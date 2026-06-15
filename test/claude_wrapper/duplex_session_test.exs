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

    test "wires --permission-prompt-tool stdio so we receive can_use_tool requests" do
      args = DuplexSession.build_args([])
      idx = Enum.find_index(args, &(&1 == "--permission-prompt-tool"))

      assert idx != nil
      assert Enum.at(args, idx + 1) == "stdio"
    end
  end

  describe "default_allow_input/2" do
    test "plain :allow is rewritten to {:allow, input} so updatedInput round-trips" do
      input = %{"command" => "ls"}
      assert DuplexSession.default_allow_input(:allow, input) == {:allow, input}
    end

    test "{:allow, custom} is left alone (caller already supplied updatedInput)" do
      custom = %{"command" => "ls -la"}
      original = %{"command" => "ls"}
      assert DuplexSession.default_allow_input({:allow, custom}, original) == {:allow, custom}
    end

    test "{:deny, reason} is left alone" do
      assert DuplexSession.default_allow_input({:deny, "nope"}, %{"command" => "ls"}) ==
               {:deny, "nope"}
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

  describe "permissions (with fake claude)" do
    # cat echoes whatever the session writes back to stdout. We use that
    # property to capture the control_response payload: the session
    # writes a JSON line, cat echoes it, and the session re-dispatches
    # the echoed line as if it were inbound. control_response with no
    # matching pending request just gets dropped, so it's harmless --
    # but we can intercept the bytes by giving the session a custom
    # collector subscriber that records everything it sees.
    #
    # Easier path: peek directly at the captured request_id via the
    # callback itself, then verify a write happened by calling
    # :sys.get_state to see that the buffer/state didn't change in a
    # way that would imply a defer was in effect.
    #
    # In practice the cleanest verification is to (a) run the callback
    # with the right inputs (which we can capture by sending to a
    # known pid in the closure) and (b) verify defer truly defers by
    # asserting the callback returns `:defer` and confirming a later
    # respond_to_permission/3 call is accepted without raising.

    test "allow callback receives tool_name and input" do
      pid = start_with_fake_claude()
      parent = self()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | on_permission: fn tool, input ->
              Kernel.send(parent, {:asked, tool, input})
              :allow
            end
        }
      end)

      try do
        inject(pid, %{
          type: "control_request",
          request_id: "r1",
          request: %{
            subtype: "can_use_tool",
            tool_name: "Bash",
            input: %{"command" => "ls"}
          }
        })

        assert_receive {:asked, "Bash", %{"command" => "ls"}}, 1_000
      after
        DuplexSession.stop(pid)
      end
    end

    test "deny callback receives tool_name and input" do
      pid = start_with_fake_claude()
      parent = self()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | on_permission: fn tool, _input ->
              Kernel.send(parent, {:denied, tool})
              {:deny, "nope"}
            end
        }
      end)

      try do
        inject(pid, %{
          type: "control_request",
          request_id: "r2",
          request: %{
            subtype: "can_use_tool",
            tool_name: "Edit",
            input: %{"file" => "/tmp/x"}
          }
        })

        assert_receive {:denied, "Edit"}, 1_000
      after
        DuplexSession.stop(pid)
      end
    end

    test "defer callback does not crash; respond_to_permission/3 finishes the cycle" do
      pid = start_with_fake_claude()

      :sys.replace_state(pid, fn state ->
        %{state | on_permission: fn _tool, _input -> :defer end}
      end)

      try do
        inject(pid, %{
          type: "control_request",
          request_id: "deferred-1",
          request: %{
            subtype: "can_use_tool",
            tool_name: "Bash",
            input: %{}
          }
        })

        # If defer crashed the GenServer, this call would error.
        assert :ok = DuplexSession.respond_to_permission(pid, "deferred-1", :allow)

        # Calling respond_to_permission with :defer is rejected.
        assert {:error, %ClaudeWrapper.Error{kind: :cannot_defer_again}} =
                 DuplexSession.respond_to_permission(pid, "deferred-1", :defer)
      after
        DuplexSession.stop(pid)
      end
    end

    test "3-arity callback receives request_id" do
      pid = start_with_fake_claude()
      parent = self()

      :sys.replace_state(pid, fn state ->
        %{
          state
          | on_permission: fn tool, input, request_id ->
              Kernel.send(parent, {:asked3, tool, input, request_id})
              :defer
            end
        }
      end)

      try do
        inject(pid, %{
          type: "control_request",
          request_id: "abc-3-arity",
          request: %{
            subtype: "can_use_tool",
            tool_name: "Bash",
            input: %{"command" => "echo hi"}
          }
        })

        assert_receive {:asked3, "Bash", %{"command" => "echo hi"}, "abc-3-arity"}, 1_000

        # The handler returned :defer, so respond_to_permission/3 with
        # the captured id closes the cycle.
        assert :ok = DuplexSession.respond_to_permission(pid, "abc-3-arity", :allow)
      after
        DuplexSession.stop(pid)
      end
    end

    test "raising callback defaults to deny without crashing the session" do
      pid = start_with_fake_claude()

      :sys.replace_state(pid, fn state ->
        %{state | on_permission: fn _tool, _input -> raise "boom" end}
      end)

      try do
        ref = Process.monitor(pid)

        inject(pid, %{
          type: "control_request",
          request_id: "raise-1",
          request: %{subtype: "can_use_tool", tool_name: "Bash", input: %{}}
        })

        # GenServer should still be alive after the callback raised.
        refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
        assert Process.alive?(pid)
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "default deny_all/2" do
    test "denies any tool" do
      assert {:deny, _msg} = DuplexSession.deny_all("Bash", %{})
      assert {:deny, _msg} = DuplexSession.deny_all("Edit", %{"file" => "x"})
    end
  end

  describe "interrupt (with fake claude)" do
    # Capture the interrupt control_request as the session writes it,
    # extract the request_id, then synthesize a control_response with
    # that id. cat echoes our outbound control_request back to us as
    # if it were inbound -- the dispatch matches on type/request_id,
    # not direction, so the round-trip works.
    test "outbound control_request elicits a reply when the matching response arrives" do
      pid = start_with_fake_claude()
      parent = self()

      # Fork the interrupt call so we can drive the response from this
      # test process while the GenServer waits.
      caller =
        spawn_link(fn ->
          result = DuplexSession.interrupt(pid, 5_000)
          Kernel.send(parent, {:interrupt_returned, result})
        end)

      try do
        # Poll the GenServer state until we see the pending_control entry.
        request_id =
          poll_for(fn ->
            case :sys.get_state(pid).pending_control do
              %{} = m when map_size(m) == 1 -> {:ok, m |> Map.keys() |> hd()}
              _ -> :not_yet
            end
          end)

        # Now inject a synthetic control_response with that id.
        inject(pid, %{
          type: "control_response",
          response: %{
            subtype: "success",
            request_id: request_id
          }
        })

        assert_receive {:interrupt_returned, :ok}, 5_000
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        DuplexSession.stop(pid)
      end
    end

    test "control_response with subtype error is propagated" do
      pid = start_with_fake_claude()
      parent = self()

      caller =
        spawn_link(fn ->
          result = DuplexSession.interrupt(pid, 5_000)
          Kernel.send(parent, {:interrupt_returned, result})
        end)

      try do
        request_id =
          poll_for(fn ->
            case :sys.get_state(pid).pending_control do
              %{} = m when map_size(m) == 1 -> {:ok, m |> Map.keys() |> hd()}
              _ -> :not_yet
            end
          end)

        inject(pid, %{
          type: "control_response",
          response: %{
            subtype: "error",
            request_id: request_id,
            error: "boom"
          }
        })

        assert_receive {:interrupt_returned,
                        {:error,
                         %ClaudeWrapper.Error{kind: :duplex_control_failed, reason: "boom"}}},
                       5_000
      after
        if Process.alive?(caller), do: Process.exit(caller, :kill)
        DuplexSession.stop(pid)
      end
    end

    test "interrupt request_ids are unique" do
      # Smoke check that consecutive interrupts get distinct ids.
      # 16 random bytes makes collisions astronomically unlikely; this
      # is just sanity-checking the helper.
      ids = for _ <- 1..50, do: uniq_request_id_via_interrupt()
      assert length(Enum.uniq(ids)) == length(ids)
    end

    test "control_response with no matching pending request is dropped" do
      pid = start_with_fake_claude()

      try do
        # No outbound interrupt issued. Inject a stray response.
        inject(pid, %{
          type: "control_response",
          response: %{subtype: "success", request_id: "stranger-id"}
        })

        # GenServer should still be alive and responsive.
        assert Process.alive?(pid)
        assert :sys.get_state(pid).pending_control == %{}
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "close/1" do
    test "is equivalent to stop/3 normal" do
      pid = start_with_fake_claude()
      ref = Process.monitor(pid)

      assert :ok = DuplexSession.close(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000
      refute Process.alive?(pid)
    end
  end

  describe "alive?/1" do
    test "true for a live session, false after close" do
      pid = start_with_fake_claude()

      assert DuplexSession.alive?(pid) == true

      :ok = DuplexSession.close(pid)
      refute Process.alive?(pid)
      assert DuplexSession.alive?(pid) == false
    end

    test "false for an unregistered name" do
      assert DuplexSession.alive?(:no_such_duplex_session) == false
    end
  end

  describe "exit_status/1" do
    test "is :running while the session is live" do
      pid = start_with_fake_claude()

      try do
        assert DuplexSession.exit_status(pid) == :running
      after
        DuplexSession.stop(pid)
      end
    end

    test "reads :completed once the process is gone (clean close)" do
      pid = start_with_fake_claude()
      ref = Process.monitor(pid)

      :ok = DuplexSession.close(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      assert DuplexSession.exit_status(pid) == :completed
    end

    test "is a best-effort snapshot: a failed subprocess exit still reads :completed once dead" do
      # exit_status/1 keeps no persisted terminal status, so a dead
      # session always reads :completed regardless of how it died. The
      # failure reason is only available via wait_for_exit/2 (covered
      # below). This locks the documented snapshot semantics.
      pid = start_with_fake_claude()
      ref = Process.monitor(pid)
      port = :sys.get_state(pid).port

      Kernel.send(pid, {port, {:exit_status, 1}})
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      assert DuplexSession.exit_status(pid) == :completed
    end

    test "is :completed for an unregistered name" do
      assert DuplexSession.exit_status(:no_such_duplex_session) == :completed
    end
  end

  describe "wait_for_exit/2" do
    test "returns :completed promptly after the session is closed" do
      pid = start_with_fake_claude()
      :ok = DuplexSession.close(pid)

      assert DuplexSession.wait_for_exit(pid, 1_000) == :completed
    end

    test "returns immediately if the session has already exited" do
      pid = start_with_fake_claude()
      ref = Process.monitor(pid)
      :ok = DuplexSession.close(pid)
      assert_receive {:DOWN, ^ref, :process, ^pid, :normal}, 1_000

      # Process is already gone; the call must not block.
      assert DuplexSession.wait_for_exit(pid, 1_000) == :completed
    end

    test "blocks until a live session exits, then returns :completed" do
      pid = start_with_fake_claude()
      parent = self()

      task =
        Task.async(fn ->
          Kernel.send(parent, :waiting)
          DuplexSession.wait_for_exit(pid, 5_000)
        end)

      # Wait until the waiter has actually registered on the session, so
      # the terminal status flows through the {:duplex_exit, ...} path.
      assert_receive :waiting, 1_000
      wait_until(fn -> map_size(:sys.get_state(pid).exit_waiters) == 1 end)

      :ok = DuplexSession.close(pid)
      assert Task.await(task, 5_000) == :completed
    end

    test "surfaces a failed subprocess exit to a blocked waiter" do
      pid = start_with_fake_claude()
      port = :sys.get_state(pid).port

      task = Task.async(fn -> DuplexSession.wait_for_exit(pid, 5_000) end)

      # Ensure the waiter is registered before driving the non-zero exit,
      # so the {:failed, ...} status is delivered via {:duplex_exit, ...}.
      wait_until(fn -> map_size(:sys.get_state(pid).exit_waiters) == 1 end)
      Kernel.send(pid, {port, {:exit_status, 2}})

      assert Task.await(task, 5_000) == {:failed, {:port_exit, 2}}
    end

    test "falls back to the monitor when the session is hard-killed" do
      # A hard kill is untrappable: terminate/2 never runs, so no
      # {:duplex_exit, ...} is sent even though the waiter registered.
      # This exercises the :DOWN fallback, where a non-:normal exit
      # reason (:killed) maps to {:failed, reason}.
      pid = start_with_fake_claude_quiet()
      parent = self()

      spawn(fn ->
        status = DuplexSession.wait_for_exit(pid, 5_000)
        Kernel.send(parent, {:waited, status})
      end)

      # Register first so the test is deterministic; the kill still skips
      # terminate/2, forcing the monitor path.
      wait_until(fn -> map_size(:sys.get_state(pid).exit_waiters) == 1 end)
      Process.exit(pid, :kill)

      assert_receive {:waited, {:failed, :killed}}, 5_000
    end

    test "returns :running on timeout while the session is still alive" do
      pid = start_with_fake_claude()

      try do
        assert DuplexSession.wait_for_exit(pid, 50) == :running
        assert Process.alive?(pid)
      after
        DuplexSession.stop(pid)
      end
    end

    test "returns :completed for an unregistered name" do
      assert DuplexSession.wait_for_exit(:no_such_duplex_session, 100) == :completed
    end
  end

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

  # Fire an interrupt and return its request_id, without waiting for
  # any response. Used by the uniqueness smoke test.
  defp uniq_request_id_via_interrupt do
    pid = start_with_fake_claude_quiet()

    spawn(fn ->
      _ = DuplexSession.interrupt(pid, 1_000)
    end)

    request_id =
      poll_for(fn ->
        case :sys.get_state(pid).pending_control do
          %{} = m when map_size(m) == 1 -> {:ok, m |> Map.keys() |> hd()}
          _ -> :not_yet
        end
      end)

    GenServer.stop(pid, :normal, 1_000)
    request_id
  end

  defp start_with_fake_claude_quiet do
    # Trap so the test process stays alive even if the spawned interrupt
    # caller crashes when we kill the session.
    Process.flag(:trap_exit, true)
    config = Config.new(binary: System.find_executable("cat"))
    {:ok, pid} = DuplexSession.start_link(config: config, args_override: [])
    pid
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
