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
  """
  @spec run(module(), struct(), ClaudeWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = ClaudeWrapper.Config.base_args(config) ++ mod.args(command)
    opts = ClaudeWrapper.Config.cmd_opts(config)

    case Runner.impl().run(config.binary, all_args, opts, config.timeout) do
      {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
      {:error, :timeout} -> {:error, Error.timeout(config.timeout)}
      {:error, reason} -> {:error, Error.io(reason)}
    end
  end

  # Build the `:args` list for a `Port.open({:spawn_executable, "/bin/sh"}, ...)`
  # call that runs `binary` with `args` and redirects stdin from `/dev/null`.
  # Used by streaming paths (`Query.stream/2`) to prevent the CLI from
  # blocking on an inherited-but-empty stdin pipe. `System.cmd`-based
  # callers (the non-streaming `execute` path) close stdin automatically
  # and do not need this.
  @doc false
  @spec shell_cmd_args(String.t(), [String.t()]) :: [String.t()]
  def shell_cmd_args(binary, args) do
    escaped_args = Enum.map_join(args, " ", &shell_escape/1)
    shell_cmd = "#{binary} #{escaped_args} < /dev/null"
    ["-c", shell_cmd]
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
