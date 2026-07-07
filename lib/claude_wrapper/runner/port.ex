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
    e in ErlangError -> {:error, {:io, e}}
  end

  def run(binary, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(binary, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {stdout, code}} -> {:ok, {stdout, code}}
      nil -> {:error, :timeout}
    end
  rescue
    e in ErlangError -> {:error, {:io, e}}
  end

  @impl true
  def stream_lines(binary, args, opts, timeout) do
    shell_args = Command.shell_cmd_args(binary, args)
    idle_timeout = timeout || @stream_idle_timeout_ms

    port_opts =
      [:binary, :exit_status, {:line, 1_048_576}, {:args, shell_args}] ++
        env_opts(opts) ++ cd_opts(opts)

    Stream.resource(
      fn -> Port.open({:spawn_executable, "/bin/sh"}, port_opts) end,
      fn port -> next_line(port, idle_timeout) end,
      fn port -> close(port) end
    )
  end

  defp next_line(port, idle_timeout) do
    receive do
      {^port, {:data, {:eol, line}}} -> {[line], port}
      # A line longer than the buffer cap: skip its fragment, as before.
      {^port, {:data, {:noeol, _partial}}} -> {[], port}
      {^port, {:exit_status, _code}} -> {:halt, port}
    after
      idle_timeout -> {:halt, port}
    end
  end

  defp close(port) do
    send(port, {self(), :close})

    receive do
      {^port, :closed} -> :ok
    after
      5_000 -> :ok
    end
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
