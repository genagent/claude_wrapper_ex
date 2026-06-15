defmodule ClaudeWrapper.ConversationTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Conversation, DuplexSession, Result}

  # Spawn a DuplexSession against `cat` (same pattern as
  # DuplexSessionTest): cat echoes whatever the session writes to its
  # stdin back out, but it never produces `result` events on its own.
  # We drive turn completion by injecting a synthetic `result` line from
  # the test process while a `Conversation.send/3` call blocks in a
  # separate process.
  defp start_with_fake_claude do
    config = Config.new(binary: System.find_executable("cat"))
    {:ok, pid} = DuplexSession.start_link(config: config, args_override: [])
    pid
  end

  # Inject a raw NDJSON term into the running session's port. Yields via
  # :sys.get_state/1 so the inbound :data message is processed first.
  defp inject(session, term) do
    state = :sys.get_state(session)
    Port.command(state.port, [Jason.encode!(term), ?\n])
    :sys.get_state(session)
  end

  # Run one full turn: kick off Conversation.send/3 in a child process,
  # wait until the underlying session registers the pending turn, inject
  # a `result` carrying the given fields, and return the {:ok, conv,
  # result} tuple the send produced.
  defp run_turn(conversation, prompt, result_fields) do
    parent = self()
    session = Conversation.session(conversation)

    spawn_link(fn ->
      reply = Conversation.send(conversation, prompt, 5_000)
      Kernel.send(parent, {:turn_done, reply})
    end)

    # Wait for the session to mark a turn in flight, then complete it.
    poll_for(fn ->
      case :sys.get_state(session).pending_turn do
        {_from, _events} -> {:ok, :pending}
        _ -> :not_yet
      end
    end)

    inject(session, Map.merge(%{type: "result"}, result_fields))

    receive do
      {:turn_done, reply} -> reply
    after
      5_000 -> flunk("turn did not complete")
    end
  end

  describe "new/1" do
    test "starts with an empty history and the given session" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)

        assert conv.session == pid
        assert Conversation.history(conv) == []
        assert Conversation.turn_count(conv) == 0
        assert Conversation.total_cost(conv) == 0.0
        assert Conversation.last_result(conv) == nil
        assert Conversation.session(conv) == pid
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "send/3" do
    test "accumulates history, cost, and turn count across turns" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)

        assert {:ok, conv, %Result{} = r1} =
                 run_turn(conv, "hello", %{
                   result: "hi there",
                   session_id: "sess-1",
                   total_cost_usd: 0.01
                 })

        assert r1.result == "hi there"
        assert Conversation.turn_count(conv) == 1
        assert_in_delta Conversation.total_cost(conv), 0.01, 1.0e-9
        assert Conversation.last_result(conv) == r1

        assert {:ok, conv, %Result{} = r2} =
                 run_turn(conv, "again", %{
                   result: "second",
                   session_id: "sess-1",
                   total_cost_usd: 0.02
                 })

        assert Conversation.turn_count(conv) == 2
        assert_in_delta Conversation.total_cost(conv), 0.03, 1.0e-9
        assert Conversation.history(conv) == [r1, r2]
        assert Conversation.last_result(conv) == r2
      after
        DuplexSession.stop(pid)
      end
    end

    test "treats a turn with no cost as 0.0" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)

        assert {:ok, conv, _result} =
                 run_turn(conv, "hello", %{result: "ok", session_id: "sess-1"})

        assert Conversation.turn_count(conv) == 1
        assert Conversation.total_cost(conv) == 0.0
      after
        DuplexSession.stop(pid)
      end
    end

    test "propagates a :turn_in_flight error without recording a turn" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)
        session = Conversation.session(conv)

        # Occupy the session with an in-flight turn that we never finish.
        parent = self()

        spawn_link(fn ->
          _ = Conversation.send(conv, "first", 5_000)
          Kernel.send(parent, :first_done)
        end)

        poll_for(fn ->
          case :sys.get_state(session).pending_turn do
            {_from, _events} -> {:ok, :pending}
            _ -> :not_yet
          end
        end)

        # A second concurrent send must be rejected, leaving history empty.
        assert {:error, %ClaudeWrapper.Error{kind: :turn_in_flight}} =
                 Conversation.send(conv, "second", 1_000)

        assert Conversation.turn_count(conv) == 0
      after
        DuplexSession.stop(pid)
      end
    end

    test "propagates a :duplex_closed error without recording a turn" do
      # A session whose port has been closed but whose GenServer is still
      # alive replies {:error, %Error{kind: :duplex_closed}}. We reach that state by
      # nil-ing the port via :sys.replace_state, which leaves the
      # GenServer running so it can answer the call.
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)

        # Close and drop the real port so the send-with-nil-port clause
        # is exercised, but keep the GenServer process alive.
        :sys.replace_state(pid, fn state ->
          if is_port(state.port) and Port.info(state.port) != nil do
            Port.close(state.port)
          end

          %{state | port: nil}
        end)

        assert {:error, %ClaudeWrapper.Error{kind: :duplex_closed}} =
                 Conversation.send(conv, "hello", 1_000)

        assert Conversation.turn_count(conv) == 0
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "session_id/1" do
    test "is nil before any turn or init" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)
        assert Conversation.session_id(conv) == nil
      after
        DuplexSession.stop(pid)
      end
    end

    test "falls back to the live session id from system/init" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)
        inject(pid, %{type: "system", subtype: "init", session_id: "init-abc"})

        # The init line round-trips through `cat` async; poll until the
        # underlying session has recorded it.
        poll_for(fn ->
          case Conversation.session_id(conv) do
            "init-abc" -> {:ok, :seen}
            _ -> :not_yet
          end
        end)

        assert Conversation.session_id(conv) == "init-abc"
      after
        DuplexSession.stop(pid)
      end
    end

    test "prefers the most recent recorded turn's session id" do
      pid = start_with_fake_claude()

      try do
        conv = Conversation.new(pid)

        assert {:ok, conv, _r} =
                 run_turn(conv, "hello", %{result: "ok", session_id: "turn-xyz"})

        assert Conversation.session_id(conv) == "turn-xyz"
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "close/1" do
    test "stops the underlying session" do
      pid = start_with_fake_claude()
      ref = Process.monitor(pid)

      conv = Conversation.new(pid)

      assert :ok = Conversation.close(conv)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      refute Process.alive?(pid)

      # History survives the underlying session being gone.
      assert Conversation.history(conv) == []
    end
  end

  # --- Helpers --------------------------------------------------------

  defp poll_for(fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_poll_for(fun, deadline)
  end

  defp do_poll_for(fun, deadline) do
    case fun.() do
      {:ok, value} ->
        value

      _ ->
        if System.monotonic_time(:millisecond) > deadline do
          flunk("poll_for: condition not met before deadline")
        else
          Process.sleep(10)
          do_poll_for(fun, deadline)
        end
    end
  end
end
