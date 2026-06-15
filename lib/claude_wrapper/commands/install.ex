defmodule ClaudeWrapper.Commands.Install do
  @moduledoc """
  Install a Claude Code native build.

  Wraps `claude install [target] [--force]`.

  > #### Mutating command {: .warning}
  >
  > `install/2` runs `claude install`, which downloads and installs a native
  > build, mutating the local installation. Call it deliberately.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Install the CLI's default build
      {:ok, output} = ClaudeWrapper.Commands.Install.install(config)

      # Install a specific target, forcing reinstall
      {:ok, output} =
        ClaudeWrapper.Commands.Install.install(config, target: "latest", force: true)
  """

  alias ClaudeWrapper.Config

  @doc """
  Install a Claude Code native build.

  ## Options

    * `:target` - Version to install: `"stable"`, `"latest"`, or a specific
      version string (positional argument). Omit to use the CLI's default.
    * `:force` - Force installation even if already installed (`--force`,
      boolean).
  """
  @spec install(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def install(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ install_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc false
  @spec install_args(keyword()) :: [String.t()]
  def install_args(opts) do
    flags = bool_flag(opts[:force], "--force")
    target = if opts[:target], do: [to_string(opts[:target])], else: []

    ["install"] ++ flags ++ target
  end

  defp bool_flag(true, flag), do: [flag]
  defp bool_flag(_falsy, _flag), do: []
end
