defmodule Mix.Tasks.ClaudeWrapper.Install do
  @shortdoc "Install the pinned bundled claude binary into priv/bin"

  @moduledoc """
  Install the opt-in bundled `claude` CLI (current stable, verified `>=`
  `ClaudeWrapper.Bundled.minimum_version/0`) into the package's `priv/bin/`.

      mix claude_wrapper.install

  No-op when an up-to-date binary is already installed. Reinstalls on a
  version mismatch. This downloads from the network; the default PATH-based
  resolution does not need it.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")

    case ClaudeWrapper.Bundled.ensure() do
      {:ok, path} ->
        Mix.shell().info(
          "claude installed at #{path} (>= #{ClaudeWrapper.Bundled.minimum_version()})"
        )

      {:error, error} ->
        Mix.raise("bundled install failed: #{Exception.message(error)}")
    end
  end
end
