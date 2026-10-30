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
  """

  @behaviour ClaudeWrapper.Runner

  alias ClaudeWrapper.{Command, Config}

  # Safety timeout for a hung streaming producer when no deadline is set.
  @stream_idle_timeout_ms 300_000

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
    idle_timeout = timeout || @stream_idle_timeout_ms

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, shell_args}] ++
        env_opts(opts) ++ cd_opts(opts)

    Stream.resource(
      fn ->
        {Port.open({:spawn_executable, "/bin/sh"}, port_opts), [], :open, deadline(timeout)}
      end,
      fn {port, buffer, _status, deadline} -> next_line(port, buffer, idle_timeout, deadline) end,
      fn {port, _buffer, status, _deadline} -> close(port, status) end
    )
  end

  defp deadline(timeout) when is_integer(timeout),
    do: System.monotonic_time(:millisecond) + timeout

  defp deadline(_timeout), do: nil

  # Reassemble lines longer than the port's line buffer: the port delivers an
  # over-long line as one or more `{:noeol, fragment}` followed by `{:eol, rest}`.
  # Carry the fragments in an iolist buffer and flush the whole line on `:eol`,
  # rather than dropping fragments (which silently lost any NDJSON event > 1 MB).
  defp next_line(port, buffer, idle_timeout, deadline) do
    wait = receive_timeout(idle_timeout, deadline)

    if wait == 0 do
      {:halt, {port, buffer, :open, deadline}}
    else
      receive do
        {^port, {:data, {:eol, line}}} ->
          {[IO.iodata_to_binary([buffer, line])], {port, [], :open, deadline}}

        {^port, {:data, {:noeol, fragment}}} ->
          {[], {port, [buffer, fragment], :open, deadline}}

        {^port, {:exit_status, _code}} ->
          {:halt, {port, buffer, :exited, deadline}}
      after
        wait -> {:halt, {port, buffer, :open, deadline}}
      end
    end
  end

  defp receive_timeout(idle_timeout, nil), do: idle_timeout

  defp receive_timeout(idle_timeout, deadline) do
    remaining = max(deadline - System.monotonic_time(:millisecond), 0)
    if idle_timeout == :infinity, do: remaining, else: min(idle_timeout, remaining)
  end

  # On normal completion the port has already terminated (we received
  # `:exit_status`), so there is nothing to close -- and the old code then waited
  # for a `:closed` reply that never arrives, stalling *every* stream for the
  # full 5s receive timeout. Only a still-open port (idle timeout, or a consumer
  # that stopped early) needs an explicit close.
  defp close(_port, :exited), do: :ok

  defp close(port, :open) do
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
