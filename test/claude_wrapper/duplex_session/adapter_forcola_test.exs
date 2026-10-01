defmodule ClaudeWrapper.DuplexSession.Adapter.ForcolaTest do
  use ExUnit.Case, async: true

  # Drives the real forcola shim; skipped when it is not resolvable.
  @moduletag :forcola

  alias ClaudeWrapper.{Config, DuplexSession}
  alias ClaudeWrapper.DuplexSession.Adapter.Forcola

  describe "adapter callbacks" do
    test "forwards one stdout line at a time and waits for acknowledgement" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())

      # cat echoes stdin; the session frames writes as [json, ?\n].
      :ok = Forcola.command(handle, [~s({"type":"user"}), ?\n])

      assert_receive {^handle, {:data, "{\"type\":\"user\"}\n", ref}}, 2_000
      assert :ok = Forcola.ack(handle, ref)

      :ok = Forcola.close(handle)
    end

    test "close/1 terminates the transport and puller" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())

      assert Process.alive?(handle.session.pid)
      assert Process.alive?(handle.puller)
      :ok = Forcola.close(handle)
      refute Process.alive?(handle.session.pid)
      refute Process.alive?(handle.puller)
    end

    test "close/1 on an already-dead handle is idempotent" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())
      :ok = Forcola.close(handle)
      assert :ok = Forcola.close(handle)
    end

    test "keeps stderr separate and forwards native terminal evidence" do
      config = Config.new(binary: System.find_executable("sh"))

      {:ok, handle} =
        Forcola.open(
          config: config,
          args: ["-c", "printf 'diagnostic\\n' >&2; printf 'output\\n'; exit 7"],
          owner: self()
        )

      lines =
        for _ <- 1..2 do
          receive do
            {^handle, {stream, line, ref}} when stream in [:data, :stderr] ->
              Forcola.ack(handle, ref)
              {stream, line}
          after
            2_000 -> flunk("transport did not deliver both streams")
          end
        end

      assert Enum.sort(lines) == Enum.sort([{:stderr, "diagnostic"}, {:data, "output\n"}])
      assert_receive {^handle, {:terminal, %Elixir.Forcola.Duplex.Terminal{} = terminal}}, 2_000
      assert terminal.status == 7
      assert terminal.confirmation == :confirmed
    end
  end

  describe "driving a DuplexSession through the adapter" do
    setup do
      # A minimal fake claude: for each stdin line, emit an assistant
      # message and a terminal result event.
      script = """
      #!/bin/sh
      while IFS= read -r line; do
        printf '{"type":"assistant","message":{"content":"ok"},"session_id":"s1"}\\n'
        printf '{"type":"result","subtype":"success","result":"done","is_error":false,"session_id":"s1"}\\n'
      done
      """

      path = Path.join(System.tmp_dir!(), "fake_claude_#{System.unique_integer([:positive])}.sh")
      File.write!(path, script)
      File.chmod!(path, 0o755)
      on_exit(fn -> File.rm(path) end)

      {:ok, binary: path}
    end

    test "completes turns and parses the result event", %{binary: binary} do
      config = Config.new(binary: binary)

      {:ok, pid} =
        DuplexSession.start_link(config: config, adapter: Forcola, args_override: [])

      assert {:ok, %ClaudeWrapper.Result{result: "done", session_id: "s1"}} =
               DuplexSession.send(pid, "hi", 5_000)

      assert {:ok, %ClaudeWrapper.Result{}} = DuplexSession.send(pid, "again", 5_000)

      :ok = DuplexSession.stop(pid)
    end

    test "shutdown retains cleanup evidence separately from a completed provider result", %{
      binary: binary
    } do
      config = Config.new(binary: binary)

      {:ok, pid} =
        DuplexSession.start_link(config: config, adapter: Forcola, args_override: [])

      assert {:ok, %ClaudeWrapper.Result{result: "done"}} = DuplexSession.send(pid, "hi", 5_000)

      assert {:ok, %DuplexSession.TransportTerminal{} = outcome} =
               DuplexSession.shutdown(pid)

      assert outcome.evidence.confirmation == :confirmed
      assert outcome.evidence.cause == :explicit_close
      assert outcome.evidence.scope in [:process_group, :active_cgroup]
      assert outcome.stderr == ""
    end

    test "bounded stderr stays out of NDJSON and is returned with shutdown" do
      config = Config.new(binary: System.find_executable("sh"))

      script =
        ~s(while IFS= read -r line; do printf 'first diagnostic\\nsecond diagnostic\\n' >&2; printf '{"type":"result","subtype":"success","result":"done","is_error":false}\\n'; done)

      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          adapter: Forcola,
          args_override: ["-c", script],
          adapter_opts: [stderr_capture_bytes: 18]
        )

      assert {:ok, %ClaudeWrapper.Result{result: "done"}} = DuplexSession.send(pid, "hi", 5_000)
      await_stderr_tail(pid, "diagnostic\n")
      assert {:ok, %DuplexSession.TransportTerminal{stderr: stderr}} = DuplexSession.shutdown(pid)
      assert byte_size(stderr) <= 18
      assert String.ends_with?(stderr, "diagnostic\n")
    end

    test "line limit reports typed output evidence" do
      config = Config.new(binary: System.find_executable("sh"))

      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          adapter: Forcola,
          args_override: ["-c", "read line; printf '%0100d\\n' 0"],
          adapter_opts: [max_line_bytes: 32, max_pending_bytes: 33, max_output_bytes: 256]
        )

      :ok = DuplexSession.subscribe(pid)
      assert {:error, _} = DuplexSession.send(pid, "hi", 5_000)

      assert_receive {:claude,
                      {:transport_terminal,
                       %DuplexSession.TransportTerminal{
                         evidence: %Elixir.Forcola.Duplex.Terminal{
                           output: {:limit, :line, :stdout, 32}
                         }
                       }}},
                     5_000
    end

    test "a natural nonzero child exit reaches waiters as structured evidence" do
      config = Config.new(binary: System.find_executable("sh"))

      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          adapter: Forcola,
          args_override: ["-c", "read line; exit 7"]
        )

      waiter = Task.async(fn -> DuplexSession.wait_for_exit(pid, 5_000) end)
      await_exit_waiter(pid)

      assert {:error, %ClaudeWrapper.Error{reason: {:transport_terminal, evidence}}} =
               DuplexSession.send(pid, "hi", 5_000)

      assert evidence.status == 7
      assert evidence.confirmation == :confirmed
      assert {:failed, {:transport_terminal, ^evidence}} = Task.await(waiter, 5_000)
    end

    test "an independent recipient retains terminal evidence after owner death" do
      config = Config.new(binary: System.find_executable("sh"))

      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          adapter: Forcola,
          args_override: ["-c", "sleep 30"],
          adapter_opts: [terminal_recipient: self()]
        )

      Process.unlink(pid)
      Process.exit(pid, :kill)

      assert_receive {:forcola_terminal, _session,
                      %Elixir.Forcola.Duplex.Terminal{
                        cause: :owner_death,
                        confirmation: :confirmed
                      }},
                     10_000
    end

    test "a synthetic unconfirmed terminal is not mapped to exit code 1" do
      # Inject only the terminal message shape; this does not claim that
      # native cleanup was actually unconfirmed in this test.
      config = Config.new(binary: System.find_executable("sh"))

      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          adapter: Forcola,
          args_override: ["-c", "read line; sleep 30"]
        )

      handle = :sys.get_state(pid).port
      pending = Task.async(fn -> DuplexSession.send(pid, "hi", 5_000) end)
      await_pending_turn(pid)

      evidence = %Elixir.Forcola.Duplex.Terminal{
        status: nil,
        confirmation: :unconfirmed,
        cause: :session_lost,
        scope: :unknown,
        output: :unknown
      }

      send(pid, {handle, {:terminal, evidence}})

      assert {:error, %ClaudeWrapper.Error{reason: {:transport_terminal, ^evidence}}} =
               Task.await(pending, 5_000)
    end
  end

  defp await_pending_turn(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if :sys.get_state(pid).pending_turn do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        await_pending_turn(pid, deadline)
      else
        flunk("the test prompt never became pending")
      end
    end
  end

  defp await_exit_waiter(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if map_size(:sys.get_state(pid).exit_waiters) > 0 do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        await_exit_waiter(pid, deadline)
      else
        flunk("the exit waiter never registered")
      end
    end
  end

  defp await_stderr_tail(pid, expected, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    if String.ends_with?(:sys.get_state(pid).stderr, expected) do
      :ok
    else
      if System.monotonic_time(:millisecond) < deadline do
        Process.sleep(10)
        await_stderr_tail(pid, expected, deadline)
      else
        flunk("stderr was not captured before shutdown")
      end
    end
  end
end
