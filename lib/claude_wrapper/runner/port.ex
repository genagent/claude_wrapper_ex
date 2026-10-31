defmodule ClaudeWrapper.Runner.Port do
  @moduledoc """
  Default runner: a `/bin/sh` `Port` for both one-shot calls and NDJSON
  streaming.

  Both paths start the CLI through `/bin/sh -c 'exec "$@" </dev/null'`,
  which passes the binary and arguments as positional parameters (no
  quoting, one argv string each) and gives the CLI an empty stdin. A
  missing or non-executable binary is reported as `:binary_not_found`
  before anything is spawned.

  The shell is a supervisor (`ClaudeWrapper.Command`): when the port closes
  (a timeout shuts down the one-shot `Task`, a stream halts) or the BEAM
  dies, it sends the CLI SIGINT, then SIGTERM after 2 s, then SIGKILL after
  1 s more (#303). Only the CLI's pid is signalled; subprocesses it started
  stop only if it stops them. For a process-group kill, use
  `ClaudeWrapper.Runner.Forcola` (see `ClaudeWrapper.Runner` and #185).

  Streaming bounds each line at the `:max_line_bytes` option (default 1 MiB,
  #312) but not the lines waiting in the consumer's mailbox: an Erlang port
  has no read-side flow control, so every line the CLI writes is delivered
  whether or not the consumer has asked for it.
  """

  @behaviour ClaudeWrapper.Runner

  alias ClaudeWrapper.{Command, Config}

  # Safety timeout for a hung streaming producer when no deadline is set.
  @stream_idle_timeout_ms 300_000

  @default_max_line_bytes 1_048_576

  @impl true
  def run(binary, args, opts, timeout) do
    with {:ok, path} <- Command.resolve_executable(binary) do
      # The port is owned by the task, so shutting the task down on timeout
      # closes it. Errors are returned, not raised, so nothing crashes the
      # linked caller.
      task = Task.async(fn -> run_port(path, args, opts) end)

      case Task.yield(task, timeout || :infinity) || Task.shutdown(task) do
        {:ok, reply} -> reply
        nil -> {:error, :timeout}
      end
    end
  end

  defp run_port(path, args, opts) do
    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, Command.launcher_args(path, args)}] ++
        stderr_opts(opts) ++ env_opts(opts) ++ cd_opts(opts)

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    collect(port, [])
  rescue
    e in ErlangError -> {:error, {:io, e}}
  end

  defp collect(port, acc) do
    receive do
      {^port, {:data, data}} -> collect(port, [acc | data])
      {^port, {:exit_status, code}} -> {:ok, {IO.iodata_to_binary(acc), code}}
    end
  end

  defp stderr_opts(opts),
    do: if(Keyword.get(opts, :stderr_to_stdout, false), do: [:stderr_to_stdout], else: [])

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    shell_args = Command.launcher_args(binary, args)
    max_line = Keyword.get(opts, :max_line_bytes, @default_max_line_bytes)

    limits = %{
      idle_timeout: timeout || @stream_idle_timeout_ms,
      deadline: deadline(timeout),
      max_line: max_line
    }

    # The port's line buffer only sets the fragment size; lines are
    # reassembled up to max_line. With :eof the port reports the end of the
    # CLI's stdout separately from its exit: a final unterminated line can
    # arrive after the exit status, before :eof.
    port_opts =
      [:binary, :exit_status, :eof, {:line, min(max_line + 1, 1_048_576)}, {:args, shell_args}] ++
        env_opts(opts) ++ cd_opts(opts)

    Stream.resource(
      fn -> {Port.open({:spawn_executable, "/bin/sh"}, port_opts), {[], 0}, [:eof, :exit]} end,
      fn
        {_port, :done, _pending} = state -> {:halt, state}
        {port, buffer, pending} -> next_line(port, buffer, pending, limits)
      end,
      fn {port, _buffer, _pending} -> close(port) end
    )
  end

  defp deadline(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp deadline(_timeout), do: nil

  # Reassemble lines longer than the port's line buffer: the port delivers an
  # over-long line as one or more `{:noeol, fragment}` followed by `{:eol, rest}`.
  # Carry the fragments in an iolist buffer (with its size) and flush the whole
  # line on `:eol`, rather than dropping fragments (which silently lost any
  # NDJSON event > 1 MB). A line over max_line ends the stream with
  # `{:line_limit, max_line}`; closing the port signals the CLI (#312). The
  # stream ends once both the exit status and the end of stdout are seen.
  defp next_line(port, {iodata, size} = buffer, pending, limits) do
    wait = receive_timeout(limits.idle_timeout, limits.deadline)

    if wait == 0 do
      {:halt, {port, buffer, pending}}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          if size + byte_size(line) > limits.max_line,
            do: line_limit(port, pending, limits),
            else: {[IO.iodata_to_binary([iodata, line])], {port, {[], 0}, pending}}

        {^port, {:data, {:noeol, fragment}}} ->
          size = size + byte_size(fragment)

          if size > limits.max_line,
            do: line_limit(port, pending, limits),
            else: {[], {port, {[iodata, fragment], size}, pending}}

        # A final line written without a newline is complete at end of stdout;
        # emit it as Forcola.Stream does.
        {^port, :eof} ->
          ended(port, buffer, pending -- [:eof])

        {^port, {:exit_status, _code}} ->
          ended(port, buffer, pending -- [:exit])
      after
        wait -> {:halt, {port, buffer, pending}}
      end
    end
  end

  defp ended(port, buffer, []), do: {flush(buffer), {port, :done, []}}
  defp ended(port, buffer, [:exit] = pending), do: {flush(buffer), {port, {[], 0}, pending}}
  defp ended(port, buffer, pending), do: {[], {port, buffer, pending}}

  defp flush({_iodata, 0}), do: []
  defp flush({iodata, _size}), do: [IO.iodata_to_binary(iodata)]

  defp line_limit(port, pending, limits),
    do: {[{:line_limit, limits.max_line}], {port, :done, pending}}

  defp receive_timeout(idle_timeout, nil), do: idle_timeout

  defp receive_timeout(idle_timeout, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    if idle_timeout == :infinity, do: remaining, else: min(idle_timeout, remaining)
  end

  # Closing is immediate (nothing waits for a `:closed` reply, which once
  # stalled every stream for 5 s). A port that already exited and reported end
  # of stdout is still open under :eof and is closed here too; closing one the
  # VM already closed raises and is ignored. Closing a running CLI's port makes
  # the supervisor signal it (#303).
  defp close(port) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp env_opts(opts) do
    case Keyword.get(opts, :env, []) do
      [] -> []
      env -> [{:env, Config.port_env(env)}]
    end
  end

  defp cd_opts(opts) do
    case Keyword.get(opts, :cd) do
      nil -> []
      dir -> [{:cd, String.to_charlist(dir)}]
    end
  end
end
