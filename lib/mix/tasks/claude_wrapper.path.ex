defmodule Mix.Tasks.ClaudeWrapper.Path do
  @shortdoc "Print the bundled claude binary path (and install state)"

  @moduledoc """
  Print where the opt-in bundled `claude` binary lives, and whether it is
  installed.

      mix claude_wrapper.path

  Prints the absolute path on stdout (scriptable); install state goes to
  stderr via the Mix shell.
  """

  use Mix.Task

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.config")
    path = ClaudeWrapper.Bundled.path()

    state =
      case ClaudeWrapper.Bundled.installed_version() do
        nil ->
          if ClaudeWrapper.Bundled.installed?(),
            do: "installed (version unknown)",
            else: "not installed"

        version ->
          "installed (#{ClaudeWrapper.CliVersion.to_string(version)})"
      end

    Mix.shell().info("#{path}  [#{state}]")
  end
end
