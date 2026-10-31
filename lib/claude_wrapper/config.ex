defmodule ClaudeWrapper.Config do
  @moduledoc """
  Shared client configuration for the Claude CLI.

  Equivalent to the Rust `Claude` struct -- holds binary path, working directory,
  environment variables, and default options that apply across all commands.

  ## Usage

      config = ClaudeWrapper.Config.new()
      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")

  ## Per-config runner

  A config can carry its own `:runner` and `:runner_options`, so two configs
  for the same provider (different binaries, working directories, endpoints,
  credentials, MCP files or config roots) can run side by side without
  touching application or OS environment state:

      a = ClaudeWrapper.Config.new(
        binary: "/opt/claude-a/bin/claude",
        env: [{"CLAUDE_CONFIG_DIR", "/srv/a/.claude"}],
        runner: ClaudeWrapper.Runner.Forcola,
        runner_options: [idle_timeout_ms: 120_000, max_output_bytes: 8_388_608]
      )

  Each field falls back to the application default
  (`config :claude_wrapper, runner: ...` / `runner_options: ...`) only when
  it is absent. An explicit `runner_options: []` overrides a configured
  default with no options. The struct is immutable; resolution happens per
  execution through `ClaudeWrapper.Runner.impl/1` and
  `ClaudeWrapper.Runner.options/1`.
  """

  @type t :: %__MODULE__{
          binary: String.t(),
          working_dir: String.t() | nil,
          env: [{String.t(), String.t() | nil}],
          timeout: pos_integer() | nil,
          verbose: boolean(),
          debug: boolean(),
          runner: module() | nil,
          runner_options: keyword() | nil,
          release_env: :scrub | :inherit
        }

  defstruct [
    :binary,
    :working_dir,
    :timeout,
    :runner,
    :runner_options,
    env: [],
    verbose: false,
    debug: false,
    release_env: :scrub
  ]

  @doc """
  Create a new config from keyword options.

  ## Options

    * `:binary` - Path to the claude binary (default: auto-discover via
      `CLAUDE_CLI`/PATH). Pass the atom `:bundled` to resolve the opt-in
      bundled binary (`ClaudeWrapper.Bundled.path/0`); install it first
      with `mix claude_wrapper.install`.
    * `:working_dir` - Working directory for the subprocess
    * `:env` - List of `{name, value}` environment variable tuples added to
      the inherited environment. A value of `nil` (or `false`, normalized to
      `nil`) removes the variable from the child's environment on every
      spawn path (#309). Names must be non-empty strings without `=`;
      anything else raises `ArgumentError`.
    * `:release_env` - `:scrub` (default) or `:inherit`. When the VM runs
      from a mix release (`RELEASE_ROOT` is set), `:scrub` removes release
      boot variables and release `PATH` entries from the child's
      environment on every spawn path, before `:env` is applied; see
      `ClaudeWrapper.ChildEnv`. It has no effect outside a release.
    * `:timeout` - Command timeout in milliseconds (default `nil`: unbounded).
      In print mode the CLI waits for background tasks after the prompt's
      turn, and runs a further turn for each one that finishes, before it
      exits; that wait (up to `CLAUDE_CODE_PRINT_BG_WAIT_CEILING_MS`, 600000
      ms by default in Claude Code 2.1.312) counts against this timeout.
      Applies to `query/2`, `Command.run/3`, `raw/2`, and the CLI subcommand
      wrappers (via `exec/2`). For `ClaudeWrapper.stream/2`, a finite value
      bounds both the whole run and each gap between output frames. Without
      one, streaming retains its per-frame idle safety deadline.
    * `:verbose` - Enable verbose output
    * `:debug` - Enable debug output
    * `:runner` - A `ClaudeWrapper.Runner` module for this config (default
      `nil`: the `:runner` application env, then `ClaudeWrapper.Runner.Port`)
    * `:runner_options` - A keyword list of runner options for this config
      (default `nil`: the `:runner_options` application env, then `[]`). An
      explicit `[]` disables configured defaults. Runner options are honored
      only by evidenced one-shot execution (`Query.execute/2,3` through a
      runner implementing `c:ClaudeWrapper.Runner.run_evidenced/5`); other
      runner paths and `ClaudeWrapper.DuplexSession` reject non-empty
      options before spawning. See
      `ClaudeWrapper.Runner.Forcola` for the keys it accepts.

  Raises `ArgumentError` when `:runner` is not a module atom or
  `:runner_options` is not a keyword list with unique keys.
  """
  @spec new(keyword()) :: t()
  def new(opts \\ []) do
    %__MODULE__{
      binary: resolve_binary(opts[:binary]),
      working_dir: opts[:working_dir],
      env: validate_env!(opts[:env] || []),
      timeout: opts[:timeout],
      verbose: Keyword.get(opts, :verbose, false),
      debug: Keyword.get(opts, :debug, false),
      runner: validate_runner!(opts[:runner]),
      runner_options: validate_runner_options!(opts[:runner_options]),
      release_env: validate_release_env!(Keyword.get(opts, :release_env, :scrub))
    }
  end

  defp validate_runner!(nil), do: nil

  defp validate_runner!(runner) when is_atom(runner) and runner not in [true, false] do
    runner
  end

  defp validate_runner!(other),
    do: raise(ArgumentError, "runner must be a module, got: #{inspect(other)}")

  defp validate_runner_options!(nil), do: nil

  defp validate_runner_options!(options) do
    if keyword_options?(options) do
      options
    else
      raise ArgumentError,
            "runner_options must be a keyword list with unique keys, got: #{inspect(options)}"
    end
  end

  @doc false
  @spec keyword_options?(term()) :: boolean()
  def keyword_options?(options) when is_list(options) do
    keys = if Keyword.keyword?(options), do: Keyword.keys(options), else: nil
    keys != nil and Enum.uniq(keys) == keys
  end

  def keyword_options?(_options), do: false

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

  @doc false
  # `Config.env` as `Port.open/2` takes it: charlist pairs, with `false` (or
  # `nil`, which `System.cmd/3` treats as unset) unsetting a variable. Shared
  # by Runner.Port and Adapter.Port.
  @spec port_env([{String.t(), String.t() | false | nil}]) :: [{charlist(), charlist() | false}]
  def port_env(env),
    do: Enum.map(env, fn {key, value} -> {to_charlist(key), port_value(value)} end)

  defp port_value(unset) when unset in [false, nil], do: false
  defp port_value(value), do: to_charlist(value)

  @doc """
  Build the cmd options (working dir, env) for System.cmd/Port.
  """
  @spec cmd_opts(t()) :: keyword()
  def cmd_opts(%__MODULE__{} = config) do
    opts = [stderr_to_stdout: true]
    opts = if config.working_dir, do: [{:cd, config.working_dir} | opts], else: opts
    env = child_env(config)
    opts = if env != [], do: [{:env, cmd_env(env)} | opts], else: opts
    opts
  end

  @doc false
  # The environment entries every spawn path applies: the release scrub
  # (unless `release_env: :inherit`), then `Config.env` (#310).
  @spec child_env(t()) :: [{String.t(), String.t() | nil}]
  def child_env(%__MODULE__{release_env: :inherit, env: env}), do: env
  def child_env(%__MODULE__{env: env}), do: ClaudeWrapper.ChildEnv.apply(env)

  defp validate_release_env!(mode) when mode in [:scrub, :inherit], do: mode

  defp validate_release_env!(mode),
    do: raise(ArgumentError, ":release_env must be :scrub or :inherit, got: #{inspect(mode)}")

  # `System.cmd/3` unsets a variable given `nil`; a struct built without
  # new/1 may still carry `false`.
  defp cmd_env(env), do: Enum.map(env, fn {name, value} -> {name, value || nil} end)

  defp validate_env!(env) when is_list(env), do: Enum.map(env, &validate_env_entry!/1)

  defp validate_env!(env),
    do: raise(ArgumentError, ":env must be a list of {name, value} tuples, got: #{inspect(env)}")

  defp validate_env_entry!({name, value}) when is_binary(name) and name != "" do
    cond do
      String.contains?(name, "=") ->
        raise ArgumentError, "invalid :env name #{inspect(name)}"

      is_binary(value) or is_nil(value) ->
        {name, value}

      value == false ->
        {name, nil}

      true ->
        raise ArgumentError, "invalid :env value for #{inspect(name)}: #{inspect(value)}"
    end
  end

  defp validate_env_entry!(entry),
    do: raise(ArgumentError, "invalid :env entry #{inspect(entry)}")

  @doc false
  # For a spawner that only takes string values (Forcola): split `Config.env`
  # into the pairs to set and an argv whose unset names become an
  # `/usr/bin/env -u NAME ...` prefix. env execs the command, so the pid and
  # process group are unchanged.
  @spec split_env_argv([String.t()], list()) :: {[String.t()], [{String.t(), String.t()}]}
  def split_env_argv(argv, env) do
    {set, unset} = Enum.split_with(env, fn {_name, value} -> is_binary(value) end)

    case Enum.map(unset, &elem(&1, 0)) do
      [] -> {argv, set}
      names -> {["/usr/bin/env" | Enum.flat_map(names, &["-u", &1])] ++ argv, set}
    end
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

  Killing the task on timeout closes the pipes but sends no signal to the
  subcommand, unlike the `Runner.Port` paths (#303); subcommands are short
  and do not run model turns.

  This helper calls `System.cmd/3` directly and does not dispatch through
  `config.runner`. Because it cannot honor runner options (for example
  `env_mode: :replace`), it raises `ArgumentError` before spawning when the
  resolved `ClaudeWrapper.Runner.options/1` is non-empty, rather than
  silently running without them.
  """
  @spec exec(t(), [String.t()]) :: {String.t(), non_neg_integer()}
  def exec(%__MODULE__{} = config, args) do
    if ClaudeWrapper.Runner.options(config) != [] do
      raise ArgumentError,
            "runner_options are only supported by evidenced one-shot Query execution; " <>
              "Config.exec/2 cannot honor them"
    end

    opts = cmd_opts(config)
    task = Task.async(fn -> System.cmd(config.binary, args, opts) end)

    case Task.yield(task, config.timeout || :infinity) || Task.shutdown(task) do
      {:ok, {output, code}} -> {output, code}
      nil -> {"claude command timed out after #{config.timeout}ms", 124}
    end
  end
end
