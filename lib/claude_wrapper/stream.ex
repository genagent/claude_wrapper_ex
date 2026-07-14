defmodule ClaudeWrapper.Stream do
  @moduledoc """
  Lazy `Stream` combinators over a `ClaudeWrapper.DuplexSession` turn.

  `DuplexSession` broadcasts a turn's progress to subscribers as
  `{:claude, event}` messages (see its module doc for the vocabulary).
  This module wraps one turn as an Elixir `t:Enumerable.t/0` so the
  events compose with the standard `Stream`/`Enum` toolkit, and adds a
  few decode-and-project combinators on top. It is a pure ergonomic
  layer: no new runtime dependencies, no new transport.

  ## One turn per enumeration

  `stream/3` returns a *lazy* stream. Like any `Stream`, it is a recipe:
  **each time it is enumerated it triggers a fresh turn.** Pick one
  transform or terminal per turn. If you need both the text and the
  `t:ClaudeWrapper.Result.t/0`, use `collect/1` (it returns both) rather
  than enumerating twice.

      session
      |> ClaudeWrapper.Stream.stream("Write a haiku about Elixir.")
      |> ClaudeWrapper.Stream.text_deltas()
      |> Enum.each(&IO.write/1)

      %{text: text, result: %ClaudeWrapper.Result{}} =
        session
        |> ClaudeWrapper.Stream.stream("Summarize this file.")
        |> ClaudeWrapper.Stream.collect()

  ## Elements

  The foundational `stream/3` yields the same `event` payloads a
  subscriber receives (the second element of `{:claude, event}`):
  `{:system_init, session_id}`, `{:assistant, msg}`, `{:stream_event,
  raw}`, `{:user, msg}`, and the terminal `{:result, %Result{}}`. A
  failed turn (including `:turn_in_flight`) yields a terminal
  `{:error, %ClaudeWrapper.Error{}}` instead of `{:result, _}`.

  ## Early halt

  Halting early (e.g. `Stream.take/2`) stops consumption and unsubscribes,
  but does **not** cancel the turn server-side -- the `claude` subprocess
  runs the turn to completion. Use `ClaudeWrapper.DuplexSession.interrupt/1`
  for a real mid-turn cancel.
  """

  alias ClaudeWrapper.{DuplexSession, Error, Result, StreamEvent}

  @default_timeout 120_000

  @typedoc "A decoded turn event, as yielded by `stream/3`."
  @type event ::
          {:system_init, String.t()}
          | {:assistant, map()}
          | {:stream_event, map()}
          | {:user, map()}
          | {:result, Result.t()}
          | {:error, ClaudeWrapper.Error.t()}

  @typedoc "Options for `stream/3`."
  @type option :: {:timeout, timeout()}

  @doc """
  Wrap one `DuplexSession` turn as a lazy stream of `t:event/0` values.

  Enumerating subscribes the calling process, sends `prompt`, and yields
  each broadcast event in arrival order, ending with the terminal
  `{:result, %Result{}}` (or `{:error, %Error{}}`).

  Options:

    * `:timeout` -- per-turn timeout forwarded to
      `ClaudeWrapper.DuplexSession.send/3` (default `120_000`).
  """
  @spec stream(GenServer.server(), String.t(), [option()]) :: Enumerable.t()
  def stream(session, prompt, opts \\ []) when is_binary(prompt) do
    timeout = Keyword.get(opts, :timeout, @default_timeout)

    Stream.resource(
      fn -> start_turn(session, prompt, timeout) end,
      &next_event/1,
      &cleanup/1
    )
  end

  @doc """
  Project a turn stream to its text deltas (the streamed answer tokens).

      session
      |> ClaudeWrapper.Stream.stream("Say hi.")
      |> ClaudeWrapper.Stream.text_deltas()
      |> Enum.join()
  """
  @spec text_deltas(Enumerable.t()) :: Enumerable.t()
  def text_deltas(events), do: delta_stream(events, :text)

  @doc "Project a turn stream to its extended-thinking deltas."
  @spec thinking_deltas(Enumerable.t()) :: Enumerable.t()
  def thinking_deltas(events), do: delta_stream(events, :thinking)

  @doc """
  Project a turn stream to its tool-use starts, as `%{id, name}` maps.

  Emits one element per tool-use content block the assistant opens. The
  tool input arrives as later `input_json` deltas; this surfaces the
  identity of each tool call.
  """
  @spec tool_uses(Enumerable.t()) :: Enumerable.t()
  def tool_uses(events) do
    events
    |> partial_messages()
    |> Stream.flat_map(fn
      {:block_start, _index, {:tool_use, id, name}} -> [%{id: id, name: name}]
      _ -> []
    end)
  end

  @doc """
  Keep only the events for which `fun` returns truthy.

  A thin pass-through to `Stream.filter/2`, here for discoverability
  alongside the projections.
  """
  @spec filter(Enumerable.t(), (event() -> as_boolean(term()))) :: Enumerable.t()
  def filter(events, fun), do: Stream.filter(events, fun)

  @doc """
  Run `fun` on each event for its side effect, passing the event through.

  A thin pass-through to `Stream.each/2`.
  """
  @spec tap(Enumerable.t(), (event() -> term())) :: Enumerable.t()
  def tap(events, fun), do: Stream.each(events, fun)

  @doc """
  Run the turn to completion and return the accumulated answer text.

  Concatenates every text delta. Terminal: enumerates the whole turn.
  """
  @spec final_text(Enumerable.t()) :: String.t()
  def final_text(events) do
    events
    |> text_deltas()
    |> Enum.join()
  end

  @doc """
  Run the turn to completion and return its `t:ClaudeWrapper.Result.t/0`.

  Returns `nil` if the turn yielded no result event (e.g. it ended in an
  `{:error, _}`). Terminal: enumerates the whole turn.
  """
  @spec final_result(Enumerable.t()) :: Result.t() | nil
  def final_result(events) do
    Enum.reduce(events, nil, fn
      {:result, result}, _acc -> result
      _other, acc -> acc
    end)
  end

  @doc """
  Run the turn to completion, returning both the text and the result.

      %{text: text, result: %ClaudeWrapper.Result{}} =
        ClaudeWrapper.Stream.collect(stream)

  `result` is `nil` if the turn ended without a result event. Terminal:
  enumerates the whole turn once (the right call when you need both the
  text and the result from a single turn).
  """
  @spec collect(Enumerable.t()) :: %{text: String.t(), result: Result.t() | nil}
  def collect(events) do
    {chunks, result} =
      Enum.reduce(events, {[], nil}, fn event, {chunks, result} ->
        case event do
          {:result, r} -> {chunks, r}
          {:stream_event, _} = ev -> {prepend_text(ev, chunks), result}
          _other -> {chunks, result}
        end
      end)

    %{text: chunks |> Enum.reverse() |> IO.iodata_to_binary(), result: result}
  end

  # -- internals -----------------------------------------------------

  defp start_turn(session, prompt, timeout) do
    :ok = DuplexSession.subscribe(session)
    parent = self()

    # spawn_monitor, not Task.async: a Task links to the consumer, so a
    # send/3 exit (e.g. a dead session) would crash the stream consumer.
    # Monitor-only lets us surface that as a terminal {:error, _} instead.
    {pid, ref} =
      spawn_monitor(fn ->
        Process.send(
          parent,
          {:__turn_outcome__, DuplexSession.send(session, prompt, timeout)},
          []
        )
      end)

    %{session: session, pid: pid, ref: ref, done: false}
  end

  defp next_event(%{done: true} = acc), do: {:halt, acc}

  defp next_event(%{ref: ref} = acc) do
    receive do
      {:claude, {:result, _result} = event} ->
        {[event], %{acc | done: true}}

      {:claude, event} ->
        {[event], acc}

      # The send process finished. A successful turn already broadcast
      # {:result, _} (we halt on that, above); reaching the outcome
      # without one means the send returned an error -- surface it as a
      # terminal {:error, _} so the consumer never blocks forever.
      {:__turn_outcome__, {:error, error}} ->
        {[{:error, error}], %{acc | done: true}}

      {:__turn_outcome__, {:ok, _result}} ->
        next_event(acc)

      {:DOWN, ^ref, :process, _pid, :normal} ->
        next_event(acc)

      {:DOWN, ^ref, :process, _pid, reason} ->
        {[{:error, Error.new(:duplex_closed, reason: reason)}], %{acc | done: true}}
    end
  end

  defp cleanup(%{session: session, pid: pid, ref: ref}) do
    # The session may already be dead (an abnormal close is exactly the case the
    # :duplex_closed terminal covers); swallow the exit so the Stream.resource
    # after-callback still completes cleanly instead of crashing the consumer.
    try do
      DuplexSession.unsubscribe(session)
    catch
      :exit, _ -> :ok
    end

    Process.demonitor(ref, [:flush])
    if Process.alive?(pid), do: Process.exit(pid, :kill)
    :ok
  end

  # Decode the {:stream_event, raw} elements into typed partial messages,
  # dropping every other event kind.
  defp partial_messages(events) do
    events
    |> Stream.flat_map(fn
      {:stream_event, raw} ->
        case StreamEvent.partial_message(%StreamEvent{type: "stream_event", data: raw}) do
          nil -> []
          partial -> [partial]
        end

      _other ->
        []
    end)
  end

  defp delta_stream(events, kind) do
    events
    |> partial_messages()
    |> Stream.flat_map(fn
      {:block_delta, _index, {^kind, text}} -> [text]
      _ -> []
    end)
  end

  defp prepend_text({:stream_event, raw}, chunks) do
    case StreamEvent.partial_message(%StreamEvent{type: "stream_event", data: raw}) do
      {:block_delta, _index, {:text, text}} -> [text | chunks]
      _ -> chunks
    end
  end
end
