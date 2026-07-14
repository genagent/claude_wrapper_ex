defmodule ClaudeWrapper.Config do
  @moduledoc """
  Shared client configuration for the Claude CLI.

  Equivalent to the Rust `Claude` struct -- holds binary path, working directory,
  environment variables, and default options that apply across all commands.

  ## Usage

      config = ClaudeWrapper.Config.new()
      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")
  """

  @type t :: %__MODULE__{
          binary: String.t(),
          working_dir: String.t() | nil,
          env: [{String.t(), String.t()}],
          timeout: pos_integer() | nil,
          verbose: boolean(),
          debug: boolean()
        }

  defstruct [
    :binary,
    :working_dir,
    :timeout,
    env: [],
    verbose: false,
    debug: false
  ]

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:binary` - Path to the claude binary (default: auto-discover via
      `CLAUDE_CLI`/PATH). Pass the atom `:bundled` to resolve the opt-in
      bundled binary (`ClaudeWrapper.Bundled.path/0`); install it first
      with `mix claude_wrapper.install`.
    * `:working_dir` - Working directory for the subprocess
    * `:env` - List of `{key, value}` environment variable tuples
    * `:timeout` - Command timeout in milliseconds (default `nil`: unbounded).
      Applies to `query/2`, `Command.run/3`, `raw/2`, and the CLI subcommand
      wrappers (via `exec/2`). Streaming (`ClaudeWrapper.stream/2`) is bounded
      only by its per-frame idle deadline, not this whole-run value.
    * `:verbose` - Enable verbose output
    * `:debug` - Enable debug output
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      binary: resolve_binary(opts[:binary]),
      working_dir: opts[:working_dir],
      env: opts[:env] || [],
      timeout: opts[:timeout],
      verbose: Keyword.get(opts, :verbose, false),
      debug: Keyword.get(opts, :debug, false)
    }
  end

  # Resolve the `:binary` option into a concrete path.
  #
  #   * `nil`        -> PATH/`CLAUDE_CLI` auto-discovery (`find_binary/0`)
  #   * `:bundled`   -> the opt-in bundled binary path (pure; install is
  #                     a separate step -- see `ClaudeWrapper.Bundled`)
  #   * a string     -> used verbatim
  defp resolve_binary(nil), do: find_binary()
  defp resolve_binary(:bundled), do: ClaudeWrapper.Bundled.path()
  defp resolve_binary(path) when is_binary(path), do: path

  @doc """
  Find the claude binary path.

  Checks in order:
  1. `CLAUDE_CLI` environment variable
  2. System PATH
  """
  @spec find_binary() :: String.t()
  def find_binary do
    case System.get_env("CLAUDE_CLI") do
      nil -> System.find_executable("claude") || "claude"
      path -> path
    end
  end

  @doc """
  Build the base command args from config (global flags).
  """
  @spec base_args(t()) :: [String.t()]
  def base_args(%__MODULE__{} = config) do
    args = []
    args = if config.verbose, do: args ++ ["--verbose"], else: args
    args = if config.debug, do: args ++ ["--debug"], else: args
    args
  end

  @doc """
  Build the cmd options (working dir, env) for System.cmd/Port.
  """
  @spec cmd_opts(t()) :: keyword()
  def cmd_opts(%__MODULE__{} = config) do
    opts = [stderr_to_stdout: true]
    opts = if config.working_dir, do: [{:cd, config.working_dir} | opts], else: opts
    opts = if config.env != [], do: [{:env, config.env} | opts], else: opts
    opts
  end

  @doc """
  Run a claude subcommand, bounded by `config.timeout`.

  `System.cmd/3` has no timeout, so the CLI subcommand wrappers used it directly
  and a wedged subcommand blocked the calling process forever, silently
  discarding the configured `:timeout`. This runs the command in a `Task` and
  bounds it with `Task.yield/2` + `Task.shutdown/1` (mirroring the one-shot
  `Runner.Port` path), returning `System.cmd/3`'s `{output, exit_code}` on
  completion. On timeout it kills the task and synthesizes `{message, 124}` (124
  is the conventional timeout exit code), so a caller's existing `{_, code}`
  clause surfaces it as a `command_failed` instead of hanging. A `nil` timeout
  (the default) is unbounded, exactly as before. A spawn failure (missing
  binary) still crashes the caller via the task link, as the direct call did.
  """
  @spec exec(t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def exec(%__MODULE__{} = config, args) do
    opts = cmd_opts(config)
    task = Task.async(fn -> System.cmd(config.binary, args, opts) end)

    case Task.yield(task, config.timeout || :infinity) || Task.shutdown(task) do
      {:ok, {output, code}} -> {output, code}
      nil -> {"claude command timed out after #{config.timeout}ms", 124}
    end
  end
end
