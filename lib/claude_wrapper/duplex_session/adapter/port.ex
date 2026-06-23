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

  alias ClaudeWrapper.Config

  @impl true
  def open(opts) do
    config = Keyword.fetch!(opts, :config)
    args = Keyword.fetch!(opts, :args)

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, args}] ++
        env_opts(config) ++
        cd_opts(config)

    {:ok, Port.open({:spawn_executable, config.binary}, port_opts)}
  end

  @impl true
  def command(port, iodata) do
    Port.command(port, iodata)
    :ok
  end

  @impl true
  def close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  defp env_opts(%Config{env: []}), do: []
  defp env_opts(%Config{env: env}), do: [{:env, env}]

  defp cd_opts(%Config{working_dir: nil}), do: []
  defp cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
