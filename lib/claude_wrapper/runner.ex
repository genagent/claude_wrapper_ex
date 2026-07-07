defmodule ClaudeWrapper.Runner do
  @moduledoc """
  How `claude` subprocesses are executed.

  Two shapes cover the non-duplex paths: a bounded one-shot `run/4` and
  an NDJSON `stream_lines/4`. The default implementation is
  `ClaudeWrapper.Runner.Port`, the `System.cmd`/`Port` code the library
  has always used.

  For leak-free execution -- where a timeout, a halted stream, or BEAM
  death kills the whole `claude` process group (the CLI and every stdio
  MCP server it spawned) rather than abandoning it -- add
  [`forcola`](https://hex.pm/packages/forcola) to your deps and select
  its runner:

      # mix.exs
      {:forcola, "~> 0.3"}

      # config/config.exs
      config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola

  `Runner.Forcola` only compiles when `forcola` is present, so the
  dependency stays optional. See the "Error handling" and leak-free
  sections of the README, and #185.

  ## Contract

  `run/4` returns `System.cmd/3`'s `{stdout, exit_code}` on completion
  (a non-zero exit is *not* an error -- callers decide what an exit code
  means), `{:error, :timeout}` when the timeout elapsed, and other
  `{:error, reason}` tuples for spawn/io failures. `stream_lines/4`
  returns a lazy `Enumerable` of complete stdout lines (no trailing
  newline); the caller parses each line.
  """

  @typedoc "Runner error reasons. `:timeout` is common to both runners."
  @type error ::
          :timeout
          | {:signal, term()}
          | {:spawn, term()}
          | {:io, term()}

  @typedoc """
  Execution options, a subset of `System.cmd/3`'s:

    * `:cd` -- working directory (string) or `nil`
    * `:env` -- list of `{name, value}` string tuples
    * `:stderr_to_stdout` -- merge stderr into stdout (default `false`)
  """
  @type opts :: keyword()

  @callback run(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: {:ok, {String.t(), non_neg_integer()}} | {:error, error()}

  @callback stream_lines(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: Enumerable.t()

  @doc """
  The configured runner module, `ClaudeWrapper.Runner.Port` by default.

  Set with `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola`.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Port)
  end
end
