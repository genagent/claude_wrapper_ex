defmodule ClaudeWrapper.Command do
  @moduledoc """
  Behaviour for CLI commands.

  Every command knows how to build its argument list and how to
  parse its output. This is the Elixir equivalent of the Rust
  `ClaudeCommand` trait.
  """

  alias ClaudeWrapper.Error

  @type args :: [String.t()]

  @callback args() :: args()
  @callback parse_output(stdout :: String.t(), exit_code :: non_neg_integer()) ::
              {:ok, term()} | {:error, term()}

  @doc """
  Run a command synchronously via System.cmd.

  Returns the parsed output on success.
  """
  @spec run(module(), struct(), ClaudeWrapper.Config.t()) :: {:ok, term()} | {:error, term()}
  def run(mod, command, config) do
    all_args = ClaudeWrapper.Config.base_args(config) ++ mod.args(command)
    opts = ClaudeWrapper.Config.cmd_opts(config)

    opts =
      if config.timeout do
        # System.cmd doesn't support timeout directly, we use Task
        opts
      else
        opts
      end

    execute_cmd(mod, config.binary, all_args, opts, config.timeout)
  end

  defp execute_cmd(mod, binary, args, opts, nil) do
    case System.cmd(binary, args, opts) do
      {stdout, 0} -> mod.parse_output(stdout, 0)
      {stdout, code} -> mod.parse_output(stdout, code)
    end
  rescue
    e in ErlangError -> {:error, Error.io(e)}
  end

  defp execute_cmd(mod, binary, args, opts, timeout) do
    task = Task.async(fn -> System.cmd(binary, args, opts) end)

    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {stdout, code}} -> mod.parse_output(stdout, code)
      nil -> {:error, Error.timeout(timeout)}
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

  @doc false
  def shell_escape(arg) do
    if String.contains?(arg, ["'", " ", "\"", "\\", "(", ")", "$", "`", "!", "&", "|", ";", "\n"]) do
      "'" <> String.replace(arg, "'", "'\\''") <> "'"
    else
      arg
    end
  end
end
