defmodule ClaudeWrapper.Runner do
  @moduledoc """
  How `claude` subprocesses are executed.

  Two shapes cover the non-duplex paths: a bounded one-shot `run/4` and
  an NDJSON `stream_lines/4`. The default implementation is
  `ClaudeWrapper.Runner.Port`, which runs the CLI under a `/bin/sh`
  supervisor that signals it (SIGINT, SIGTERM, SIGKILL) when a timeout, a
  halted stream or BEAM death ends the run early.

  For leak-free execution -- where those events kill the whole `claude`
  process group (the CLI and every stdio MCP server it spawned) rather than
  only the CLI -- add
  [`forcola`](https://hex.pm/packages/forcola) to your deps and select
  its runner:

      # mix.exs
      {:forcola, "~> 0.7.0"}

      # config/config.exs
      config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola

  `Runner.Forcola` only compiles when `forcola` is present, so the
  dependency stays optional. See the "Error handling" and leak-free
  sections of the README, and #185.

  ## Runner selection

  `impl/1` and `options/1` resolve the runner and its options for one
  `ClaudeWrapper.Config`. A config's own `:runner` / `:runner_options` win;
  the `:runner` / `:runner_options` application env is used only when the
  config field is `nil`. An explicit `runner_options: []` therefore disables
  configured default options. Nothing in this library writes application or
  OS environment state to select a runner.

  Runner options are honored only by `c:run_evidenced/5`. `run/4`,
  `stream_lines/4` and `run_observed/5` take no runner options, so the paths
  that dispatch through them (`ClaudeWrapper.Command.run/3`,
  `ClaudeWrapper.raw/2`, `Query.stream/2`) reject a non-empty resolved
  option list before spawning instead of silently ignoring it.
  `ClaudeWrapper.DuplexSession.start_link/1` rejects one the same way before
  opening any duplex adapter.

  ## Observed execution

  `run_observed/5` is optional. It runs to transport completion while calling
  a trusted, nonblocking line observer with stdout lines only. The observer
  returns `:continue`, `:observed` to stop observing, or
  `{:continue, next_observer}` to replace itself with an observer carrying
  updated state. The runner must not call it again after `:observed`. It must execute synchronously
  in the process calling `run_observed/5`, before that function returns.
  This is an internal execution
  seam, not an API for caller-supplied callbacks.

  Observed output is `{stdout, exit_code, stderr}` with newline-normalized
  stdout. Stderr stays separate and must never be passed to the observer.
  Forcola captures stderr on nonzero completion; clean completion returns an
  empty stderr field. The same whole-run deadline and cleanup as `run/4`
  apply. Unsupported runners are rejected by `Query.execute/3` before spawn.

  ## Evidenced execution

  `Query` converts raises, throws and catchable exits from `run_evidenced/5`
  into typed `:io` errors (`{:runner_failed, kind, reason}`), retaining the
  first observed native ID and bounded observed stdout in terminal evidence.
  Legacy callbacks keep their exception behavior. Collector observer failures
  return `{:observer_failed, kind, reason}` after draining the native run.

  `run_evidenced/5` is optional and one-shot only. It has the same observer
  contract as `run_observed/5` (trusted, invoked in the calling process
  before the function returns, stdout only) and additionally:

    * receives the resolved runner options under `opts[:runner_options]`
      and must reject unknown or invalid options, and any option it cannot
      enforce, before spawning (`{:error, {:invalid_runner_options, reason}}`
      or `{:error, {:evidence_unsupported, reason}}`), never by silently
      running without them;
    * returns `{outcome, evidence}`, where `outcome` uses the
      `run_observed/5` shapes plus the bounded-execution errors below, and
      `evidence` is a `t:native_evidence/0` map recording what the native
      layer reported, independently of `outcome`.

  Evidence fields are separate facts. A terminal JSON result, a session ID,
  exhausted output or a zero child exit status does not imply confirmed
  cleanup. Fields the runner could not observe are `:unknown`; fields that
  do not apply because nothing was spawned are `:not_applicable`.
  `Query.execute/2,3` select this callback when the call has an
  `:execution_observer` or the config resolves non-empty runner options. A
  runner without it is rejected before it is invoked; there is no fallback
  to another runner or callback.

  ## Contract

  `run/4` returns `System.cmd/3`'s `{stdout, exit_code}` on completion
  (a non-zero exit is *not* an error -- callers decide what an exit code
  means), `{:error, :timeout}` when the timeout elapsed, and other
  `{:error, reason}` tuples for spawn/io failures. `stream_lines/4`
  returns a lazy `Enumerable` of complete stdout lines (no trailing
  newline); the caller parses each line. A finite streaming timeout bounds
  both the whole run and each gap between lines. Without one, implementations
  retain their idle safety deadline.
  """

  @typedoc "Runner error reasons. `:timeout` is common to both runners."
  @type error ::
          :timeout
          | {:signal, term()}
          | {:spawn, term()}
          | {:io, term()}

  @typedoc """
  Additional `run_evidenced/5` error reasons.

    * `:idle_timeout` -- no output for the configured idle bound
    * `{:limit, :max_output_bytes | :observer_overflow}` -- an output bound
      cancelled the run
    * `{:invalid_runner_options, reason}` -- rejected before spawning
    * `{:evidence_unsupported, reason}` -- the runner or its dependency
      cannot enforce evidenced execution; rejected before spawning
    * `{:runner_failed, kind, reason}` -- a runner callback raised, threw or
      exited; `Query` converts it to a typed `:io` error
    * `{:observer_failed, kind, reason}` -- a collector observer failed;
      the owned native run is drained before returning
    * `{:helper_down, reason}` -- the runner's collector process died before
      reporting an outcome
  """
  @type evidenced_error ::
          {:runner_failed, :error | :throw | :exit, term()}
          | {:observer_failed, :error | :throw | :exit, term()}
          | error()
          | :idle_timeout
          | {:limit, :max_output_bytes | :observer_overflow}
          | {:invalid_runner_options, term()}
          | {:evidence_unsupported, term()}
          | {:helper_down, term()}

  @typedoc """
  Native execution evidence returned by `run_evidenced/5`.

    * `:execution` -- `:started` when a child is known to have been spawned,
      `:not_started` when the runner knows it was not, `:unknown` otherwise
    * `:child_status` / `:child_signal` -- raw direct-child exit status or
      signal number, `nil` when not reported
    * `:termination` -- how the native layer ended (runner-specific, for
      example `:exit`, `:malformed_exit`, `:backstop`, `{:transport, status}`,
      `{:spawn, reason}`), `:not_started`, or `:unknown`
    * `:reason` -- `nil` or the bound that cancelled the run (`:timeout`,
      `:idle_timeout`, `:max_output_bytes`, `:observer_overflow`)
    * `:output_truncated` -- `true`, `false`, or `:unknown`
    * `:cleanup` -- `:confirmed`, `:unconfirmed`, `:unknown`, or
      `:not_applicable`
    * `:scope` -- what a cleanup confirmation covers: `:process_group`,
      `:active_cgroup`, `:unknown`, or `:not_applicable`. A process-group
      confirmation says nothing about descendants that left the group.
    * `:guard_close` -- the transport close result, separate from cleanup
      (`:ok`, `{:error, reason}`, `:unknown`, or `:not_applicable`)
    * `:stdout` / `:stderr` -- the retained (bounded when the runner bounds
      output) bytes, including after a failure
    * `:lines_dropped` -- stdout lines withheld from the observer because they
      exceeded the runner's per-line bound
  """
  @type native_evidence :: %{
          execution: :started | :not_started | :unknown,
          child_status: non_neg_integer() | nil,
          child_signal: pos_integer() | nil,
          termination: term(),
          reason: nil | :timeout | :idle_timeout | :max_output_bytes | :observer_overflow,
          output_truncated: boolean() | :unknown,
          cleanup: :confirmed | :unconfirmed | :unknown | :not_applicable,
          scope: :process_group | :active_cgroup | :unknown | :not_applicable,
          guard_close: :ok | {:error, term()} | :unknown | :not_applicable,
          stdout: binary(),
          stderr: binary(),
          lines_dropped: non_neg_integer()
        }

  @typedoc """
  Execution options, a subset of `System.cmd/3`'s:

    * `:cd` -- working directory (string) or `nil`
    * `:env` -- list of `{name, value}` string tuples
    * `:stderr_to_stdout` -- merge stderr into stdout (default `false`)

  `run_evidenced/5` additionally receives `:runner_options`.
  """
  @type opts :: keyword()

  @callback run(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: {:ok, {String.t(), non_neg_integer()}} | {:error, error()}

  @typedoc "A trusted stdout line observer constructed by Query."
  @type line_observer ::
          (String.t() -> :continue | :observed | {:continue, line_observer()})

  @callback run_observed(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil,
              observer :: line_observer()
            ) :: {:ok, {String.t(), non_neg_integer(), String.t()}} | {:error, error()}

  @typedoc "What `run_evidenced/5` returns: the outcome and its native evidence."
  @type evidenced_result ::
          {{:ok, {String.t(), non_neg_integer(), String.t()}} | {:error, evidenced_error()},
           native_evidence()}

  @callback run_evidenced(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil,
              observer :: line_observer()
            ) :: evidenced_result()

  @optional_callbacks run_observed: 5, run_evidenced: 5

  @callback stream_lines(
              binary :: String.t(),
              args :: [String.t()],
              opts :: opts(),
              timeout :: timeout() | nil
            ) :: Enumerable.t()

  @doc """
  The application-configured runner module, `ClaudeWrapper.Runner.Port` by
  default.

  Set with `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola`.
  Prefer `impl/1`, which also honors a per-config `:runner`.
  """
  @spec impl() :: module()
  def impl do
    Application.get_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Port)
  end

  @doc """
  The runner for `config`: `config.runner` when set, otherwise `impl/0`.
  """
  @spec impl(ClaudeWrapper.Config.t()) :: module()
  def impl(%ClaudeWrapper.Config{runner: nil}), do: impl()
  def impl(%ClaudeWrapper.Config{runner: runner}), do: runner

  @doc """
  The runner options for `config`: `config.runner_options` when set
  (including an explicit `[]`), otherwise the `:runner_options` application
  env, otherwise `[]`.
  """
  @spec options(ClaudeWrapper.Config.t()) :: keyword()
  def options(%ClaudeWrapper.Config{runner_options: nil}),
    do: Application.get_env(:claude_wrapper, :runner_options, [])

  def options(%ClaudeWrapper.Config{runner_options: options}), do: options

  @doc """
  Empty evidence for an execution that was never started.

  Used when a request is rejected before any runner spawns a process, so no
  native status or cleanup fact is fabricated.
  """
  @spec not_started_evidence() :: native_evidence()
  def not_started_evidence do
    %{
      execution: :not_started,
      child_status: nil,
      child_signal: nil,
      termination: :not_started,
      reason: nil,
      output_truncated: false,
      cleanup: :not_applicable,
      scope: :not_applicable,
      guard_close: :not_applicable,
      stdout: "",
      stderr: "",
      lines_dropped: 0
    }
  end
end
