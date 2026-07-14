defmodule ClaudeWrapper.Runner.Port do
  @moduledoc """
  Default runner: `System.cmd/3` for one-shot calls and a `/bin/sh`
  `Port` for NDJSON streaming.

  This is the execution path the library has always used. On a timeout
  it shuts down the `Task` (one-shot) or closes the port (streaming),
  which closes the pipes but sends no signal to the OS process. The CLI
  and any subprocess it spawned may keep running until they next touch a
  closed pipe. For strict termination, use `ClaudeWrapper.Runner.Forcola`
  (see `ClaudeWrapper.Runner` and #185).
  """

  @behaviour ClaudeWrapper.Runner

  alias ClaudeWrapper.Command

  # Safety timeout for a hung streaming producer: bounds the gap between
  # output frames, matching the historical per-receive deadline.
  @stream_idle_timeout_ms 300_000

  @impl true
  def run(binary, args, opts, nil) do
    {stdout, code} = System.cmd(binary, args, opts)
    {:ok, {stdout, code}}
  rescue
    e in ErlangError -> {:error, launch_error(e)}
  end

  def run(binary, args, opts, timeout) do
    # Rescue INSIDE the task: a missing/unlaunchable binary raises here, and
    # `Task.async` links, so an un-rescued raise crashes the *caller* (the outer
    # rescue below could not catch that linked exit -- the previous code did, so
    # a missing binary on the timeout path crashed the job). Wrap the outcome so
    # both success and failure come back through `Task.yield`.
    task =
      Task.async(fn ->
        try do
          {:ok, System.cmd(binary, args, opts)}
        rescue
          e in ErlangError -> {:error, launch_error(e)}
        end
      end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, {stdout, code}}} -> {:ok, {stdout, code}}
      {:ok, {:error, reason}} -> {:error, reason}
      nil -> {:error, :timeout}
    end
  end

  # A missing or non-executable binary fails the OS spawn with `:enoent` /
  # `:eacces`; surface it as the typed `:binary_not_found` signal (run_cmd turns
  # it into a `%Error{kind: :binary_not_found}`) rather than a generic `:io`,
  # which the classifier would retry to exhaustion.
  defp launch_error(%ErlangError{original: reason}) when reason in [:enoent, :eacces],
    do: {:binary_not_found, reason}

  defp launch_error(e), do: {:io, e}

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    shell_args = Command.shell_cmd_args(binary, args)
    idle_timeout = timeout || @stream_idle_timeout_ms

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, shell_args}] ++
        env_opts(opts) ++ cd_opts(opts)

    Stream.resource(
      fn -> {Port.open({:spawn_executable, "/bin/sh"}, port_opts), [], :open} end,
      fn {port, buffer, _status} -> next_line(port, buffer, idle_timeout) end,
      fn {port, _buffer, status} -> close(port, status) end
    )
  end

  # Reassemble lines longer than the port's line buffer: the port delivers an
  # over-long line as one or more `{:noeol, fragment}` followed by `{:eol, rest}`.
  # Carry the fragments in an iolist buffer and flush the whole line on `:eol`,
  # rather than dropping fragments (which silently lost any NDJSON event > 1 MB).
  defp next_line(port, buffer, idle_timeout) do
    receive do
      {^port, {:data, {:eol, line}}} ->
        {[IO.iodata_to_binary([buffer, line])], {port, [], :open}}

      {^port, {:data, {:noeol, fragment}}} ->
        {[], {port, [buffer, fragment], :open}}

      {^port, {:exit_status, _code}} ->
        {:halt, {port, buffer, :exited}}
    after
      idle_timeout -> {:halt, {port, buffer, :open}}
    end
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
      env -> [{:env, env}]
    end
  end

  defp cd_opts(opts) do
    case Keyword.get(opts, :cd) do
      nil -> []
      dir -> [{:cd, String.to_charlist(dir)}]
    end
  end
end
