defmodule ClaudeWrapper.Commands.Plugin do
  @moduledoc """
  Plugin management commands.

  Wraps `claude plugin install|uninstall|list|enable|disable|update|validate|tag|details|prune`.

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

      # Inspect a plugin's component inventory and token cost
      {:ok, info} = ClaudeWrapper.Commands.Plugin.details(config, "my-plugin")

      # Tag a plugin release (current dir), pushing the tag
      {:ok, _} = ClaudeWrapper.Commands.Plugin.tag(config, message: "release %s", push: true)

      # Remove auto-installed dependencies no longer needed (non-TTY needs :yes)
      {:ok, _} = ClaudeWrapper.Commands.Plugin.prune(config, yes: true)
  """

  alias ClaudeWrapper.{Config, Error}

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
          {:error, reason} -> {:error, Error.json(reason)}
        end

      {output, code} ->
        {:error, Error.command_failed(code, output)}
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
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Uninstall an installed plugin.

  ## Options

    * `:scope` - Scope to uninstall from (`:user`, `:project`, or `:local`). Default: `:user`.
    * `:keep_data` - Preserve the plugin's persistent data directory (`--keep-data`, boolean).
    * `:prune` - Also remove auto-installed dependencies that are no longer needed
      (`--prune`, boolean). Requires `:yes` in non-interactive contexts.
    * `:yes` - Skip the `--prune` confirmation prompt (`--yes`, boolean). Required when
      stdin or stdout is not a TTY, which every wrapper consumer is by definition.
  """
  @spec uninstall(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def uninstall(%Config{} = config, plugin, opts \\ []) do
    args = Config.base_args(config) ++ uninstall_args(plugin, opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec uninstall_args(String.t(), keyword()) :: [String.t()]
  def uninstall_args(plugin, opts) do
    flags =
      scope_args(opts[:scope]) ++
        bool_flag(opts[:keep_data], "--keep-data") ++
        bool_flag(opts[:prune], "--prune") ++
        bool_flag(opts[:yes], "--yes")

    ["plugin", "uninstall", plugin | flags]
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
      {output, code} -> {:error, Error.command_failed(code, output)}
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
      {output, code} -> {:error, Error.command_failed(code, output)}
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
      {output, code} -> {:error, Error.command_failed(code, output)}
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
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Create a `{name}--v{version}` git tag for a plugin release.

  Validates that the plugin's `plugin.json` and any enclosing marketplace entry
  agree on the version before tagging. Without `:path`, the CLI uses the current
  directory.

  ## Options

    * `:path` - Path to the plugin directory (positional argument).
    * `:dry_run` - Print what would be tagged without creating it (`--dry-run`, boolean).
    * `:force` - Skip the dirty-working-tree and tag-already-exists checks
      (`--force`, boolean).
    * `:message` - Tag annotation message; use `%s` for the version (`--message`).
    * `:push` - Push the tag to the remote after creating it (`--push`, boolean).
    * `:remote` - Remote to push to with `:push` (`--remote`). Default: `origin`.
  """
  @spec tag(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def tag(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ tag_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec tag_args(keyword()) :: [String.t()]
  def tag_args(opts) do
    flags =
      bool_flag(opts[:dry_run], "--dry-run") ++
        bool_flag(opts[:force], "--force") ++
        value_flag(opts[:message], "--message") ++
        bool_flag(opts[:push], "--push") ++
        value_flag(opts[:remote], "--remote")

    path = if opts[:path], do: [opts[:path]], else: []

    ["plugin", "tag"] ++ flags ++ path
  end

  @doc """
  Show a plugin's component inventory and projected token cost.

  Wraps `claude plugin details <name>`.
  """
  @spec details(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def details(%Config{} = config, plugin) do
    args = Config.base_args(config) ++ ["plugin", "details", plugin]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Remove auto-installed dependencies that are no longer needed.

  Wraps `claude plugin prune` (alias `autoremove`).

  ## Options

    * `:dry_run` - List what would be removed without removing it (`--dry-run`, boolean).
    * `:scope` - Prune at scope (`:user`, `:project`, or `:local`). Default: `:user`.
    * `:yes` - Skip the confirmation prompt (`--yes`, boolean). Required when stdin or
      stdout is not a TTY, which every wrapper consumer is by definition.
  """
  @spec prune(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def prune(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ prune_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec prune_args(keyword()) :: [String.t()]
  def prune_args(opts) do
    flags =
      bool_flag(opts[:dry_run], "--dry-run") ++
        scope_args(opts[:scope]) ++
        bool_flag(opts[:yes], "--yes")

    ["plugin", "prune"] ++ flags
  end

  defp bool_flag(true, flag), do: [flag]
  defp bool_flag(_falsy, _flag), do: []

  defp value_flag(nil, _flag), do: []
  defp value_flag(value, flag), do: [flag, value]

  defp scope_args(nil), do: []
  defp scope_args(:user), do: ["--scope", "user"]
  defp scope_args(:project), do: ["--scope", "project"]
  defp scope_args(:local), do: ["--scope", "local"]
  defp scope_args(:managed), do: ["--scope", "managed"]
end
