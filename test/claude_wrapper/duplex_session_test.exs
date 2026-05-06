defmodule ClaudeWrapper.DuplexSessionTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession}

  # Helper: spawn a DuplexSession against `cat` so we can inject NDJSON
  # bytes via Port.command/2 and observe how the GenServer demuxes them.
  # cat does not understand the duplex flags but it doesn't have to --
  # Port.command writes raw bytes to its stdin, which `cat` echoes back
  # to stdout. The duplex_session reads and dispatches them as if they
  # came from real claude.
  defp start_with_fake_claude do
    config = Config.new(binary: System.find_executable("cat"))
    # cat does not understand the duplex flags, so override args entirely
    # via the test-only :args_override hook.
    {:ok, pid} = DuplexSession.start_link(config: config, args_override: [])
    pid
  end

  defp inject(pid, term) do
    state = :sys.get_state(pid)
    Port.command(state.port, [Jason.encode!(term), ?\n])
    # Yield so the inbound :data message is processed before we return.
    :sys.get_state(pid)
  end

  describe "split_lines/1" do
    test "empty buffer yields no complete lines" do
      assert {[], ""} = DuplexSession.split_lines("")
    end

    test "buffer with no newline is all trailing" do
      assert {[], "partial"} = DuplexSession.split_lines("partial")
    end

    test "single complete line, no trailing" do
      assert {["a"], ""} = DuplexSession.split_lines("a\n")
    end

    test "single complete line plus trailing partial" do
      assert {["a"], "b"} = DuplexSession.split_lines("a\nb")
    end

    test "multiple complete lines" do
      assert {["a", "b", "c"], ""} = DuplexSession.split_lines("a\nb\nc\n")
    end

    test "multiple complete lines plus trailing partial" do
      assert {["a", "b"], "partial"} = DuplexSession.split_lines("a\nb\npartial")
    end

    test "empty lines are preserved (handled by caller)" do
      assert {["", "a", ""], ""} = DuplexSession.split_lines("\na\n\n")
    end

    test "json payload with embedded special characters" do
      line = ~s({"type":"user","message":{"content":"line1\\nline2 with \\"quote\\""}})
      bin = line <> "\n"
      assert {[^line], ""} = DuplexSession.split_lines(bin)
    end
  end

  describe "build_args/1" do
    test "includes the duplex flag set" do
      args = DuplexSession.build_args([])

      assert "--input-format" in args
      assert "stream-json" in args
      assert "--output-format" in args
      assert "--include-partial-messages" in args
      assert "--verbose" in args
      assert "--print" in args
    end

    test "appends extra args after the base flags" do
      args = DuplexSession.build_args(["--max-turns", "1"])
      assert List.last(args) == "1"
      assert Enum.at(args, -2) == "--max-turns"
    end

    test "input-format and output-format are paired correctly" do
      args = DuplexSession.build_args([])
      input_idx = Enum.find_index(args, &(&1 == "--input-format"))
      output_idx = Enum.find_index(args, &(&1 == "--output-format"))

      assert Enum.at(args, input_idx + 1) == "stream-json"
      assert Enum.at(args, output_idx + 1) == "stream-json"
    end
  end

  describe "subscribe / unsubscribe (with fake claude)" do
    test "broadcasts assistant events to subscribers" do
      pid = start_with_fake_claude()

      try do
        :ok = DuplexSession.subscribe(pid)

        inject(pid, %{type: "assistant", message: %{content: "hi"}, session_id: "s1"})

        assert_receive {:claude, {:assistant, %{"type" => "assistant"}}}, 1_000
      after
        DuplexSession.stop(pid)
      end
    end

    test "broadcasts system_init with the session id" do
      pid = start_with_fake_claude()

      try do
        :ok = DuplexSession.subscribe(pid)

        inject(pid, %{type: "system", subtype: "init", session_id: "abc-123"})

        assert_receive {:claude, {:system_init, "abc-123"}}, 1_000
        assert DuplexSession.session_id(pid) == "abc-123"
      after
        DuplexSession.stop(pid)
      end
    end

    test "broadcasts stream_event and user events" do
      pid = start_with_fake_claude()

      try do
        :ok = DuplexSession.subscribe(pid)

        inject(pid, %{type: "stream_event", event: %{delta: "hel"}})
        inject(pid, %{type: "user", message: %{content: "tool result"}})

        assert_receive {:claude, {:stream_event, %{"type" => "stream_event"}}}, 1_000
        assert_receive {:claude, {:user, %{"type" => "user"}}}, 1_000
      after
        DuplexSession.stop(pid)
      end
    end

    test "subscribing twice does not double-deliver" do
      pid = start_with_fake_claude()

      try do
        :ok = DuplexSession.subscribe(pid)
        :ok = DuplexSession.subscribe(pid)

        inject(pid, %{type: "assistant", message: %{}, session_id: "s1"})

        assert_receive {:claude, {:assistant, _}}, 1_000
        refute_receive {:claude, {:assistant, _}}, 200
      after
        DuplexSession.stop(pid)
      end
    end

    test "unsubscribe stops further messages" do
      pid = start_with_fake_claude()

      try do
        :ok = DuplexSession.subscribe(pid)
        :ok = DuplexSession.unsubscribe(pid)

        inject(pid, %{type: "assistant", message: %{}, session_id: "s1"})

        refute_receive {:claude, _}, 200
      after
        DuplexSession.stop(pid)
      end
    end

    test "subscribers are auto-removed when they exit" do
      pid = start_with_fake_claude()

      try do
        # A short-lived subscriber that subscribes, waits for an ack,
        # then dies. The session should detect the :DOWN and drop it.
        parent = self()

        sub =
          spawn(fn ->
            :ok = DuplexSession.subscribe(pid)
            Kernel.send(parent, :subscribed)

            receive do
              :exit -> :ok
            end
          end)

        assert_receive :subscribed, 1_000
        assert :sys.get_state(pid).subscribers |> Map.has_key?(sub)

        Kernel.send(sub, :exit)

        # Wait for the GenServer to process the :DOWN.
        wait_until(fn ->
          not Map.has_key?(:sys.get_state(pid).subscribers, sub)
        end)
      after
        DuplexSession.stop(pid)
      end
    end
  end

  defp wait_until(fun, deadline_ms \\ 1_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_wait_until(fun, deadline)
  end

  defp do_wait_until(fun, deadline) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("condition not met before deadline")

      true ->
        Process.sleep(10)
        do_wait_until(fun, deadline)
    end
  end
end
