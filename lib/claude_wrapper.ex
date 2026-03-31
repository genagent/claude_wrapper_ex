defmodule ClaudeWrapper do
  @moduledoc """
  Elixir wrapper for the Claude Code CLI.

  Provides a typed interface for executing queries against the `claude` CLI,
  with support for one-shot execution and streaming NDJSON output.

  ## Quick start

      # One-shot query (convenience — uses default config)
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

  ## Commands

    * `ClaudeWrapper.Query` — the main query/prompt interface
    * `ClaudeWrapper.Commands.Auth` — login, logout, status, token
    * `ClaudeWrapper.Commands.Mcp` — MCP server management
    * `ClaudeWrapper.Commands.Doctor` — CLI health check
    * `ClaudeWrapper.Commands.Version` — CLI version

  ## Binary discovery

  The `claude` binary is found via (in order):
  1. `:binary` option passed directly
  2. `CLAUDE_CLI` environment variable
  3. System PATH lookup
  """

  alias ClaudeWrapper.{Config, Query, Result}

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
    cmd_opts = Config.cmd_opts(config)

    case System.cmd(config.binary, all_args, cmd_opts) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  rescue
    e in ErlangError -> {:error, {:system_cmd, e}}
  end

  @doc """
  Execute a one-shot query and return the result.

  Convenience wrapper that builds a `Config` and `Query` from keyword options.
  Returns `{:ok, %Result{}}` on success or `{:error, reason}` on failure.

  ## Options

  Config options (passed to `Config.new/1`):
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

  The subprocess starts when the stream is consumed. Accepts the same
  options as `query/2`.
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
    ClaudeWrapper.Commands.Version.execute(config)
  end

  @doc """
  Check authentication status.
  """
  @spec auth_status(keyword()) :: {:ok, map()} | {:error, term()}
  def auth_status(opts \\ []) do
    config = Config.new(opts)
    ClaudeWrapper.Commands.Auth.status(config)
  end

  @doc """
  Run `claude doctor`.
  """
  @spec doctor(keyword()) :: {:ok, String.t()} | {:error, term()}
  def doctor(opts \\ []) do
    config = Config.new(opts)
    ClaudeWrapper.Commands.Doctor.execute(config)
  end

  # --- Private ---

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose, :debug]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp build_query(prompt, opts) do
    query = Query.new(prompt)

    Enum.reduce(opts, query, fn
      {:model, v}, q -> Query.model(q, v)
      {:system_prompt, v}, q -> Query.system_prompt(q, v)
      {:append_system_prompt, v}, q -> Query.append_system_prompt(q, v)
      {:max_turns, v}, q -> Query.max_turns(q, v)
      {:max_budget_usd, v}, q -> Query.max_budget_usd(q, v)
      {:permission_mode, v}, q -> Query.permission_mode(q, v)
      {:dangerously_skip_permissions, true}, q -> Query.dangerously_skip_permissions(q)
      {:dangerously_skip_permissions, false}, q -> q
      {:session_id, v}, q -> Query.session_id(q, v)
      {:continue_session, true}, q -> Query.continue_session(q)
      {:continue_session, false}, q -> q
      {:resume, v}, q -> Query.resume(q, v)
      {:effort, v}, q -> Query.effort(q, v)
      {:json_schema, v}, q -> Query.json_schema(q, v)
      {:agent, v}, q -> Query.agent(q, v)
      {:brief, true}, q -> Query.brief(q)
      {:brief, false}, q -> q
      {:no_session_persistence, true}, q -> Query.no_session_persistence(q)
      {:no_session_persistence, false}, q -> q
      _other, q -> q
    end)
  end
end
