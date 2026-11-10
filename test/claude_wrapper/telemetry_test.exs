defmodule ClaudeWrapper.TelemetryTest do
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{
    Config,
    DuplexSession,
    Query,
    RateLimitObservation,
    Result,
    Runner,
    StreamEvent,
    Telemetry
  }

  alias ClaudeWrapper.Test, as: CWTest

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
      [:claude_wrapper, :session, :turn, :exception],
      [:claude_wrapper, :duplex, :session, :start],
      [:claude_wrapper, :duplex, :session, :stop],
      [:claude_wrapper, :duplex, :turn, :start],
      [:claude_wrapper, :duplex, :turn, :stop],
      [:claude_wrapper, :duplex, :turn, :exception],
      [:claude_wrapper, :duplex, :permission, :request],
      [:claude_wrapper, :duplex, :permission, :decision],
      [:claude_wrapper, :duplex, :interrupt, :start],
      [:claude_wrapper, :duplex, :interrupt, :stop],
      [:claude_wrapper, :rate_limit]
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

    test "stop metadata on a :command_failed error carries exit_code" do
      query = Query.new("hi")
      error = ClaudeWrapper.Error.command_failed(2, "boom")

      assert {:error, ^error} = Telemetry.span_exec(query, fn -> {:error, error} end)

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
      assert stop_meta.turn_cost_usd == nil
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
      error = ClaudeWrapper.Error.command_failed(1, "stderr")

      assert {:error, ^error} =
               Telemetry.span_session_turn(session, query, fn ->
                 {:error, error}
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

    test "delivers a streamed event without reading ahead and cleans up on halt" do
      parent = self()
      event = %StreamEvent{type: "assistant", data: %{}}

      producer =
        Stream.resource(
          fn -> 0 end,
          fn
            0 ->
              {[event], 1}

            1 ->
              send(parent, :read_next)
              {[], 2}

            _ ->
              {:halt, 2}
          end,
          fn _ -> send(parent, :producer_closed) end
        )

      stream = Telemetry.span_stream(Query.new("stream"), fn -> producer end)
      assert [^event] = Enum.take(stream, 1)
      refute_receive :read_next
      assert_receive :producer_closed
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

  describe "duplex telemetry helpers (#215)" do
    test "session start/stop emit with a duration and merged metadata" do
      mono = Telemetry.duplex_session_start(%{command: :duplex_session})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :session, :start], _, meta}
      assert meta.command == :duplex_session

      :ok = Telemetry.duplex_session_stop(mono, %{command: :duplex_session, session_id: "s1"})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :session, :stop], meas, stop_meta}
      assert is_integer(meas.duration)
      assert stop_meta.session_id == "s1"
    end

    test "turn start/stop emit; stop metadata overrides start" do
      span = Telemetry.duplex_turn_start(%{command: :duplex_turn, session_id: "s1"})

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :start], _,
                      %{command: :duplex_turn}}

      :ok = Telemetry.duplex_turn_stop(span, %{cost_usd: 0.05, exit_code: 0, session_id: "s2"})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :stop], meas, meta}
      assert is_integer(meas.duration)
      assert meta.cost_usd == 0.05
      # the stop payload wins over the start metadata's session_id
      assert meta.session_id == "s2"
    end

    test "turn exception carries the reason and a nil cost" do
      span = Telemetry.duplex_turn_start(%{command: :duplex_turn, session_id: "s1"})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :start], _, _}

      :ok = Telemetry.duplex_turn_exception(span, {:port_exit, 1})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :exception], _, meta}
      assert meta.reason == {:port_exit, 1}
      assert meta.cost_usd == nil
    end

    test "stop/exception are no-ops with a nil span context" do
      assert :ok = Telemetry.duplex_session_stop(nil, %{})
      assert :ok = Telemetry.duplex_turn_stop(nil, %{})
      assert :ok = Telemetry.duplex_turn_exception(nil, :whatever)
      refute_receive {:telemetry, [:claude_wrapper, :duplex, _, _], _, _}
    end
  end

  describe "DuplexSession emits the duplex events at its real boundaries (#215)" do
    # Same cat-loopback fake claude as DuplexSessionTest: inject NDJSON via the
    # port, which echoes it back for the session to dispatch.
    defp start_fake_duplex do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, pid} = DuplexSession.start_link(config: config, args_override: [])
      pid
    end

    defp inject(pid, term) do
      state = :sys.get_state(pid)
      Port.command(state.port, [Jason.encode!(term), ?\n])
    end

    test "session :start on open, :stop on stop" do
      pid = start_fake_duplex()
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :session, :start], _, _}

      DuplexSession.stop(pid)
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :session, :stop], _, _}
    end

    test "turn :start on send, :stop on the terminal result (with cost/session)" do
      pid = start_fake_duplex()
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :session, :start], _, _}

      # send/3 blocks until the result, so drive it from a separate process.
      spawn(fn -> DuplexSession.send(pid, "hi") end)

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :start], _,
                      %{command: :duplex_turn}},
                     1_000

      inject(pid, %{type: "result", subtype: "success", total_cost_usd: 0.05, session_id: "s-1"})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :stop], meas, meta}, 1_000
      assert is_integer(meas.duration)
      assert meta.cost_usd == 0.05
      assert meta.turn_cost_usd == 0.05
      assert meta.session_id == "s-1"

      # The second turn's cost_usd is the running total; turn_cost_usd is
      # the difference from the first (#319).
      spawn(fn -> DuplexSession.send(pid, "again") end)

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :start], _, _}, 1_000
      inject(pid, %{type: "result", subtype: "success", total_cost_usd: 0.125, session_id: "s-1"})
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :stop], _, meta}, 1_000
      assert meta.cost_usd == 0.125
      assert meta.turn_cost_usd == 0.075

      DuplexSession.stop(pid)
    end
  end

  describe "permission events (#324)" do
    defp can_use_tool(id, input \\ %{"command" => "rm -rf /tmp/x"}) do
      %{
        "type" => "control_request",
        "request_id" => id,
        "request" => %{"subtype" => "can_use_tool", "tool_name" => "Bash", "input" => input}
      }
    end

    defp decide(handler) do
      {:ok, session, stub} = CWTest.start_session(on_permission: handler)
      CWTest.emit(stub, can_use_tool("req-1"))

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :permission, :request], _, request},
                     1_000

      assert request == %{session_id: nil, request_id: "req-1", tool_name: "Bash"}

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :permission, :decision], meas,
                      decision},
                     1_000

      assert is_integer(meas.duration)
      refute Map.has_key?(decision, :input)
      DuplexSession.stop(session)
      decision
    end

    test "a synchronous handler's decision" do
      assert %{decision: :allow, source: :handler, tool_name: "Bash"} =
               decide(fn _tool, _input -> :allow end)

      assert %{decision: :allow_updated, source: :handler} =
               decide(fn _tool, input -> {:allow, input} end)

      assert %{decision: :deny, source: :handler} = decide(fn _tool, _input -> {:deny, "no"} end)
    end

    @tag :capture_log
    test "a raising handler is denied" do
      assert %{decision: :deny, source: :handler_raised} =
               decide(fn _tool, _input -> raise "boom" end)
    end

    @tag :capture_log
    test "a 2-arity :defer is denied" do
      assert %{decision: :deny, source: :defer_unsupported} =
               decide(fn _tool, _input -> :defer end)
    end

    test "a deferred request emits :defer, then the deferred answer" do
      assert %{decision: :defer, source: :handler} = decide_deferred()
    end

    defp decide_deferred do
      {:ok, session, stub} = CWTest.start_session(on_permission: fn _t, _i, _id -> :defer end)
      CWTest.emit(stub, can_use_tool("req-2"))

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :permission, :decision], first,
                      deferred},
                     1_000

      Process.sleep(5)
      :ok = DuplexSession.respond_to_permission(session, "req-2", {:deny, "later"})

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :permission, :decision], second,
                      %{
                        decision: :deny,
                        source: :deferred,
                        request_id: "req-2",
                        tool_name: "Bash"
                      }},
                     1_000

      assert second.duration > first.duration

      # A repeat answer is a no-op and emits nothing.
      :ok = DuplexSession.respond_to_permission(session, "req-2", :allow)
      refute_receive {:telemetry, [:claude_wrapper, :duplex, :permission, :decision], _, _}, 50
      DuplexSession.stop(session)
      deferred
    end
  end

  describe "interrupt events (#324)" do
    defp start_interrupt(session) do
      parent = self()
      spawn(fn -> send(parent, {:interrupted, DuplexSession.interrupt(session, 2_000)}) end)

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :interrupt, :start], _, start},
                     1_000

      assert start == %{session_id: nil, turn_pending?: false}
      await_pending_control(session)
    end

    defp await_pending_control(session) do
      case Map.keys(:sys.get_state(session).pending_control) do
        [id] ->
          id

        [] ->
          Process.sleep(2)
          await_pending_control(session)
      end
    end

    defp control_response(id, subtype) do
      response =
        if subtype == "success",
          do: %{"subtype" => "success", "request_id" => id, "response" => %{}},
          else: %{"subtype" => "error", "request_id" => id, "error" => "no turn"}

      %{"type" => "control_response", "response" => response}
    end

    test "an acknowledged interrupt" do
      {:ok, session, stub} = CWTest.start_session()
      id = start_interrupt(session)
      CWTest.emit(stub, control_response(id, "success"))

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :interrupt, :stop], meas,
                      %{outcome: :ok}},
                     1_000

      assert is_integer(meas.duration)
      assert_receive {:interrupted, :ok}
      DuplexSession.stop(session)
    end

    test "an interrupt the CLI answers with an error" do
      {:ok, session, stub} = CWTest.start_session()
      id = start_interrupt(session)
      CWTest.emit(stub, control_response(id, "error"))

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :interrupt, :stop], _,
                      %{outcome: :error}},
                     1_000

      assert_receive {:interrupted, {:error, _}}
      DuplexSession.stop(session)
    end

    test "an interrupt on a session that closes before the answer, and on a closed session" do
      {:ok, session, stub} = CWTest.start_session()
      _id = start_interrupt(session)
      CWTest.exit_status(stub, 0)

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :interrupt, :stop], _,
                      %{outcome: :closed}},
                     1_000

      assert_receive {:interrupted, {:error, _}}

      if DuplexSession.alive?(session) do
        assert {:error, _} = DuplexSession.interrupt(session, 1_000)

        assert_receive {:telemetry, [:claude_wrapper, :duplex, :interrupt, :stop], _,
                        %{outcome: :closed}},
                       1_000
      end
    end
  end

  describe "rate-limit events (#324)" do
    defp rate_limit_frame(status) do
      %{
        "type" => "rate_limit_event",
        "session_id" => "s-rl",
        "rate_limit_info" => %{"status" => status, "rateLimitType" => "five_hour"}
      }
    end

    test "from a DuplexSession" do
      {:ok, session, stub} = CWTest.start_session()
      CWTest.emit(stub, rate_limit_frame("allowed"))

      assert_receive {:telemetry, [:claude_wrapper, :rate_limit], %{system_time: _},
                      %{
                        session_id: "s-rl",
                        observation: %RateLimitObservation{status: "allowed"}
                      }},
                     1_000

      DuplexSession.stop(session)
    end

    @tag :tmp_dir
    test "from Query.stream/2", %{tmp_dir: dir} do
      config = Config.new(binary: fake_cli(dir, rate_limit_frame("rejected")), timeout: 5_000)
      Query.new("p") |> Query.stream(config) |> Enum.to_list()

      assert_receive {:telemetry, [:claude_wrapper, :rate_limit], _,
                      %{observation: %RateLimitObservation{status: "rejected"}}}

      assert_receive {:telemetry, [:claude_wrapper, :stream, :stop], _, stop}
      assert %{is_error: false, subtype: "success"} = stop
      assert stop.usage.input == 3
    end

    @tag :tmp_dir
    @tag :forcola
    test "from observed one-shot execution", %{tmp_dir: dir} do
      config =
        Config.new(
          binary: fake_cli(dir, rate_limit_frame("allowed")),
          runner: Runner.Forcola,
          timeout: 5_000
        )

      assert {:ok, _} =
               Query.execute(Query.new("p"), config, session_observer: {self(), make_ref()})

      assert_receive {:telemetry, [:claude_wrapper, :rate_limit], _,
                      %{session_id: "s-rl", observation: %RateLimitObservation{}}}
    end

    defp fake_cli(dir, frame) do
      result = %{
        "type" => "result",
        "subtype" => "success",
        "is_error" => false,
        "result" => "done",
        "session_id" => "s-rl",
        "usage" => %{"input_tokens" => 3, "output_tokens" => 4}
      }

      lines =
        [
          %{"type" => "system", "subtype" => "init", "session_id" => "s-rl"},
          frame,
          result
        ]
        |> Enum.map_join("", &"printf '%s\\n' '#{Jason.encode!(&1)}'\n")

      path = Path.join(dir, "fake_claude")
      File.write!(path, "#!/bin/sh\n" <> lines)
      File.chmod!(path, 0o755)
      path
    end
  end

  describe ":stop usage, is_error and subtype (#324)" do
    defp result_with_usage(subtype, is_error) do
      Result.from_json(%{
        "type" => "result",
        "subtype" => subtype,
        "is_error" => is_error,
        "result" => "secret text",
        "session_id" => "s-u",
        "usage" => %{"input_tokens" => 10, "output_tokens" => 5}
      })
    end

    test "exec" do
      Telemetry.span_exec(Query.new("p"), fn -> {:ok, result_with_usage("success", false)} end)
      assert_receive {:telemetry, [:claude_wrapper, :exec, :stop], _, meta}
      assert %{is_error: false, subtype: "success", usage: %{input: 10, output: 5}} = meta
      refute Enum.any?(Map.values(meta), &(&1 == "secret text"))

      Telemetry.span_exec(Query.new("p"), fn -> {:error, :boom} end)
      assert_receive {:telemetry, [:claude_wrapper, :exec, :stop], _, meta}
      assert %{is_error: true, subtype: nil, usage: nil} = meta
    end

    test "session turn" do
      session = %{session_id: nil, history: []}
      result = result_with_usage("success", false)

      Telemetry.span_session_turn(session, Query.new("p"), fn ->
        {:ok, %{session | history: [result]}, result}
      end)

      assert_receive {:telemetry, [:claude_wrapper, :session, :turn, :stop], _, meta}
      assert %{is_error: false, subtype: "success", usage: %{total: 15}} = meta
    end

    test "duplex turn reports an error_during_execution result" do
      {:ok, session, stub} = CWTest.start_session()
      task = Task.async(fn -> DuplexSession.send(session, "hi") end)
      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :start], _, _}, 1_000

      CWTest.emit_result(stub,
        subtype: "error_during_execution",
        is_error: true,
        usage: %{"input_tokens" => 7, "output_tokens" => 1}
      )

      assert_receive {:telemetry, [:claude_wrapper, :duplex, :turn, :stop], _, meta}, 1_000
      assert %{is_error: true, subtype: "error_during_execution", exit_code: 0} = meta
      assert meta.usage.input == 7
      Task.await(task)
      DuplexSession.stop(session)
    end

    test "stream without a result is an error when the wrapper ended it" do
      events = [%StreamEvent{type: "error", data: %{"error" => "stream_truncated"}, raw: nil}]
      Telemetry.span_stream(Query.new("p"), fn -> events end) |> Enum.to_list()
      assert_receive {:telemetry, [:claude_wrapper, :stream, :stop], _, meta}
      assert %{is_error: true, usage: nil, subtype: nil} = meta
    end
  end
end
