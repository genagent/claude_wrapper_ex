defmodule ClaudeWrapper.DangerousClient do
  @moduledoc """
  Opt-in wrapper for permission-bypass queries.

  Running the `claude` CLI with `--dangerously-skip-permissions` turns
  off every confirmation prompt for tool use. It's legitimate for some
  automation -- but it's also the fastest way to turn a bug into a
  destructive action.

  This module isolates that capability behind a type you have to
  explicitly reach for (`ClaudeWrapper.DangerousClient`) and a runtime
  env-var gate (`#{"CLAUDE_WRAPPER_ALLOW_DANGEROUS"}`) you have to
  explicitly set.

  ## Usage

      # At process start (deliberately):
      #   export CLAUDE_WRAPPER_ALLOW_DANGEROUS=1

      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")

      case ClaudeWrapper.DangerousClient.new(config) do
        {:ok, client} ->
          query = ClaudeWrapper.Query.new("clean up the build artifacts")
          {:ok, result} = ClaudeWrapper.DangerousClient.query_bypass(client, query)

        {:error, {:dangerous_not_allowed, env_var}} ->
          # The caller forgot to set the env var; refuse loudly rather
          # than silently running with (or without) bypass.
          {:error, {:dangerous_not_allowed, env_var}}
      end

  ## Why this shape

    * **Separate type.** `new/1` is the only path to building a bypassed
      query through this module. If a reader of calling code sees
      `DangerousClient`, the danger is obvious at the call site.
    * **Runtime env-var gate.** The check happens at construction, so a
      caller who forgot to set the env var gets a tagged error rather
      than silently running with bypass off (which might surprise them)
      or silently running with bypass on (which might destroy things).
    * **Checked on every construction.** The gate is read on each call
      to `new/1` rather than memoized, so a test that flips the env var
      mid-process sees the change.

  The lower-level `ClaudeWrapper.Query.dangerously_skip_permissions/1`
  setter is still available without this gate; this module is the
  guarded, intention-revealing path on top of it.

  Equivalent to the Rust crate's `dangerous::DangerousClient`. The Rust
  type splits `query_bypass` into async (`query_bypass`) and blocking
  (`query_bypass_sync`) variants gated by cargo features; the Elixir
  port has a single synchronous `query_bypass/2` since `Query.execute/2`
  is synchronous and there are no feature gates.
  """

  alias ClaudeWrapper.{Config, Query, Result}

  @typedoc """
  A guarded client. Holds the shared `t:ClaudeWrapper.Config.t/0` that
  bypass queries run against.
  """
  @type t :: %__MODULE__{config: Config.t()}

  @enforce_keys [:config]
  defstruct [:config]

  @allow_env "CLAUDE_WRAPPER_ALLOW_DANGEROUS"

  @doc """
  The name of the env var that must equal `"1"` for `new/1` to succeed.

  Exposed so callers and tests can reference the gate without hardcoding
  the string.

  ## Examples

      iex> ClaudeWrapper.DangerousClient.allow_env()
      "CLAUDE_WRAPPER_ALLOW_DANGEROUS"
  """
  @spec allow_env() :: String.t()
  def allow_env, do: @allow_env

  @doc """
  Build a guarded client, refusing unless the opt-in env var is set.

  Succeeds only when `System.get_env("#{@allow_env}") == "1"`. Otherwise
  returns `{:error, {:dangerous_not_allowed, env_var}}`, where `env_var`
  is the name of the env var to set.

  The check is made on each call rather than memoized, so a process that
  sets the env var after start (or a test that flips it) is honored.

  ## Examples

      {:ok, client} = ClaudeWrapper.DangerousClient.new(ClaudeWrapper.Config.new())

      {:error, {:dangerous_not_allowed, "CLAUDE_WRAPPER_ALLOW_DANGEROUS"}} =
        ClaudeWrapper.DangerousClient.new(ClaudeWrapper.Config.new())
  """
  @spec new(Config.t()) :: {:ok, t()} | {:error, {:dangerous_not_allowed, String.t()}}
  def new(%Config{} = config) do
    if allowed?() do
      {:ok, %__MODULE__{config: config}}
    else
      {:error, {:dangerous_not_allowed, @allow_env}}
    end
  end

  @doc """
  Return the underlying config for composition with other wrapper APIs.
  """
  @spec config(t()) :: Config.t()
  def config(%__MODULE__{config: config}), do: config

  @doc """
  Run `query` with `--dangerously-skip-permissions` set, against the
  client's config.

  Sets `dangerously_skip_permissions` on the query (replacing any prior
  value) and delegates to `ClaudeWrapper.Query.execute/2`. Returns
  whatever `execute/2` returns: `{:ok, %ClaudeWrapper.Result{}}` or
  `{:error, reason}`.
  """
  @spec query_bypass(t(), Query.t()) :: {:ok, Result.t()} | {:error, term()}
  def query_bypass(%__MODULE__{config: config}, %Query{} = query) do
    query
    |> Query.dangerously_skip_permissions()
    |> Query.execute(config)
  end

  defp allowed?, do: System.get_env(@allow_env) == "1"
end
