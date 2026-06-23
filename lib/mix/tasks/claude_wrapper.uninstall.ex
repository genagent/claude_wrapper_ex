defmodule Mix.Tasks.ClaudeWrapper.Uninstall do
  @shortdoc "Remove the bundled claude binary from priv/bin"

  @moduledoc """
  Remove the opt-in bundled `claude` binary installed by
  `mix claude_wrapper.install`.

      mix claude_wrapper.uninstall

  Idempotent: succeeds whether or not a bundled binary is present.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    path = ClaudeWrapper.Bundled.path()
    existed? = ClaudeWrapper.Bundled.installed?()
    :ok = ClaudeWrapper.Bundled.uninstall()

    if existed? do
      Mix.shell().info("removed bundled claude at #{path}")
    else
      Mix.shell().info("no bundled claude to remove (#{path})")
    end
  end
end
