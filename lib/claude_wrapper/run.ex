defmodule ClaudeWrapper.Run do
  @moduledoc """
  A handle for one evidenced one-shot run that does not block the caller.

  `Query.execute/3` blocks until the run ends. `start/3` runs the same
  evidenced execution (see "Evidenced execution" in `Query.execute/3`) in
  a separate process and returns a handle that can be inspected, awaited and
  cancelled:

      {:ok, run} = ClaudeWrapper.Run.start(query, config)

      %{status: :running, session_id: sid, frames: n} = ClaudeWrapper.Run.snapshot(run)

      case ClaudeWrapper.Run.await(run, 300_000) do
        {:ok, %ClaudeWrapper.Result{} = result, %ClaudeWrapper.ExecutionEvidence{}} -> result
        {:error, %ClaudeWrapper.Error{} = error, %ClaudeWrapper.ExecutionEvidence{}} -> error
        :timeout -> ClaudeWrapper.Run.cancel(run)
      end

  The runner must implement `c:ClaudeWrapper.Runner.run_evidenced/5`
  (currently `ClaudeWrapper.Runner.Forcola`).

  ## Starting

  `start/3` takes the `Query.execute/3` options (`:session_observer`,
  `:rate_limit_observer`, `:execution_observer`) plus:

    * `:events_to` -- the pid that receives frames, default the caller.
      `nil` disables frame delivery.
    * `:max_queued_frames` -- the mailbox bound for frame delivery (see
      below), default `1_000`.
    * `:cancel_grace_ms` -- how long a cancelled run waits for the runner to
      stop before the run process ends the execution process itself,
      default `10_000`.

  Before anything is spawned, `start/3` returns `{:error, %Error{}}` for the
  same rejections as `Query.execute/3`: malformed, unknown or duplicate
  options, invalid observers (`:invalid_session_observer`,
  `:invalid_rate_limit_observer`, `:invalid_execution_observer`), a runner
  without `run_evidenced/5` (`:evidence_unsupported`), invalid runner options
  (`:invalid_runner_options`, through the runner's optional
  `c:ClaudeWrapper.Runner.check_evidenced/2`), and a spawn target that cannot
  be built (`:argument_list_too_long`, `:binary_not_found` for stdin
  prompts). Invalid run options return `:invalid_run_options`. As with
  `Query.execute/3`, a valid `:execution_observer` receives one not-started
  record for each of these rejections.

  `start/3` returns once the run process has started the execution. It does
  not wait for the native child: a spawn failure reported by the runner
  arrives through `await/2` as an error with its evidence.

  ## Frames

  Every stdout line that parses as a stream-json event is sent to
  `:events_to` as `{run.ref, {:frame, %ClaudeWrapper.StreamEvent{}}}`, in
  stream order. After the last frame, `{run.ref, {:done, status}}` is sent,
  where `status` is the final status of `snapshot/1`.

  Delivery is unacknowledged and the run never waits for the recipient.
  Mailbox policy for a slow recipient: before each frame, the run process
  reads the recipient's message queue length; at `:max_queued_frames` or
  more, the frame is dropped and counted in `snapshot/1`'s
  `:frames_dropped`. Frames that are delivered keep their order. The full
  stdout is retained in the evidence record, bounded by the runner.

  ## Await and cancel

  The run process sends every observer message for the run: the
  `%SessionObservation{}` for the first nonblank native session ID, a
  `%RateLimitObservation{}` for each valid rate-limit event, and the one
  terminal `%ExecutionEvidence{}` record, in that order, with the same
  shapes as `Query.execute/3`.

  `await/2` returns `{:ok, %Result{}, %ExecutionEvidence{}}` or
  `{:error, %Error{}, %ExecutionEvidence{}}`, with the same `Result` and
  `Error` categories as `Query.execute/3` plus `:cancelled`. Each run has
  exactly one evidence record; every `await/2` and `cancel/2` returns that
  same record, and a valid `:execution_observer` receives it once. An
  `await/2` that times out returns `:timeout` and leaves the run going.

  `cancel/2` asks the runner to stop the run and returns its outcome and
  evidence. Cancellation starts native termination; it does not mean native
  cleanup has finished when `cancel/2` returns. A run whose runner returned
  before the cancel took effect keeps its own outcome: the execution process
  reports it before `[:claude_wrapper, :exec, :stop]` telemetry handlers run,
  so a slow handler cannot turn it into a cancellation. Otherwise the outcome
  is `{:error, %Error{kind: :cancelled}, evidence}`
  with `evidence.reason == :cancelled` and the cleanup facts the runner
  reported. `ClaudeWrapper.Runner.Forcola` stops the run by closing its
  Forcola port, so the shim runs its owner-death sequence (the configured
  interrupt, then TERM/KILL of the process group); Forcola 0.7 sends no
  report after that, so `:cleanup` is `:unknown`. If the runner does not
  stop within `:cancel_grace_ms`, the run process ends the execution process
  and records `reason: :cancelled` with unknown native facts. `cancel/2` is
  idempotent: later calls return the same outcome. On a run that already
  finished, it returns that run's own outcome unchanged. A `cancel/2` that
  times out returns `:timeout`; the cancellation continues.

  Besides the `Query.execute/3` error categories and `:cancelled`, a run can
  end with `:io` errors of its own: `{:run_start_failed, reason}` when the
  run process could not be started after preflight (a valid
  `:execution_observer` still receives one not-started record), and
  `{:run_down, reason}` when the execution process exited without reporting
  while the run was not being cancelled.

  ## Lifetime

  The run process monitors the process that called `start/3` (the owner).
  If the owner exits, the run is cancelled and the run process stops once
  the execution has ended. An exit signal sent to the run process (for
  example `Process.exit(run.pid, :shutdown)`) does the same, and the run
  process then stops with that reason; a `:normal` exit signal from another
  process is ignored, as it is for a process that does not trap exits. A
  `:kill` signal ends the run process at once, without cleanup or a terminal
  record.

  Until it stops, the run process keeps the outcome, so `snapshot/1`,
  `await/2` and `cancel/2` keep working after the run ends. `release/1`
  stops it once the run has ended, for owners that start many runs. Once the
  run process has stopped they return `{:error, %Error{kind: :not_found}}`.
  """

  use GenServer

  alias ClaudeWrapper.{
    Config,
    Error,
    ExecutionEvidence,
    Query,
    RateLimitObservation,
    Result,
    Runner,
    SessionObservation,
    StreamEvent
  }

  @enforce_keys [:pid, :ref]
  defstruct [:pid, :ref]

  @typedoc "A run handle. `:ref` tags the frames sent to `:events_to`."
  @type t :: %__MODULE__{pid: pid(), ref: reference()}

  @typedoc "The final outcome of a run."
  @type outcome ::
          {:ok, Result.t(), ExecutionEvidence.t()}
          | {:error, Error.t(), ExecutionEvidence.t()}

  @typedoc "Run status. The last three are final."
  @type status :: :running | :cancelling | :succeeded | :failed | :cancelled

  @typedoc """
  A point-in-time view of a run:

    * `:status` -- see `t:status/0`
    * `:session_id` -- the first nonblank native session ID seen, or `nil`
    * `:frames` -- frames received from the runner
    * `:frames_dropped` -- frames not delivered to `:events_to` under the
      mailbox policy
    * `:rate_limit` -- the last `%ClaudeWrapper.RateLimitObservation{}`, or
      `nil`
    * `:elapsed_ms` -- milliseconds since start, frozen when the run ends
  """
  @type snapshot :: %{
          status: status(),
          session_id: String.t() | nil,
          frames: non_neg_integer(),
          frames_dropped: non_neg_integer(),
          rate_limit: RateLimitObservation.t() | nil,
          elapsed_ms: non_neg_integer()
        }

  defguardp timeout_value?(timeout)
            when timeout == :infinity or (is_integer(timeout) and timeout >= 0)

  @run_keys [:events_to, :max_queued_frames, :cancel_grace_ms]
  @default_max_queued_frames 1_000
  @default_cancel_grace_ms 10_000

  # --- Public API ---

  @doc """
  Start an evidenced run of `query` and return its handle.

  See "Starting" in the module docs for options and preflight rejections.
  """
  @spec start(Query.t(), Config.t(), keyword()) :: {:ok, t()} | {:error, Error.t()}
  def start(%Query{} = query, %Config{} = config, opts \\ []) do
    {run_opts, query_opts, precheck} = split_opts(opts)

    with {:ok, prepared} <- Query.prepare_evidenced(query, config, query_opts, precheck) do
      ref = make_ref()

      args = %{
        prepared: prepared,
        owner: self(),
        ref: ref,
        events_to: Keyword.get(run_opts, :events_to, self()),
        max_queued: Keyword.get(run_opts, :max_queued_frames, @default_max_queued_frames),
        cancel_grace: Keyword.get(run_opts, :cancel_grace_ms, @default_cancel_grace_ms)
      }

      case GenServer.start(__MODULE__, args) do
        {:ok, pid} ->
          {:ok, %__MODULE__{pid: pid, ref: ref}}

        {:error, reason} ->
          prepared.cleanup.()
          reply = {:error, Error.io({:run_start_failed, reason})}
          send_not_started(prepared, reply)
          reply
      end
    end
  end

  @doc """
  Return the current `t:snapshot/0` of a run.

  Answered from the run process's own state; it never waits on the child or
  the runner.
  """
  @spec snapshot(t(), timeout()) :: snapshot() | :timeout | {:error, Error.t()}
  def snapshot(%__MODULE__{pid: pid}, timeout \\ 5_000) when timeout_value?(timeout),
    do: call(pid, :snapshot, timeout)

  @doc """
  Stop the run process once the run has ended, freeing its outcome.

  On a finished run the process stops now. On a run still in progress it
  stops right after the run ends, once pending `await/2` and `cancel/2`
  callers and `:events_to` have been sent the outcome. `release/1` does not
  cancel the run. Afterwards `snapshot/1`, `await/2` and `cancel/2` return
  `{:error, %Error{kind: :not_found}}`. Returns `:ok`, also when the run
  process is already gone.
  """
  @spec release(t()) :: :ok
  def release(%__MODULE__{pid: pid}) do
    case call(pid, :release, 5_000) do
      {:error, %Error{kind: :not_found}} -> :ok
      other -> other
    end
  end

  @doc """
  Wait up to `timeout` milliseconds for the run's outcome.

  Returns `t:outcome/0`, or `:timeout` without affecting the run.
  """
  @spec await(t(), timeout()) :: outcome() | :timeout | {:error, Error.t()}
  def await(%__MODULE__{pid: pid}, timeout \\ 5_000) when timeout_value?(timeout),
    do: wait(pid, :await, timeout)

  @doc """
  Cancel the run and wait up to `timeout` milliseconds for its outcome.

  See "Await and cancel" in the module docs.
  """
  @spec cancel(t(), timeout()) :: outcome() | :timeout | {:error, Error.t()}
  def cancel(%__MODULE__{pid: pid}, timeout \\ 5_000) when timeout_value?(timeout),
    do: wait(pid, :cancel, timeout)

  # The caller's own call timeout bounds the wait, including time queued in
  # the run process. On a timeout the caller tells the run process to drop
  # its waiter. The run process also drops it at the same absolute deadline
  # and when the caller exits, so no entry outlives its wait.
  defp wait(pid, request, :infinity), do: call(pid, {request, make_ref(), :infinity}, :infinity)

  defp wait(pid, request, timeout) do
    tag = make_ref()

    case call(pid, {request, tag, now() + timeout}, timeout) do
      :timeout ->
        GenServer.cast(pid, {:abandon, tag})
        :timeout

      reply ->
        reply
    end
  end

  defp call(pid, message, timeout) do
    GenServer.call(pid, message, timeout)
  catch
    :exit, {:timeout, _} -> :timeout
    :exit, {reason, _} when reason in [:noproc, :normal, :shutdown, :killed] -> not_found(pid)
    :exit, {{:shutdown, _}, _} -> not_found(pid)
  end

  defp send_not_started(%{observers: %{execution: {pid, reference}}} = prepared, reply) do
    evidence =
      ExecutionEvidence.from_native(Runner.not_started_evidence(),
        runner: prepared.runner,
        outcome: reply
      )

    send(pid, {reference, evidence})
  end

  defp send_not_started(_prepared, _reply), do: :ok

  defp not_found(pid), do: {:error, Error.new(:not_found, reason: {:run, pid})}

  # Run options are taken out before the rest goes to Query's preflight. A
  # list that is not a keyword list is passed through unchanged, so Query
  # rejects it exactly as execute/3 would.
  defp split_opts(opts) do
    if is_list(opts) and Keyword.keyword?(opts) do
      {run_opts, query_opts} = Keyword.split_with(opts, fn {key, _} -> key in @run_keys end)
      {run_opts, query_opts, validate_run_opts(run_opts)}
    else
      {[], opts, :ok}
    end
  end

  defp validate_run_opts(run_opts) do
    keys = Keyword.keys(run_opts)

    case keys -- Enum.uniq(keys) do
      [key | _] -> {:error, Error.new(:invalid_run_options, reason: {:duplicate, key})}
      [] -> Enum.find_value(run_opts, :ok, &invalid_run_opt/1)
    end
  end

  defp invalid_run_opt({:events_to, nil}), do: nil
  defp invalid_run_opt({:events_to, pid}) when is_pid(pid) and node(pid) == node(), do: nil
  defp invalid_run_opt({key, n}) when key != :events_to and is_integer(n) and n > 0, do: nil

  defp invalid_run_opt(pair),
    do: {:error, Error.new(:invalid_run_options, reason: pair)}

  # --- Run process ---

  @impl true
  def init(args) do
    Process.flag(:trap_exit, true)
    server = self()
    cancel = make_ref()
    prepared = args.prepared

    # The run process sends every observer message (session, rate limit and
    # the terminal record), so their order is that of one sender.
    worker_prepared = %{prepared | observers: %{session: nil, rate_limit: nil, execution: nil}}
    worker = spawn_link(fn -> work(server, worker_prepared, cancel) end)

    {:ok,
     %{
       ref: args.ref,
       owner_monitor: Process.monitor(args.owner),
       events_to: args.events_to,
       max_queued: args.max_queued,
       cancel_grace: args.cancel_grace,
       prepared: prepared,
       observers: prepared.observers,
       worker: worker,
       cancel: cancel,
       status: :running,
       started_at: now(),
       finished_at: nil,
       session_id: nil,
       frames: 0,
       frames_dropped: 0,
       rate_limit: nil,
       outcome: nil,
       waiters: %{},
       stop_when_done: false,
       stop_reason: :normal
     }}
  end

  # Runs in the execution process: Query's evidenced path, forwarding each
  # parsed stdout line to the run process in stream order.
  defp work(server, prepared, cancel) do
    frame = fn line ->
      case StreamEvent.parse(line) do
        {:ok, %StreamEvent{} = event} -> send(server, {:frame, event})
        _other -> :ok
      end
    end

    # Reported from inside the exec span, before its stop handlers run, so a
    # cancel grace kill during a slow handler cannot replace the outcome.
    report = fn {reply, evidence} -> send(server, {:finished, reply, evidence}) end
    Query.run_prepared(prepared, %{frame: frame, cancel: cancel, report: report})
  end

  @impl true
  def handle_call(:snapshot, _from, state), do: {:reply, snapshot_of(state), state}

  def handle_call(:release, _from, %{outcome: nil} = state),
    do: {:reply, :ok, %{state | stop_when_done: true}}

  def handle_call(:release, _from, state), do: {:stop, :normal, :ok, state}

  def handle_call({request, _tag, _deadline}, _from, %{outcome: outcome} = state)
      when request in [:await, :cancel] and outcome != nil,
      do: {:reply, outcome, state}

  def handle_call({:await, tag, deadline}, from, state),
    do: {:noreply, add_waiter(state, from, tag, deadline)}

  def handle_call({:cancel, tag, deadline}, from, state),
    do: {:noreply, state |> request_cancel() |> add_waiter(from, tag, deadline)}

  @impl true
  def handle_cast({:abandon, tag}, state), do: {:noreply, drop_waiter(state, tag)}

  @impl true
  def handle_info({:frame, event}, %{outcome: nil} = state) do
    state = %{state | frames: state.frames + 1} |> track(event) |> deliver(event)
    {:noreply, state}
  end

  def handle_info({:frame, _event}, state), do: {:noreply, state}

  def handle_info({:finished, reply, evidence}, %{outcome: nil} = state) do
    finish(state, reply, evidence)
  end

  def handle_info({:finished, _reply, _evidence}, state), do: {:noreply, state}

  # The execution process ended without reporting (killed after the cancel
  # grace, or crashed). The run process records the one evidence record.
  def handle_info({:EXIT, worker, reason}, %{worker: worker, outcome: nil} = state) do
    {reply, native_reason} =
      if state.status == :cancelling,
        do: {{:error, Error.new(:cancelled)}, :cancelled},
        else: {{:error, Error.io({:run_down, reason})}, nil}

    native = %{
      execution: if(state.frames > 0, do: :started, else: :unknown),
      reason: native_reason
    }

    evidence =
      ExecutionEvidence.from_native(native,
        runner: state.prepared.runner,
        session_id: state.session_id,
        outcome: reply
      )

    finish(state, reply, evidence)
  end

  def handle_info({:EXIT, worker, _reason}, %{worker: worker} = state), do: {:noreply, state}

  # An exit signal from any other process. Without trap_exit a :normal signal
  # would be ignored, so it is here too; any other reason cancels the run and
  # stops the run process with that reason once the run has ended.
  def handle_info({:EXIT, _pid, :normal}, state), do: {:noreply, state}

  def handle_info({:EXIT, _pid, reason}, %{outcome: nil} = state),
    do: {:noreply, %{request_cancel(state) | stop_when_done: true, stop_reason: reason}}

  def handle_info({:EXIT, _pid, reason}, state), do: {:stop, reason, state}

  def handle_info(:cancel_grace, %{outcome: nil, status: :cancelling} = state) do
    Process.exit(state.worker, :kill)
    {:noreply, state}
  end

  def handle_info(:cancel_grace, state), do: {:noreply, state}

  # Backstop for a caller whose abandon message has not arrived.
  def handle_info({:wait_timeout, tag}, state), do: {:noreply, drop_waiter(state, tag)}

  def handle_info({:DOWN, monitor, :process, _owner, _reason}, %{owner_monitor: monitor} = state) do
    if state.outcome == nil do
      {:noreply, %{request_cancel(state) | stop_when_done: true}}
    else
      {:stop, :normal, state}
    end
  end

  # A waiting caller exited.
  def handle_info({:DOWN, monitor, :process, _pid, _reason}, state) do
    waiters =
      state.waiters
      |> Enum.reject(fn {_tag, {_from, timer, waiter_monitor}} ->
        waiter_monitor == monitor and cancel_timer(timer)
      end)
      |> Map.new()

    {:noreply, %{state | waiters: waiters}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  defp add_waiter(state, {pid, _} = from, tag, deadline) do
    timer =
      if deadline != :infinity,
        do: Process.send_after(self(), {:wait_timeout, tag}, max(deadline - now(), 0))

    waiter = {from, timer, Process.monitor(pid)}
    %{state | waiters: Map.put(state.waiters, tag, waiter)}
  end

  defp drop_waiter(state, tag) do
    case Map.pop(state.waiters, tag) do
      {nil, _waiters} ->
        state

      {{_from, timer, monitor}, waiters} ->
        cancel_timer(timer)
        Process.demonitor(monitor, [:flush])
        %{state | waiters: waiters}
    end
  end

  defp cancel_timer(nil), do: true
  defp cancel_timer(timer), do: Process.cancel_timer(timer, async: false, info: false) || true

  defp request_cancel(%{status: :running} = state) do
    send(state.worker, {state.cancel, :cancel})
    Process.send_after(self(), :cancel_grace, state.cancel_grace)
    %{state | status: :cancelling}
  end

  defp request_cancel(state), do: state

  defp finish(state, reply, evidence) do
    state.prepared.cleanup.()

    outcome =
      case reply do
        {:ok, result} -> {:ok, result, evidence}
        {:error, error} -> {:error, error, evidence}
      end

    status =
      case reply do
        {:ok, _} -> :succeeded
        {:error, %Error{kind: :cancelled}} -> :cancelled
        {:error, _} -> :failed
      end

    observe(state.observers.execution, evidence)

    Enum.each(state.waiters, fn {_tag, {from, timer, monitor}} ->
      cancel_timer(timer)
      Process.demonitor(monitor, [:flush])
      GenServer.reply(from, outcome)
    end)

    if state.events_to, do: send(state.events_to, {state.ref, {:done, status}})

    state = %{state | outcome: outcome, status: status, finished_at: now(), waiters: %{}}

    if state.stop_when_done, do: {:stop, state.stop_reason, state}, else: {:noreply, state}
  end

  defp track(state, %StreamEvent{type: "system", data: %{"subtype" => "init"} = data}) do
    id = data["session_id"]

    if state.session_id == nil and is_binary(id) and String.trim(id) != "" do
      observe(state.observers.session, %SessionObservation{session_id: id})
      %{state | session_id: id}
    else
      state
    end
  end

  defp track(state, %StreamEvent{type: "rate_limit_event", data: data}) do
    case RateLimitObservation.from_event(data) do
      {:ok, observation} ->
        observe(state.observers.rate_limit, observation)
        %{state | rate_limit: observation}

      _invalid ->
        state
    end
  end

  defp track(state, _event), do: state

  defp observe(nil, _message), do: :ok
  defp observe({pid, reference}, message), do: send(pid, {reference, message})

  defp deliver(%{events_to: nil} = state, _event), do: state

  defp deliver(state, event) do
    case Process.info(state.events_to, :message_queue_len) do
      {:message_queue_len, n} when n < state.max_queued ->
        send(state.events_to, {state.ref, {:frame, event}})
        state

      _full_or_dead ->
        %{state | frames_dropped: state.frames_dropped + 1}
    end
  end

  defp snapshot_of(state) do
    %{
      status: state.status,
      session_id: state.session_id,
      frames: state.frames,
      frames_dropped: state.frames_dropped,
      rate_limit: state.rate_limit,
      elapsed_ms: (state.finished_at || now()) - state.started_at
    }
  end

  defp now, do: System.monotonic_time(:millisecond)
end
