defmodule ClaudeWrapper.Settings do
  @moduledoc """
  Read-side access to Claude Code's on-disk **settings** files.

  Claude Code reads up to four JSON files in increasing order of
  precedence (later layers override earlier ones):

    1. `~/.claude/settings.json` -- user defaults
    2. `~/.claude/settings.local.json` -- user-private overrides
    3. `<project>/.claude/settings.json` -- project-shared
    4. `<project>/.claude/settings.local.json` -- project-private

  This module reads each layer as an opaque decoded JSON value and
  returns them side by side, **without merging**. Claude Code's merge
  semantics are non-trivial and not fully documented, so reproducing
  them here would risk diverging from the binary. Callers who want an
  "effective" view can merge with full knowledge of which layer produced
  which value -- the per-layer split makes that attribution possible.

  ## Secrets

  The `env` block of a settings file often contains secrets
  (`ANTHROPIC_API_KEY`, tokens). Use `redact_env_values/1` before
  forwarding a layer to a less-trusted consumer.

  ## Example

      {:ok, settings} = ClaudeWrapper.Settings.load(project_root: "/path/to/repo")

      case ClaudeWrapper.Settings.get(settings, :user) do
        nil -> IO.puts("no user settings")
        user -> IO.inspect(Map.keys(user))
      end
  """

  @enforce_keys [:user, :user_local, :project, :project_local, :paths]
  defstruct [:user, :user_local, :project, :project_local, :paths]

  @typedoc "One of the four settings layers, low-to-high precedence."
  @type layer :: :user | :user_local | :project | :project_local

  @typedoc "Absolute paths the loader checked, whether or not the files exist."
  @type paths :: %{
          user: String.t(),
          user_local: String.t(),
          project: String.t() | nil,
          project_local: String.t() | nil
        }

  @type t :: %__MODULE__{
          user: map() | nil,
          user_local: map() | nil,
          project: map() | nil,
          project_local: map() | nil,
          paths: paths()
        }

  @doc """
  Load all four settings layers.

  Options:

    * `:user_root` -- the `.claude` directory to read user layers from
      (default: `~/.claude`)
    * `:project_root` -- the project directory whose `.claude/` holds the
      project layers (default: none, so the project layers stay `nil`)

  Missing files become `nil`; a malformed JSON file returns
  `{:error, {:invalid_settings_json, path, reason}}`. Returns
  `{:error, :no_home}` when `:user_root` is omitted and the home
  directory cannot be determined.
  """
  @spec load(keyword()) :: {:ok, t()} | {:error, term()}
  def load(opts \\ []) do
    with {:ok, user_root} <- resolve_user_root(opts) do
      paths = build_paths(user_root, Keyword.get(opts, :project_root))

      with {:ok, user} <- read_layer(paths.user),
           {:ok, user_local} <- read_layer(paths.user_local),
           {:ok, project} <- read_layer(paths.project),
           {:ok, project_local} <- read_layer(paths.project_local) do
        {:ok,
         %__MODULE__{
           user: user,
           user_local: user_local,
           project: project,
           project_local: project_local,
           paths: paths
         }}
      end
    end
  end

  @doc "Return the loaded value for one `t:layer/0`, or `nil` if absent."
  @spec get(t(), layer()) :: map() | nil
  def get(%__MODULE__{} = s, :user), do: s.user
  def get(%__MODULE__{} = s, :user_local), do: s.user_local
  def get(%__MODULE__{} = s, :project), do: s.project
  def get(%__MODULE__{} = s, :project_local), do: s.project_local

  @doc "All four layers, low-to-high precedence."
  @spec layers() :: [layer(), ...]
  def layers, do: [:user, :user_local, :project, :project_local]

  @doc "The filename component (after `.claude/`) for a layer."
  @spec filename(layer()) :: String.t()
  def filename(layer) when layer in [:user, :project], do: "settings.json"
  def filename(layer) when layer in [:user_local, :project_local], do: "settings.local.json"

  @doc """
  Replace every value under the top-level `env` object with
  `"<redacted>"`, keeping the keys visible. A no-op on values that are
  not maps or that have no map-valued `env` field.
  """
  @spec redact_env_values(map()) :: map()
  def redact_env_values(%{"env" => env} = map) when is_map(env) do
    Map.put(map, "env", Map.new(env, fn {k, _v} -> {k, "<redacted>"} end))
  end

  def redact_env_values(value), do: value

  # -- helpers -------------------------------------------------------

  defp resolve_user_root(opts) do
    case Keyword.get(opts, :user_root) do
      nil ->
        case System.user_home() do
          nil -> {:error, :no_home}
          home -> {:ok, Path.join(home, ".claude")}
        end

      root ->
        {:ok, root}
    end
  end

  defp build_paths(user_root, project_root) do
    %{
      user: Path.join(user_root, "settings.json"),
      user_local: Path.join(user_root, "settings.local.json"),
      project: project_root && Path.join([project_root, ".claude", "settings.json"]),
      project_local: project_root && Path.join([project_root, ".claude", "settings.local.json"])
    }
  end

  defp read_layer(nil), do: {:ok, nil}

  defp read_layer(path) do
    case File.read(path) do
      {:ok, raw} -> decode_layer(path, raw)
      {:error, :enoent} -> {:ok, nil}
      {:error, reason} -> {:error, {:settings_read_error, path, reason}}
    end
  end

  defp decode_layer(path, raw) do
    case Jason.decode(raw) do
      {:ok, value} -> {:ok, value}
      {:error, reason} -> {:error, {:invalid_settings_json, path, reason}}
    end
  end
end
