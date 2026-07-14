defmodule ClaudeWrapper.Commands.Agents do
  @moduledoc """
  `claude agents` command -- lists active background agent sessions.

  Bare `claude agents` is an interactive, TTY-oriented view; the scripting
  surface is `claude agents --json`, which "Print[s] active sessions as a JSON
  array and exit[s] ... does not require a TTY". This module uses `--json` and
  decodes that array, so it returns **active sessions** (not configured agents).
  Each element is the CLI's raw session map (string keys).

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Active background sessions (decoded JSON array)
      {:ok, sessions} = ClaudeWrapper.Commands.Agents.list(config)

      # Include completed sessions too
      {:ok, sessions} = ClaudeWrapper.Commands.Agents.list(config, all: true)

      # Raw --json output string
      {:ok, json} = ClaudeWrapper.Commands.Agents.execute(config)
  """

  alias ClaudeWrapper.{Config, Error}

  @typedoc "A background-agent session as reported by `claude agents --json` (raw, string-keyed)."
  @type session :: map()

  @doc """
  Run `claude agents --json` and return the decoded array of active sessions.

  ## Options

    * `:all` - include completed sessions, not just active ones (`--all`)
    * `:setting_sources` - comma-separated setting sources to load
      (e.g. `"user,project"`)
  """
  @spec list(Config.t(), keyword()) :: {:ok, [session()]} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ list_args(opts)

    case Config.exec(config, args) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, sessions} when is_list(sessions) -> {:ok, sessions}
          {:ok, _other} -> {:error, Error.json(:not_an_array, output)}
          {:error, reason} -> {:error, Error.json(reason, output)}
        end

      {output, code} ->
        {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Run `claude agents --json` and return the raw output string.
  """
  @spec execute(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ list_args(opts)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec list_args(keyword()) :: [String.t()]
  def list_args(opts) do
    args = ["agents", "--json"]
    args = if opts[:all], do: args ++ ["--all"], else: args

    case Keyword.get(opts, :setting_sources) do
      nil -> args
      sources -> args ++ ["--setting-sources", sources]
    end
  end
end
