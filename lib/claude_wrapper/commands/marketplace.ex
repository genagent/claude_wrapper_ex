defmodule ClaudeWrapper.Commands.Marketplace do
  @moduledoc """
  Plugin marketplace management commands.

  Wraps `claude plugin marketplace add|remove|list|update`.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # List configured marketplaces
      {:ok, marketplaces} = ClaudeWrapper.Commands.Marketplace.list(config)

      # Add a marketplace from a URL or GitHub repo
      {:ok, _} = ClaudeWrapper.Commands.Marketplace.add(config, "https://github.com/org/marketplace")

      # Add with sparse checkout for monorepos
      {:ok, _} = ClaudeWrapper.Commands.Marketplace.add(config, "https://github.com/org/repo",
        sparse: [".claude-plugin", "plugins"]
      )

      # Remove a marketplace
      {:ok, _} = ClaudeWrapper.Commands.Marketplace.remove(config, "my-marketplace")

      # Update all marketplaces
      {:ok, _} = ClaudeWrapper.Commands.Marketplace.update(config)
  """

  alias ClaudeWrapper.{Config, Error}

  @type scope :: :user | :project | :local

  @doc """
  List all configured marketplaces.
  """
  @spec list(Config.t()) :: {:ok, list(map())} | {:error, term()}
  def list(%Config{} = config) do
    args = Config.base_args(config) ++ ["plugin", "marketplace", "list", "--json"]

    case Config.exec(config, args) do
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
  Add a marketplace from a URL, path, or GitHub repo.

  ## Options

    * `:scope` - Where to declare the marketplace (`:user`, `:project`, or `:local`). Default: `:user`.
    * `:sparse` - List of directories for git sparse-checkout (for monorepos).
  """
  @spec add(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, source, opts \\ []) do
    args = Config.base_args(config) ++ add_args(source, opts)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec add_args(String.t(), keyword()) :: [String.t()]
  def add_args(source, opts) do
    flags = scope_args(opts[:scope]) ++ sparse_args(opts[:sparse])
    ["plugin", "marketplace", "add", source | flags]
  end

  @doc """
  Remove a configured marketplace by name.
  """
  @spec remove(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def remove(%Config{} = config, name) do
    args = Config.base_args(config) ++ ["plugin", "marketplace", "remove", name]

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Update marketplace(s) from their source.

  If no name is given, updates all marketplaces.
  """
  @spec update(Config.t(), String.t() | nil) :: {:ok, String.t()} | {:error, term()}
  def update(%Config{} = config, name \\ nil) do
    args = Config.base_args(config) ++ update_args(name)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec update_args(String.t() | nil) :: [String.t()]
  def update_args(name) do
    base = ["plugin", "marketplace", "update"]
    if name, do: base ++ [name], else: base
  end

  defp scope_args(nil), do: []
  defp scope_args(:user), do: ["--scope", "user"]
  defp scope_args(:project), do: ["--scope", "project"]
  defp scope_args(:local), do: ["--scope", "local"]

  defp sparse_args(nil), do: []
  defp sparse_args(paths) when is_list(paths), do: ["--sparse" | paths]
end
