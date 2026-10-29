defmodule ClaudeWrapper.DuplexSession.Adapter.Port do
  @moduledoc """
  Default `ClaudeWrapper.DuplexSession.Adapter`: a real `claude`
  subprocess over an Erlang port.

  The port is opened by (and delivers its `{port, {:data, _}}` /
  `{port, {:exit_status, _}}` / `{:EXIT, port, _}` messages directly to)
  the session process, which calls `open/1` from its own `init/1`. The
  returned handle is the port itself.
  """

  @behaviour ClaudeWrapper.DuplexSession.Adapter

  alias ClaudeWrapper.{Command, Config}

  @impl true
  def open(opts) do
    config = Keyword.fetch!(opts, :config)
    args = Keyword.fetch!(opts, :args)

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, args}] ++
        env_opts(config) ++
        cd_opts(config)

    port = Port.open({:spawn_executable, config.binary}, port_opts)
    open_lifeline(port)
    {:ok, port}
  end

  # A second port that signals claude when the session closes its transport
  # or the BEAM dies (#303); see ClaudeWrapper.Command.lifeline_args/1. It is
  # opened by, and so closes with, the session process; the adapter callbacks
  # run in that process, so the lifeline is kept in its dictionary.
  defp open_lifeline(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      lifeline =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [:binary, {:args, Command.lifeline_args(os_pid)}]
        )

      Process.put({__MODULE__, :lifeline, port}, lifeline)
    end
  rescue
    ErlangError -> :ok
  end

  @impl true
  def command(port, iodata) do
    Port.command(port, iodata)
    :ok
  end

  @impl true
  def close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)

    case Process.delete({__MODULE__, :lifeline, port}) do
      lifeline when is_port(lifeline) -> close_port(lifeline)
      nil -> :ok
    end

    :ok
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp env_opts(%Config{env: []}), do: []
  defp env_opts(%Config{env: env}), do: [{:env, Config.port_env(env)}]

  defp cd_opts(%Config{working_dir: nil}), do: []
  defp cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
