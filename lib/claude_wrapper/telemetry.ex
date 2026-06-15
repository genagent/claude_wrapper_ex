defmodule ClaudeWrapper.Telemetry do
  @moduledoc """
  `:telemetry` events emitted by ClaudeWrapper.

  Wraps the core exec paths with `:telemetry.span/3` so downstream
  applications can subscribe once via `:telemetry.attach_many/4` and
  observe query, stream, and session-turn lifecycle.

  ## Events

    * `[:claude_wrapper, :exec, :start | :stop | :exception]` --
      emitted around `ClaudeWrapper.Query.execute/2` (one-shot,
      synchronous query).

    * `[:claude_wrapper, :stream, :start | :stop | :exception]` --
      emitted around `ClaudeWrapper.Query.stream/2`. The `:stop`
      event fires when the returned stream is fully consumed or
      closed; `:start` fires when the stream is first reduced.

    * `[:claude_wrapper, :session, :turn, :start | :stop | :exception]` --
      emitted around `ClaudeWrapper.Session.send/3` (a single turn
      of a multi-turn session).

  ## Measurements

  Automatically populated by `:telemetry.span/3`:

    * `:start` -- `%{monotonic_time: integer(), system_time: integer()}`
    * `:stop` -- `%{monotonic_time: integer(), duration: integer()}`
    * `:exception` -- `%{monotonic_time: integer(), duration: integer()}`

  ## Metadata

  Every event carries at least:

    * `:command` -- atom identifying the call site, e.g. `:query`
      (one-shot execute), `:stream`, or `:session_turn`.
    * `:session_id` -- present when known (a resumed session, or the
      `session_id` returned by the CLI in the result).
    * `:model` -- from `ClaudeWrapper.Query.model/2` or session
      `query_opts`.
    * `:resume?` -- boolean, whether this invocation threads a
      previously established `session_id`.

  `:stop` events additionally include:

    * `:cost_usd` -- parsed from the final NDJSON result, when
      available.
    * `:exit_code` -- `0` on success, non-zero when the CLI exited
      with an error that still produced output, `nil` for other
      errors.

  `:exception` events follow the standard `:telemetry.span/3` shape
  and add `:kind`, `:reason`, and `:stacktrace`.

  ## Example

      :telemetry.attach_many(
        "my-handler",
        [
          [:claude_wrapper, :exec, :stop],
          [:claude_wrapper, :stream, :stop],
          [:claude_wrapper, :session, :turn, :stop]
        ],
        fn event, measurements, metadata, _config ->
          Logger.info(fn ->
            "\#{inspect(event)} duration=\#{measurements.duration} cost=\#{inspect(metadata.cost_usd)}"
          end)
        end,
        nil
      )
  """

  alias ClaudeWrapper.{Error, Query, Result, StreamEvent}

  @type metadata :: %{optional(atom()) => term()}

  @doc """
  Wrap a one-shot query execution in a `[:claude_wrapper, :exec, _]` span.

  `fun` must return `{:ok, %Result{}} | {:error, term()}`. Stop
  metadata is derived from the return value.
  """
  @spec span_exec(Query.t(), (-> {:ok, Result.t()} | {:error, term()})) ::
          {:ok, Result.t()} | {:error, term()}
  def span_exec(%Query{} = query, fun) when is_function(fun, 0) do
    start_metadata = exec_start_metadata(query)

    :telemetry.span([:claude_wrapper, :exec], start_metadata, fn ->
      result = fun.()
      stop_metadata = Map.merge(start_metadata, exec_stop_metadata(result))
      {result, stop_metadata}
    end)
  end

  @doc """
  Wrap a streaming query in a `[:claude_wrapper, :stream, _]` span.

  `stream_fun` must return an `Enumerable.t()` of `%StreamEvent{}`.
  The span's `:start` fires on first reduce, `:stop` fires when the
  consumer halts or the producer is exhausted. `:stop` metadata
  captures `cost_usd` / `session_id` from the terminal `result`
  stream event, when observed.
  """
  @spec span_stream(Query.t(), (-> Enumerable.t())) :: Enumerable.t()
  def span_stream(%Query{} = query, stream_fun) when is_function(stream_fun, 0) do
    start_metadata = stream_start_metadata(query)

    Stream.resource(
      fn -> stream_start(start_metadata, stream_fun) end,
      &stream_next/1,
      &stream_stop/1
    )
  end

  @doc """
  Wrap a session turn in a `[:claude_wrapper, :session, :turn, _]` span.

  `fun` must return `{:ok, updated_session, %Result{}} | {:error, term()}`.
  """
  @spec span_session_turn(
          map(),
          Query.t(),
          (-> {:ok, map(), Result.t()} | {:error, term()})
        ) ::
          {:ok, map(), Result.t()} | {:error, term()}
  def span_session_turn(session, %Query{} = query, fun) when is_function(fun, 0) do
    start_metadata = session_turn_start_metadata(session, query)

    :telemetry.span([:claude_wrapper, :session, :turn], start_metadata, fn ->
      result = fun.()
      stop_metadata = Map.merge(start_metadata, session_turn_stop_metadata(result))
      {result, stop_metadata}
    end)
  end

  # --- Metadata builders ---

  defp exec_start_metadata(%Query{} = query) do
    %{
      command: :query,
      session_id: query.session_id || query.resume,
      model: query.model,
      resume?: resume?(query)
    }
  end

  defp stream_start_metadata(%Query{} = query) do
    %{
      command: :stream,
      session_id: query.session_id || query.resume,
      model: query.model,
      resume?: resume?(query)
    }
  end

  defp session_turn_start_metadata(session, %Query{} = query) do
    session_id = Map.get(session, :session_id)

    %{
      command: :session_turn,
      session_id: session_id || query.session_id || query.resume,
      model: query.model,
      resume?: is_binary(session_id)
    }
  end

  defp exec_stop_metadata({:ok, %Result{} = result}) do
    %{
      cost_usd: result.cost_usd,
      exit_code: 0,
      session_id: result.session_id
    }
  end

  defp exec_stop_metadata({:error, %Error{exit_code: code}}) do
    %{cost_usd: nil, exit_code: code}
  end

  defp exec_stop_metadata({:error, _reason}) do
    %{cost_usd: nil, exit_code: nil}
  end

  defp session_turn_stop_metadata({:ok, _session, %Result{} = result}) do
    %{
      cost_usd: result.cost_usd,
      exit_code: 0,
      session_id: result.session_id
    }
  end

  defp session_turn_stop_metadata({:error, %Error{exit_code: code}}) do
    %{cost_usd: nil, exit_code: code}
  end

  defp session_turn_stop_metadata({:error, _reason}) do
    %{cost_usd: nil, exit_code: nil}
  end

  defp resume?(%Query{resume: resume, continue_session: continue, session_id: sid}) do
    is_binary(resume) or continue or is_binary(sid)
  end

  # --- Stream lifecycle ---

  # `Stream.resource/3` doesn't give us the producer as an
  # `Enumerable.t()` directly -- we capture the underlying stream's
  # continuation inside the accumulator so we can step through it.
  defp stream_start(start_metadata, stream_fun) do
    monotonic = System.monotonic_time()
    system = System.system_time()

    :telemetry.execute(
      [:claude_wrapper, :stream, :start],
      %{monotonic_time: monotonic, system_time: system},
      start_metadata
    )

    enum = stream_fun.()
    reducer = &Enumerable.reduce(enum, &1, fn elem, acc -> {:suspend, [elem | acc]} end)

    %{
      metadata: start_metadata,
      monotonic: monotonic,
      cont: reducer.({:cont, []})
    }
  end

  defp stream_next(%{cont: cont, metadata: metadata} = state) do
    case cont do
      {:suspended, [elem | _], continuation} ->
        updated_metadata = observe_stream_event(metadata, elem)

        {[elem], %{state | metadata: updated_metadata, cont: continuation.({:cont, []})}}

      {:done, _} ->
        {:halt, %{state | cont: :done}}

      {:halted, _} ->
        {:halt, %{state | cont: :done}}

      :done ->
        {:halt, state}
    end
  catch
    kind, reason ->
      stacktrace = __STACKTRACE__
      emit_exception(metadata, state.monotonic, kind, reason, stacktrace)
      :erlang.raise(kind, reason, stacktrace)
  end

  defp stream_stop(%{cont: cont, metadata: metadata, monotonic: monotonic}) do
    # If the consumer halted early, we must halt the suspended
    # producer so its cleanup (closing the Port) runs.
    _ =
      case cont do
        {:suspended, _elems, continuation} ->
          try do
            continuation.({:halt, []})
          catch
            _, _ -> :ok
          end

        _ ->
          :ok
      end

    duration = System.monotonic_time() - monotonic

    stop_metadata =
      metadata
      |> Map.put_new(:cost_usd, nil)
      |> Map.put_new(:exit_code, 0)

    :telemetry.execute(
      [:claude_wrapper, :stream, :stop],
      %{monotonic_time: System.monotonic_time(), duration: duration},
      stop_metadata
    )
  end

  defp emit_exception(metadata, monotonic, kind, reason, stacktrace) do
    duration = System.monotonic_time() - monotonic

    exception_metadata =
      metadata
      |> Map.put(:kind, kind)
      |> Map.put(:reason, reason)
      |> Map.put(:stacktrace, stacktrace)

    :telemetry.execute(
      [:claude_wrapper, :stream, :exception],
      %{monotonic_time: System.monotonic_time(), duration: duration},
      exception_metadata
    )
  end

  # Inspect stream events to capture session_id / cost_usd from the
  # terminal `result` event, so :stop metadata can carry them.
  defp observe_stream_event(metadata, %StreamEvent{type: "result", data: data})
       when is_map(data) do
    metadata
    |> maybe_put(:cost_usd, data["total_cost_usd"] || data["cost_usd"])
    |> maybe_put(:session_id, data["session_id"])
  end

  defp observe_stream_event(metadata, _event), do: metadata

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, value), do: Map.put(map, key, value)
end
