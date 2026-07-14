defmodule ClaudeWrapper do
  @moduledoc """
  Elixir wrapper for the Claude Code CLI.

  Two ways to drive `claude` from Elixir:

  1. `ClaudeWrapper.DuplexSession` -- a `GenServer` that holds **one**
     `claude` subprocess open for the lifetime of a conversation.
     Streams partial tokens as they arrive, supports clean mid-turn
     cancellation, and routes tool-permission prompts back to the
     host. The right fit for chat UIs, agent runtimes, Phoenix
     servers, and any long-running OTP host.
  2. The convenience `ClaudeWrapper.query/2` and `ClaudeWrapper.stream/2`
     functions in this module -- one subprocess per turn, simple
     request/response. The right fit for `mix` tasks, escripts, batch
     jobs, and anything else that runs and exits.

  Both modes are first-class. Pick whichever matches the lifecycle
  of the host using `claude_wrapper`.

  ## Long-lived chat-style sessions (DuplexSession)

      config = ClaudeWrapper.Config.new(working_dir: ".")
      {:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config)

      ClaudeWrapper.DuplexSession.subscribe(pid)
      {:ok, result} = ClaudeWrapper.DuplexSession.send(pid, "Explain this codebase.")

      # Subscriber inbox now holds streaming events:
      #   {:claude, {:assistant, msg}}
      #   {:claude, {:stream_event, msg}}    -- partial token deltas
      #   {:claude, {:result, %ClaudeWrapper.Result{}}}

      ClaudeWrapper.DuplexSession.close(pid)

  See `ClaudeWrapper.DuplexSession` for the permission callback,
  interrupt API, and full event vocabulary. `ClaudeWrapper.DuplexIEx`
  wraps it with REPL helpers that stream tokens to stdout live.

  ## One-shot queries

      # One-shot query (convenience -- uses default config)
      {:ok, result} = ClaudeWrapper.query("Explain this error: ...")

      # With options
      {:ok, result} = ClaudeWrapper.query("Fix the bug in lib/foo.ex",
        model: "sonnet",
        working_dir: "/path/to/project",
        max_turns: 5,
        permission_mode: :bypass_permissions
      )

      # Streaming
      ClaudeWrapper.stream("Implement the feature described in issue #42",
        working_dir: "/path/to/project"
      )
      |> Stream.each(fn event -> IO.inspect(event.type) end)
      |> Stream.run()

      # Full control via Query builder
      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")

      ClaudeWrapper.Query.new("Fix the tests")
      |> ClaudeWrapper.Query.model("sonnet")
      |> ClaudeWrapper.Query.dangerously_skip_permissions()
      |> ClaudeWrapper.Query.max_turns(10)
      |> ClaudeWrapper.Query.execute(config)

  ## Multi-turn continuity for one-shot mode (Session)

  `ClaudeWrapper.Session` threads `--resume <session_id>` across
  one-shot calls so you can have a multi-turn conversation without
  holding a subprocess open. Use it when you want a struct-passing
  API rather than a process API, or when turns are far enough apart
  that cold-start cost doesn't matter.

  ## Other modules

    * `ClaudeWrapper.Query` -- the query builder
    * `ClaudeWrapper.SessionServer` -- supervised wrapper for `Session`
    * `ClaudeWrapper.McpConfig` -- programmatic `.mcp.json` builder
    * `ClaudeWrapper.Retry` -- exponential backoff
    * `ClaudeWrapper.Telemetry` -- `:telemetry` spans for exec/stream/session
    * `ClaudeWrapper.Commands.{Auth, Mcp, Plugin, Marketplace, Doctor, Version}` -- CLI subcommand wrappers

  ## Binary discovery

  The `claude` binary is found via (in order):

  1. `:binary` option passed directly
  2. `CLAUDE_CLI` environment variable
  3. System PATH lookup
  """

  alias ClaudeWrapper.{Commands, Config, Error, Query, Result}

  @doc """
  Run an arbitrary CLI command that isn't wrapped by a dedicated module.

  This is the escape hatch for new or experimental CLI subcommands.

  ## Examples

      ClaudeWrapper.raw(["config", "list"])
      ClaudeWrapper.raw(["plugin", "install", "my-plugin"], working_dir: "/tmp")
  """
  @spec raw([String.t()], keyword()) :: {:ok, String.t()} | {:error, term()}
  def raw(args, opts \\ []) when is_list(args) do
    config = Config.new(opts)
    all_args = Config.base_args(config) ++ args

    # Route through the configured Runner (not System.cmd directly) so raw/2
    # honors `config.timeout` AND the leak-free Forcola runner's process-group
    # kill -- the one API explicitly framed as "run an arbitrary CLI command"
    # should not be the one that silently bypasses both.
    case ClaudeWrapper.Runner.impl().run(
           config.binary,
           all_args,
           Config.cmd_opts(config),
           config.timeout
         ) do
      {:ok, {output, 0}} ->
        {:ok, String.trim(output)}

      {:ok, {output, code}} ->
        {:error, Error.command_failed(code, output)}

      {:error, :timeout} ->
        {:error, Error.timeout(config.timeout)}

      {:error, {:binary_not_found, _reason}} ->
        {:error, Error.new(:binary_not_found, reason: config.binary)}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end

  @doc """
  Execute a one-shot query and return the result.

  Convenience wrapper that builds a `Config` and `Query` from keyword options.
  Returns `{:ok, %Result{}}` on success or `{:error, reason}` on failure.

  ## Options

  Config options (passed to `ClaudeWrapper.Config.new/1`):
    * `:binary` - Path to claude binary
    * `:working_dir` - Working directory
    * `:env` - Environment variables
    * `:timeout` - Timeout in ms
    * `:verbose` - Enable verbose output
    * `:debug` - Enable debug output

  Query options (passed to `Query` builder):
    * `:model` - Model name
    * `:system_prompt` - System prompt override
    * `:max_turns` - Max turns
    * `:max_budget_usd` - Budget limit
    * `:permission_mode` - Permission mode atom
    * `:dangerously_skip_permissions` - Bypass permissions (boolean)
    * `:session_id` - Session ID
    * `:continue_session` - Continue recent session (boolean)
    * `:resume` - Resume session ID
    * `:hermetic` - Seal the ambient `~/.claude` config for a reproducible
      surface: `true` or `:full` (drops user + project + local ambient),
      `:project` (keeps the user's global config). Does not change auth.
      See `ClaudeWrapper.Query.hermetic/2`.

  The list above is the common subset. Any other option accepted by
  `ClaudeWrapper.Query.apply_opts/2` also works here (for example `:effort`,
  `:agent`, `:agents_json`, `:fallback_model`, `:output_format`,
  `:allowed_tools`, `:disallowed_tools`, `:add_dir`, `:files`, `:mcp_config`,
  `:plugin_dirs`, `:worktree`, `:fork_session`, `:setting_sources`,
  `:json_schema`, `:betas`) -- see `ClaudeWrapper.Query.apply_opts/2` for the
  authoritative full list.
  """
  @spec query(String.t(), keyword()) :: {:ok, Result.t()} | {:error, term()}
  def query(prompt, opts \\ []) do
    {config_opts, query_opts} = split_opts(opts)
    config = Config.new(config_opts)
    query = build_query(prompt, query_opts)
    Query.execute(query, config)
  end

  @doc """
  Execute a query and return a lazy stream of `%StreamEvent{}` structs.

  The subprocess starts when the stream is consumed. Accepts the same options as
  `query/2`, except `:timeout`: streaming is bounded only by a per-frame idle
  deadline, not a whole-run timeout. A truncated run (idle timeout, non-zero
  exit, spawn failure) ends with a terminal
  `%StreamEvent{type: "error", data: %{"error" => "stream_truncated"}}` rather
  than a silent stop; see `ClaudeWrapper.Query.stream/2` for details and the
  Forcola-runner note.
  """
  @spec stream(String.t(), keyword()) :: Enumerable.t()
  def stream(prompt, opts \\ []) do
    {config_opts, query_opts} = split_opts(opts)
    config = Config.new(config_opts)
    query = build_query(prompt, query_opts)
    Query.stream(query, config)
  end

  @doc """
  Get the CLI version.
  """
  @spec version(keyword()) :: {:ok, map()} | {:error, term()}
  def version(opts \\ []) do
    config = Config.new(opts)
    Commands.Version.execute(config)
  end

  @doc """
  Check authentication status.
  """
  @spec auth_status(keyword()) :: {:ok, map()} | {:error, term()}
  def auth_status(opts \\ []) do
    config = Config.new(opts)
    Commands.Auth.status(config)
  end

  @doc """
  Run `claude doctor`.
  """
  @spec doctor(keyword()) :: {:ok, String.t()} | {:error, term()}
  def doctor(opts \\ []) do
    config = Config.new(opts)
    Commands.Doctor.execute(config)
  end

  @doc """
  List active background agent sessions (`claude agents --json`).

  Returns the decoded JSON array of active sessions (each a raw, string-keyed
  map). See `ClaudeWrapper.Commands.Agents`.

  ## Options

    * `:all` - include completed sessions (`--all`)
    * `:setting_sources` - comma-separated setting sources (e.g. `"user,project"`)

  """
  @spec agents(keyword()) :: {:ok, [map()]} | {:error, term()}
  def agents(opts \\ []) do
    {config_opts, agent_opts} = split_opts(opts)
    config = Config.new(config_opts)
    Commands.Agents.list(config, agent_opts)
  end

  # --- Private ---

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose, :debug]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp build_query(prompt, opts) do
    prompt
    |> Query.new()
    |> Query.apply_opts(opts)
  end
end
