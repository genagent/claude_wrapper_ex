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

  # Seconds the watchdog waits after SIGINT before SIGTERM, and after SIGTERM
  # before SIGKILL; and how long a duplex lifeline lets an idle claude exit on
  # its own stdin EOF before the first signal. Fixed: the cleanup schedule is
  # not a configuration surface.
  @int_grace_s 2
  @term_grace_s 1
  @close_grace_s 1

  @doc false
  # The `:args` for `Port.open({:spawn_executable, "/bin/sh"}, ...)` that runs
  # `binary` with `args`, stdin from /dev/null, and stops it when the port
  # goes away (#303). The binary and every argument are positional
  # parameters run as "$@", so nothing is quoted and each one is a separate
  # argv string: Linux's 128 KiB per-string limit applies to each argument,
  # not to the joined command (#305). An empty stdin matters in print mode:
  # Claude Code 2.1.312 waits 3 s for data on an open stdin pipe (#304).
  #
  # The shell is a small supervisor with three processes, ported from
  # codex_wrapper_ex (genagent/codex_wrapper_ex#125, #138):
  #
  #   * the target, a background job started from "$@";
  #   * a watchdog subshell that blocks in `read` on the port's stdin, which
  #     the supervisor saved on fd 3 before backgrounding anything. The BEAM
  #     holds the only write end and never writes, so EOF means the port was
  #     closed (timeout, stream halt) or the BEAM died;
  #   * the supervisor itself, which waits for the target, keeps its exit
  #     status, and kills and reaps the watchdog.
  #
  # On EOF the watchdog signals the target's pid: INT, TERM after
  # @int_grace_s, KILL after a further @term_grace_s. Only the target is
  # signalled; descendants it does not stop itself (stdio MCP servers in its
  # process group) are not, which is what Runner.Forcola's group kill adds.
  # A POSIX non-interactive shell starts a background job with SIGINT
  # ignored; a target that installs its own SIGINT handler still gets INT,
  # one that does not stops at the TERM step.
  #
  # Signalling is by pid, so a pid recycled between the target's exit and the
  # watchdog's kill is a residual risk; the supervisor kills the watchdog as
  # soon as the target is reaped, which keeps that window short. /bin/sleep
  # is absolute because callers may replace PATH. TERM keeps its default
  # action while the watchdog waits in `read`, and the trap that turns a
  # cancellation into a flag is installed only once escalation starts: a
  # trapped TERM that arrives just before `read` blocks would otherwise be
  # deferred until an EOF that never comes (genagent/codex_wrapper_ex#134). A
  # USR1 handshake makes the supervisor wait until the watchdog runs before a
  # quick target's exit can cancel it.
  @spec launcher_args(String.t(), [String.t()]) :: [String.t()]
  def launcher_args(binary, args),
    do: ["-c", supervisor_script(), "claude-wrapper", binary | args]

  defp supervisor_script do
    """
    watcher_ready=0
    trap 'watcher_ready=1' USR1
    supervisor=$$
    exec 3<&0
    "$@" </dev/null 3<&- &
    t=$!
    (
      kill -s USR1 "$supervisor" || exit 0
      while read -r _line; do :; done
      stopping=0
      trap 'stopping=1' TERM
      kill -s INT "$t" || exit 0
      [ -x /bin/sleep ] || exit 0
      [ "$stopping" = 0 ] || exit 0
      /bin/sleep #{@int_grace_s}
      [ "$stopping" = 0 ] || exit 0
      kill -s TERM "$t" || exit 0
      /bin/sleep #{@term_grace_s}
      [ "$stopping" = 0 ] || exit 0
      kill -s KILL "$t"
      exit 0
    ) <&3 3<&- >/dev/null 2>&1 &
    w=$!
    while [ "$watcher_ready" = 0 ]; do
      kill -0 "$w" || break
    done
    trap - USR1
    exec 3<&- >/dev/null 2>&1
    wait "$t"
    s=$?
    kill "$w"
    wait "$w"
    exit "$s"
    """
  end

  # Through a shell a missing binary would only show up as exit status 127,
  # so check it here and keep the typed `:binary_not_found` signal (#200)
  # that run_cmd turns into `%Error{kind: :binary_not_found}`. A path with a
  # `/` is resolved against the VM's working directory, as `System.cmd/3`
  # did; a bare name is looked up on `PATH`.
  @doc false
  @spec resolve_executable(String.t()) ::
          {:ok, String.t()} | {:error, {:binary_not_found, :enoent | :eacces}}
  def resolve_executable(binary) do
    if String.contains?(binary, "/") do
      path = Path.expand(binary)

      case File.stat(path) do
        {:ok, %File.Stat{type: :regular, mode: mode}} when Bitwise.band(mode, 0o111) != 0 ->
          {:ok, path}

        {:ok, _stat} ->
          {:error, {:binary_not_found, :eacces}}

        {:error, _reason} ->
          {:error, {:binary_not_found, :enoent}}
      end
    else
      case System.find_executable(binary) do
        nil -> {:error, {:binary_not_found, :enoent}}
        path -> {:ok, path}
      end
    end
  end

  @doc false
  # The `:args` for a duplex session's lifeline port (#303). A duplex session
  # uses claude's stdin for the protocol, so the lifeline is a second port
  # whose stdin the BEAM holds. EOF there (the adapter closed the session, or
  # the BEAM died) gives an idle claude @close_grace_s to exit on its own
  # stdin EOF, then sends INT, TERM and KILL to `os_pid` with the same graces
  # as launcher_args/2. Each step first checks that the pid is still alive,
  # so after a normal exit (the session stops and the lifeline closes) no
  # signal is sent. The same pid-reuse caveat applies. The script keeps its
  # stdout open (it never writes to it): when a port's output closes, the VM
  # closes the port, and so the lifeline's stdin, which would read as EOF.
  @spec lifeline_args(non_neg_integer()) :: [String.t()]
  def lifeline_args(os_pid) when is_integer(os_pid) do
    script = """
    t=$1
    exec 2>/dev/null
    while read -r _line; do :; done
    [ -x /bin/sleep ] || exit 0
    kill -0 "$t" || exit 0
    /bin/sleep #{@close_grace_s}
    kill -0 "$t" || exit 0
    kill -s INT "$t"
    /bin/sleep #{@int_grace_s}
    kill -0 "$t" || exit 0
    kill -s TERM "$t"
    /bin/sleep #{@term_grace_s}
    kill -0 "$t" || exit 0
    kill -s KILL "$t"
    """

    ["-c", script, "claude-wrapper-lifeline", Integer.to_string(os_pid)]
  end

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
