defmodule ClaudeWrapper.Runner.Collector do
  @moduledoc false
  # Owned, bounded bridge between a blocking one-shot native run and a
  # trusted stdout line observer.
  #
  # The native run executes in a helper process (it owns the native port and
  # is the only process that talks to the native supervisor). Output frames
  # arrive in the execution caller as `{ref, {:stdout | :stderr, bytes}}`
  # messages from that helper, followed by exactly one `{ref, :done, outcome}`.
  # The caller frames stdout into lines and invokes the observer itself, so
  # the observer always runs in the execution caller. Stderr is never
  # observed.
  #
  # Bounds: the native layer bounds frame size and the recipient queue (for
  # Forcola, 8 KiB credit windows and observer-overflow cancellation); this
  # module bounds the partial line it buffers to `:max_line_bytes`. A longer
  # line is withheld from the observer and counted in `lines_dropped`.
  # Received stdout/stderr are also retained up to the combined
  # `:max_output_bytes` bound for helper-failure evidence (default 1 MiB;
  # the Forcola runner supplies its native output bound).
  #
  # Lifetime: the caller monitors the helper. A watcher linked to the helper
  # monitors the caller, so caller death ends the helper (closing its port,
  # which the native supervisor treats as owner death) without the caller
  # being linked to the helper. Helper death is reported as
  # `{:helper_down, reason, stats}`. No process here signals or kills the
  # native child; cleanup stays with the native supervisor.
  #
  # After either outcome every message tagged with the private reference is
  # flushed, so none linger in the caller's mailbox.

  @default_max_line_bytes 1_048_576

  @type observer ::
          (String.t() -> :continue | :observed | {:continue, observer()}) | nil

  @type stats :: %{
          lines_dropped: non_neg_integer(),
          stdout: binary(),
          stderr: binary(),
          output_truncated: true | :unknown,
          observer_error: {atom(), term()} | nil
        }

  @doc false
  @spec default_max_line_bytes() :: pos_integer()
  def default_max_line_bytes, do: @default_max_line_bytes

  @doc false
  @spec run(({pid(), reference()} -> term()), observer(), keyword()) ::
          {:done, term(), stats()} | {:helper_down, term(), stats()}
  def run(fun, observer, opts \\ []) when is_function(fun, 1) do
    caller = self()
    ref = make_ref()
    {helper, monitor} = spawn_monitor(fn -> helper(caller, ref, fun) end)

    state = %{
      ref: ref,
      helper: helper,
      monitor: monitor,
      observer: observer,
      observer_error: nil,
      stdout: [],
      stderr: [],
      retained: 0,
      output_max: Keyword.get(opts, :max_output_bytes, @default_max_line_bytes),
      truncated: false,
      max: Keyword.get(opts, :max_line_bytes, @default_max_line_bytes),
      buffer: [],
      size: 0,
      skipping: false,
      dropped: 0
    }

    outcome = collect(state)
    flush(ref)
    outcome
  end

  defp helper(caller, ref, fun) do
    helper = self()
    watcher = spawn_link(fn -> watch(caller, helper) end)

    try do
      outcome = fun.({caller, ref})
      send(caller, {ref, :done, outcome})
    after
      Process.unlink(watcher)
      Process.exit(watcher, :kill)
    end
  end

  # Linked to the helper so helper death also retires the watcher. Caller
  # death sends an abnormal exit to the helper (closing its native port)
  # and lets the watcher return normally.
  defp watch(caller, helper) do
    monitor = Process.monitor(caller)

    receive do
      {:DOWN, ^monitor, :process, ^caller, _reason} ->
        Process.exit(helper, {:caller_down, helper})
    end
  end

  defp collect(%{ref: ref, monitor: monitor, helper: helper} = state) do
    receive do
      {^ref, {:stdout, bytes}} when is_binary(bytes) ->
        state |> retain(:stdout, bytes) |> frame(bytes) |> collect()

      {^ref, {:stderr, bytes}} when is_binary(bytes) ->
        state |> retain(:stderr, bytes) |> collect()

      {^ref, :done, outcome} ->
        Process.demonitor(monitor, [:flush])
        state = finish_tail(state)
        {:done, outcome, stats(state)}

      {:DOWN, ^monitor, :process, ^helper, reason} ->
        {:helper_down, reason, stats(state)}
    end
  end

  defp frame(state, bytes) do
    case :binary.split(bytes, "\n") do
      [rest] -> append(state, rest)
      [line, rest] -> state |> append(line) |> emit() |> frame(rest)
    end
  end

  defp append(%{skipping: true} = state, _segment), do: state
  defp append(state, ""), do: state

  defp append(state, segment) do
    size = state.size + byte_size(segment)

    if size > state.max do
      %{state | buffer: [], size: 0, skipping: true}
    else
      %{state | buffer: [state.buffer, segment], size: size}
    end
  end

  defp emit(%{skipping: true} = state) do
    %{state | skipping: false, dropped: state.dropped + 1}
  end

  defp emit(state) do
    line = IO.iodata_to_binary(state.buffer)
    state = %{state | buffer: [], size: 0}
    observe(state, line)
  end

  # A final unterminated line is still a line (for example a trailing result
  # without a newline).
  defp finish_tail(%{skipping: true} = state), do: emit(state)
  defp finish_tail(%{size: 0} = state), do: state
  defp finish_tail(state), do: emit(state)

  defp observe(%{observer: nil} = state, _line), do: state

  # Keep draining the owned native run after a trusted observer fails, so its
  # terminal report and cleanup handshake are not lost or fabricated.
  defp observe(state, line) do
    observer =
      case state.observer.(line) do
        :observed -> nil
        :continue -> state.observer
        {:continue, next_observer} when is_function(next_observer, 1) -> next_observer
      end

    %{state | observer: observer}
  catch
    kind, reason -> %{state | observer: nil, observer_error: {kind, reason}}
  end

  defp retain(state, stream, bytes) do
    size = min(byte_size(bytes), state.output_max - state.retained)
    kept = :binary.copy(binary_part(bytes, 0, size))
    chunks = if size > 0, do: [kept | Map.fetch!(state, stream)], else: Map.fetch!(state, stream)

    state
    |> Map.put(stream, chunks)
    |> Map.put(:retained, state.retained + size)
    |> Map.put(:truncated, state.truncated or size < byte_size(bytes))
  end

  defp stats(state) do
    %{
      lines_dropped: state.dropped,
      stdout: state.stdout |> Enum.reverse() |> IO.iodata_to_binary(),
      stderr: state.stderr |> Enum.reverse() |> IO.iodata_to_binary(),
      output_truncated: if(state.truncated, do: true, else: :unknown),
      observer_error: state.observer_error
    }
  end

  defp flush(ref) do
    receive do
      {^ref, _message} -> flush(ref)
      {^ref, _tag, _message} -> flush(ref)
    after
      0 -> :ok
    end
  end
end
