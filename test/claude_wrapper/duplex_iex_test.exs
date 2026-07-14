defmodule ClaudeWrapper.DuplexIExTest do
  # async: false because the helpers stash state in the process
  # dictionary; running concurrently with other tests in the same
  # process is fine, but we don't want to share that state across
  # parallel cases.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ClaudeWrapper.{Config, DuplexIEx, DuplexSession}

  setup do
    on_exit(fn -> safely_stop() end)
    :ok
  end

  defp safely_stop do
    DuplexIEx.close()
  catch
    _, _ -> :ok
  end

  defp start_with_fake_claude(opts \\ []) do
    config_opts = [binary: System.find_executable("cat")]
    # args_override bypasses build_args entirely so cat doesn't see
    # any real --flags. We can't go through DuplexIEx.start/1 with a
    # broken binary because it would crash; bypass with start_link.
    duplex_opts =
      [args_override: []]
      |> Keyword.merge(opts)

    config = Config.new(config_opts)

    {:ok, pid} = DuplexSession.start_link([config: config] ++ duplex_opts)
    pid
  end

  # The tricky bit for these tests: DuplexIEx.start/1 spawns the real
  # claude binary by default. To exercise the pure-function helpers
  # without hitting the network, we install a fake session manually
  # via the stash hook below.
  defp install_fake_session do
    pid = start_with_fake_claude()
    Process.put(:claude_wrapper_duplex_iex_session, pid)
    pid
  end

  describe "say/2" do
    test "prints error when no session is active" do
      output =
        capture_io(fn ->
          assert {:error, %ClaudeWrapper.Error{kind: :no_session}} = DuplexIEx.say("hi")
        end)

      assert output =~ "No active session"
    end
  end

  describe "interrupt/1" do
    test "returns a :no_session error when no session is active" do
      capture_io(fn ->
        assert {:error, %ClaudeWrapper.Error{kind: :no_session}} = DuplexIEx.interrupt()
      end)
    end
  end

  describe "close/0" do
    test "is a no-op when no session is running" do
      output = capture_io(fn -> assert :ok = DuplexIEx.close() end)
      assert output =~ "Session closed"
    end

    test "shuts down a running session and clears state" do
      pid = install_fake_session()
      assert Process.alive?(pid)

      capture_io(fn -> assert :ok = DuplexIEx.close() end)

      refute Process.get(:claude_wrapper_duplex_iex_session)
      refute Process.alive?(pid)
    end
  end

  describe "session_id/0 and pid/0" do
    test "return nil when no session" do
      assert is_nil(DuplexIEx.session_id())
      assert is_nil(DuplexIEx.pid())
    end

    test "session_id returns whatever the session reports" do
      _pid = install_fake_session()
      # Fake claude has no system/init, so session_id is nil.
      assert is_nil(DuplexIEx.session_id())
    end

    test "pid/0 returns the underlying DuplexSession pid" do
      pid = install_fake_session()
      assert DuplexIEx.pid() == pid
    end
  end

  describe "status/0" do
    test "prints :no_session when no session" do
      output = capture_io(fn -> assert :no_session = DuplexIEx.status() end)
      assert output =~ "No active session"
    end

    test "prints session id and pid when active" do
      _pid = install_fake_session()
      output = capture_io(fn -> assert :ok = DuplexIEx.status() end)
      assert output =~ "Session"
    end
  end

  describe "format_cost/1 (regression: #64)" do
    test "integer 0 does not raise (the original bug)" do
      # The CLI sometimes reports cost as an integer 0 -- e.g. cache-only
      # turns, or turns interrupted before billing. Float.round/2 is
      # strictly typed and raises FunctionClauseError on an integer.
      assert DuplexIEx.format_cost(0) == "$0.0"
    end

    test "non-zero integer cost is coerced and formatted" do
      assert DuplexIEx.format_cost(2) == "$2.0"
    end

    test "float cost is rounded to 4 decimals" do
      assert DuplexIEx.format_cost(0.123456789) == "$0.1235"
    end

    test "nil cost is rendered as ?" do
      assert DuplexIEx.format_cost(nil) == "?"
    end

    test "small float survives round-trip" do
      assert DuplexIEx.format_cost(0.0123) == "$0.0123"
    end
  end

  describe "handle_event/1 (stream printing)" do
    # The CLI wraps each streaming event as
    # %{"type" => "stream_event", "event" => %{...}}; build the realistic
    # content_block_delta envelope the printer now decodes via
    # StreamEvent.partial_message/1.
    defp text_delta(text, index \\ 0) do
      {:stream_event,
       %{
         "type" => "stream_event",
         "event" => %{
           "type" => "content_block_delta",
           "index" => index,
           "delta" => %{"type" => "text_delta", "text" => text}
         }
       }}
    end

    test "prints text deltas to stdout" do
      output = capture_io(fn -> DuplexIEx.handle_event(text_delta("hello")) end)
      assert output == "hello"
    end

    test "concatenates multiple deltas without newlines" do
      output =
        capture_io(fn ->
          DuplexIEx.handle_event(text_delta("hel"))
          DuplexIEx.handle_event(text_delta("lo"))
        end)

      assert output == "hello"
    end

    test "ignores non-text deltas" do
      output =
        capture_io(fn ->
          DuplexIEx.handle_event(
            {:stream_event,
             %{
               "type" => "stream_event",
               "event" => %{
                 "type" => "content_block_delta",
                 "index" => 0,
                 "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"x\":"}
               }
             }}
          )
        end)

      assert output == ""
    end

    test "prints a session marker on system_init" do
      output =
        capture_io(fn ->
          DuplexIEx.handle_event({:system_init, "abc-123"})
        end)

      assert output =~ "abc-123"
    end

    test "prints a tool result excerpt for user/tool_result events" do
      event =
        {:user,
         %{
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "content" => [%{"type" => "text", "text" => "hello world"}]
               }
             ]
           }
         }}

      output = capture_io(fn -> DuplexIEx.handle_event(event) end)
      assert output =~ "hello world"
    end

    test "truncates long tool results" do
      long_text = String.duplicate("x", 500)

      event =
        {:user,
         %{
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "content" => [%{"type" => "text", "text" => long_text}]
               }
             ]
           }
         }}

      output = capture_io(fn -> DuplexIEx.handle_event(event) end)
      # Truncated to 200 chars + ellipsis, ANSI dim codes around it.
      refute output =~ String.duplicate("x", 250)
      assert output =~ "…"
    end

    test "truncates long multibyte tool results without splitting a codepoint (#221)" do
      # Each "é" is 2 bytes; 200 of them is 400 bytes, so a byte-offset
      # truncation at 199 would land mid-codepoint and emit invalid UTF-8.
      long_text = String.duplicate("é", 200)

      event =
        {:user,
         %{
           "message" => %{
             "content" => [
               %{
                 "type" => "tool_result",
                 "content" => [%{"type" => "text", "text" => long_text}]
               }
             ]
           }
         }}

      output = capture_io(fn -> DuplexIEx.handle_event(event) end)
      assert String.valid?(output)
      assert output =~ "…"
    end

    test "ignores unknown events" do
      assert capture_io(fn ->
               DuplexIEx.handle_event({:other, %{}})
               DuplexIEx.handle_event(:weird)
             end) == ""
    end
  end

  describe "spawn_printer/1" do
    test "subscribes to the session and prints arriving events" do
      pid = start_with_fake_claude()

      output =
        capture_io(fn ->
          _printer = DuplexIEx.spawn_printer(pid)

          # Inject a stream_event via the same trick the unit suite
          # uses for DuplexSession: write JSON to cat's stdin.
          state = :sys.get_state(pid)

          Port.command(state.port, [
            Jason.encode!(%{
              type: "stream_event",
              event: %{
                type: "content_block_delta",
                index: 0,
                delta: %{type: "text_delta", text: "hi"}
              }
            }),
            ?\n
          ])

          # Wait briefly for the printer to receive and write.
          Process.sleep(100)
        end)

      assert output =~ "hi"

      DuplexSession.stop(pid)
    end
  end
end
