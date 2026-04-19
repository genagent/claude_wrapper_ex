defmodule ClaudeWrapper.TelemetryTest do
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Query, Result, StreamEvent, Telemetry}

  @doc false
  def forward_event(event, measurements, metadata, test_pid) do
    send(test_pid, {:telemetry, event, measurements, metadata})
  end

  setup context do
    test_pid = self()
    handler_id = "claude-wrapper-telemetry-test-#{inspect(context.test)}"

    events = [
      [:claude_wrapper, :exec, :start],
      [:claude_wrapper, :exec, :stop],
      [:claude_wrapper, :exec, :exception],
      [:claude_wrapper, :stream, :start],
      [:claude_wrapper, :stream, :stop],
      [:claude_wrapper, :stream, :exception],
      [:claude_wrapper, :session, :turn, :start],
      [:claude_wrapper, :session, :turn, :stop],
      [:claude_wrapper, :session, :turn, :exception]
    ]

    :telemetry.attach_many(
      handler_id,
      events,
      &__MODULE__.forward_event/4,
      test_pid
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    :ok
  end

  describe "span_exec/2" do
    test "emits :start and :stop with expected metadata on success" do
      query = Query.new("hi") |> Query.model("sonnet")
      result = %Result{result: "hello", session_id: "sess-1", cost_usd: 0.42}

      assert {:ok, ^result} = Telemetry.span_exec(query, fn -> {:ok, result} end)

      assert_receive {:telemetry, [:claude_wrapper, :exec, :start], start_meas, start_meta}
      assert is_integer(start_meas.monotonic_time)
      assert is_integer(start_meas.system_time)
      assert start_meta.command == :query
      assert start_meta.model == "sonnet"
      assert start_meta.resume? == false
      assert start_meta.session_id == nil

      assert_receive {:telemetry, [:claude_wrapper, :exec, :stop], stop_meas, stop_meta}
      assert is_integer(stop_meas.duration)
      assert stop_meas.duration >= 0
      assert stop_meta.command == :query
      assert stop_meta.cost_usd == 0.42
      assert stop_meta.exit_code == 0
      assert stop_meta.session_id == "sess-1"
      assert stop_meta.model == "sonnet"
    end

    test "sets resume? when query resumes a session" do
      query = Query.new("hi") |> Query.resume("sess-prev")

      Telemetry.span_exec(query, fn -> {:ok, %Result{}} end)

      assert_receive {:telemetry, [:claude_wrapper, :exec, :start], _, start_meta}
      assert start_meta.resume? == true
      assert start_meta.session_id == "sess-prev"
    end

    test "stop metadata on {:error, {:exit, code, stdout}} carries exit_code" do
      query = Query.new("hi")

      assert {:error, {:exit, 2, "boom"}} =
               Telemetry.span_exec(query, fn -> {:error, {:exit, 2, "boom"}} end)

      assert_receive {:telemetry, [:claude_wrapper, :exec, :stop], _, meta}
      assert meta.exit_code == 2
      assert meta.cost_usd == nil
    end

    test "emits :exception when function raises" do
      query = Query.new("hi")

      assert_raise RuntimeError, "nope", fn ->
        Telemetry.span_exec(query, fn -> raise "nope" end)
      end

      assert_receive {:telemetry, [:claude_wrapper, :exec, :exception], meas, meta}
      assert is_integer(meas.duration)
      assert meta.kind == :error
      assert %RuntimeError{message: "nope"} = meta.reason
      assert is_list(meta.stacktrace)
    end
  end

  describe "span_session_turn/3" do
    test "emits start/stop with resume? true when session has established session_id" do
      query = Query.new("follow-up")
      session = %{session_id: "sess-abc"}
      result = %Result{result: "ack", session_id: "sess-abc", cost_usd: 0.05}

      assert {:ok, _session, ^result} =
               Telemetry.span_session_turn(session, query, fn ->
                 {:ok, session, result}
               end)

      assert_receive {:telemetry, [:claude_wrapper, :session, :turn, :start], _, start_meta}
      assert start_meta.command == :session_turn
      assert start_meta.session_id == "sess-abc"
      assert start_meta.resume? == true

      assert_receive {:telemetry, [:claude_wrapper, :session, :turn, :stop], _, stop_meta}
      assert stop_meta.cost_usd == 0.05
      assert stop_meta.exit_code == 0
      assert stop_meta.session_id == "sess-abc"
    end

    test "first turn has resume? false when session has no established id" do
      query = Query.new("first")
      session = %{session_id: nil}

      Telemetry.span_session_turn(session, query, fn ->
        {:ok, session, %Result{}}
      end)

      assert_receive {:telemetry, [:claude_wrapper, :session, :turn, :start], _, meta}
      assert meta.resume? == false
    end

    test "error tuple sets exit_code" do
      query = Query.new("x")
      session = %{session_id: nil}

      assert {:error, {:exit, 1, "stderr"}} =
               Telemetry.span_session_turn(session, query, fn ->
                 {:error, {:exit, 1, "stderr"}}
               end)

      assert_receive {:telemetry, [:claude_wrapper, :session, :turn, :stop], _, meta}
      assert meta.exit_code == 1
      assert meta.cost_usd == nil
    end
  end

  describe "span_stream/2" do
    test "emits :start on first consume and :stop on full consume" do
      query = Query.new("stream") |> Query.model("opus")

      events = [
        %StreamEvent{type: "system", data: %{"type" => "system"}},
        %StreamEvent{
          type: "result",
          data: %{
            "type" => "result",
            "total_cost_usd" => 0.11,
            "session_id" => "sess-stream"
          }
        }
      ]

      stream = Telemetry.span_stream(query, fn -> events end)
      assert Enum.to_list(stream) == events

      assert_receive {:telemetry, [:claude_wrapper, :stream, :start], _, start_meta}
      assert start_meta.command == :stream
      assert start_meta.model == "opus"

      assert_receive {:telemetry, [:claude_wrapper, :stream, :stop], meas, stop_meta}
      assert is_integer(meas.duration)
      assert stop_meta.cost_usd == 0.11
      assert stop_meta.session_id == "sess-stream"
      assert stop_meta.exit_code == 0
    end

    test "emits :stop on early halt (take/1)" do
      query = Query.new("stream")

      events = [
        %StreamEvent{type: "system", data: %{}},
        %StreamEvent{type: "assistant", data: %{}},
        %StreamEvent{type: "result", data: %{"total_cost_usd" => 0.5}}
      ]

      stream = Telemetry.span_stream(query, fn -> events end)
      assert [%StreamEvent{type: "system"}] = Enum.take(stream, 1)

      assert_receive {:telemetry, [:claude_wrapper, :stream, :start], _, _}
      assert_receive {:telemetry, [:claude_wrapper, :stream, :stop], _, stop_meta}
      # Stopped before seeing the result event; cost_usd stays nil.
      assert stop_meta.cost_usd == nil
    end

    test "emits :exception when producer raises" do
      query = Query.new("stream")

      bad_stream =
        Stream.map([1, 2, 3], fn
          1 -> %StreamEvent{type: "system", data: %{}}
          _ -> raise "boom"
        end)

      stream = Telemetry.span_stream(query, fn -> bad_stream end)

      assert_raise RuntimeError, "boom", fn -> Enum.to_list(stream) end

      assert_receive {:telemetry, [:claude_wrapper, :stream, :exception], _, meta}
      assert meta.kind == :error
      assert %RuntimeError{message: "boom"} = meta.reason
    end
  end
end
