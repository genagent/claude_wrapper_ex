defmodule ClaudeWrapper.Commands.Plugin do
  @moduledoc """
  Plugin management commands.

  Wraps `claude plugin install|uninstall|list|enable|disable|update|validate`.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # List installed plugins
      {:ok, plugins} = ClaudeWrapper.Commands.Plugin.list(config)

      # List with available marketplace plugins
      {:ok, plugins} = ClaudeWrapper.Commands.Plugin.list(config, available: true)

      # Install a plugin
      {:ok, _} = ClaudeWrapper.Commands.Plugin.install(config, "my-plugin")

      # Install from a specific marketplace
      {:ok, _} = ClaudeWrapper.Commands.Plugin.install(config, "my-plugin@my-marketplace")

      # Enable / disable
      {:ok, _} = ClaudeWrapper.Commands.Plugin.enable(config, "my-plugin")
      {:ok, _} = ClaudeWrapper.Commands.Plugin.disable(config, "my-plugin")
  """

  alias ClaudeWrapper.Config

  @type scope :: :user | :project | :local

  @doc """
  List installed plugins.

  ## Options

    * `:available` - Include available plugins from marketplaces (boolean, requires JSON output)
  """
  @spec list(Config.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "list", "--json"]
    args = if opts[:available], do: args ++ ["--available"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Install a plugin from available marketplaces.

  Use `"name@marketplace"` to install from a specific marketplace.

  ## Options

    * `:scope` - Installation scope (`:user`, `:project`, or `:local`). Default: `:user`.
  """
  @spec install(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def install(%Config{} = config, plugin, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "install", plugin]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Uninstall an installed plugin.

  ## Options

    * `:scope` - Scope to uninstall from (`:user`, `:project`, or `:local`). Default: `:user`.
    * `:keep_data` - Preserve the plugin's persistent data directory (boolean).
  """
  @spec uninstall(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def uninstall(%Config{} = config, plugin, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "uninstall", plugin]
    args = args ++ scope_args(opts[:scope])
    args = if opts[:keep_data], do: args ++ ["--keep-data"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Enable a disabled plugin.

  ## Options

    * `:scope` - Scope (`:user`, `:project`, or `:local`). Default: auto-detect.
  """
  @spec enable(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def enable(%Config{} = config, plugin, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "enable", plugin]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Disable an enabled plugin.

  ## Options

    * `:scope` - Scope (`:user`, `:project`, or `:local`). Default: auto-detect.
    * `:all` - Disable all enabled plugins (boolean).
  """
  @spec disable(Config.t(), String.t() | nil, keyword()) :: {:ok, String.t()} | {:error, term()}
  def disable(%Config{} = config, plugin \\ nil, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "disable"]
    args = if plugin, do: args ++ [plugin], else: args
    args = args ++ scope_args(opts[:scope])
    args = if opts[:all], do: args ++ ["--all"], else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Update a plugin to the latest version.

  ## Options

    * `:scope` - Scope (`:user`, `:project`, `:local`, or `:managed`). Default: `:user`.
  """
  @spec update(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def update(%Config{} = config, plugin, opts \\ []) do
    args = Config.base_args(config) ++ ["plugin", "update", plugin]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Validate a plugin or marketplace manifest at the given path.
  """
  @spec validate(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def validate(%Config{} = config, path) do
    args = Config.base_args(config) ++ ["plugin", "validate", path]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp scope_args(nil), do: []
  defp scope_args(:user), do: ["--scope", "user"]
  defp scope_args(:project), do: ["--scope", "project"]
  defp scope_args(:local), do: ["--scope", "local"]
  defp scope_args(:managed), do: ["--scope", "managed"]
end
