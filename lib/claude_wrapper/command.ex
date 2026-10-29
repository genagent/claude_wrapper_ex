defmodule ClaudeWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. This is the Elixir equivalent of the Rust
  `ClaudeCommand` trait.
  """

  alias ClaudeWrapper.{Error, Runner}

  @type args :: [String.t()]

  @callback args() :: args()
  @callback parse_output(stdout :: String.t(), exit_code :: non_neg_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Run a command synchronously through the configured `ClaudeWrapper.Runner`.

  Returns the parsed output on success. On timeout the default runner
  abandons the OS process; `ClaudeWrapper.Runner.Forcola` kills it.

  The runner is `ClaudeWrapper.Runner.impl/1` for `config`. Runner options
  are not supported here: a non-empty `ClaudeWrapper.Runner.options/1`
  returns `{:error, %Error{kind: :invalid_runner_options}}` before spawning.
  """
  @spec run(module(), struct(), ClaudeWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = ClaudeWrapper.Config.base_args(config) ++ mod.args(command)
    opts = ClaudeWrapper.Config.cmd_opts(config)

    with :ok <- reject_runner_options(config, :command) do
      case Runner.impl(config).run(config.binary, all_args, opts, config.timeout) do
        {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
        {:error, :timeout} -> {:error, Error.timeout(config.timeout)}
        {:error, reason} -> {:error, Error.io(reason)}
      end
    end
  end

  @doc false
  # Paths that dispatch through run/4 or stream_lines/4 cannot honor runner
  # options; reject them before spawning instead of silently dropping them.
  @spec reject_runner_options(ClaudeWrapper.Config.t(), atom()) :: :ok | {:error, Error.t()}
  def reject_runner_options(config, mode) do
    if Runner.options(config) == [] do
      :ok
    else
      {:error, Error.new(:invalid_runner_options, reason: {:unsupported_mode, mode})}
    end
  end

  @launcher_script ~S(exec "$@" </dev/null)

  @doc false
  # The `:args` for `Port.open({:spawn_executable, "/bin/sh"}, ...)` that runs
  # `binary` with `args` and stdin from /dev/null. The binary and every
  # argument are positional parameters run as "$@", so nothing is quoted and
  # each one is a separate argv string: Linux's 128 KiB per-string limit
  # applies to each argument, not to the joined command (#305). An empty
  # stdin matters in print mode: Claude Code 2.1.312 waits 3 s for data on an
  # open stdin pipe before it starts (#304).
  @spec launcher_args(String.t(), [String.t()]) :: [String.t()]
  def launcher_args(binary, args), do: ["-c", @launcher_script, "claude-wrapper", binary | args]

  # A conservative allowlist of shell-safe characters. Anything else -- and the
  # empty string -- gets single-quoted below.
  @safe_arg ~r/\A[A-Za-z0-9_@%+=:,.\/-]+\z/

  @doc false
  # Single-quote every argument except strictly-safe tokens (kept bare for
  # readable debug output). The old denylist missed metacharacters like
  # `> < * ? [ ] { } ~` and left the empty string unquoted, so on the /bin/sh
  # streaming path a space-free redirection token could truncate a file and an
  # empty arg (e.g. hermetic's `--setting-sources ""`) vanished under
  # word-splitting -- diverging from the execve-based one-shot path. An
  # allowlist closes the whole class at once.
  def shell_escape(arg) do
    if Regex.match?(@safe_arg, arg) do
      arg
    else
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    end
  end
end
