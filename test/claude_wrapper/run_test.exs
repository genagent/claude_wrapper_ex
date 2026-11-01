defmodule ClaudeWrapper.RunTest do
  # Drives ClaudeWrapper.Run against fake `claude` executables under the real
  # Forcola runner (required evidence contract, like
  # forcola_evidenced_test.exs), plus fake runners for the paths Forcola
  # cannot reach.
  use ExUnit.Case, async: false

  @moduletag :forcola_evidence

  alias ClaudeWrapper.{
    Command,
    Config,
    Error,
    ExecutionEvidence,
    Query,
    RateLimitObservation,
    Result,
    Run,
    Runner,
    StreamEvent
  }

  setup do
    directory = Path.join(System.tmp_dir!(), "cw_run_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, pidfile: Path.join(directory, "pid")}
  end

  describe "success and failure" do
    test "frames arrive in stream order, then done; await returns the result and one record",
         context do
      config =
        fixture(
          context,
          emit(init()) <> emit(rate_limit()) <> emit(assistant()) <> emit(result())
        )

      reference = make_ref()
      {:ok, run} = Run.start(Query.new("hi"), config, execution_observer: {self(), reference})
      ref = run.ref

      assert {:ok, %Result{result: "done"} = result, %ExecutionEvidence{} = evidence} =
               Run.await(run, 5_000)

      types =
        for _ <- 1..4 do
          assert_receive {^ref, {:frame, %StreamEvent{type: type}}}, 1_000
          type
        end

      assert types == ["system", "rate_limit_event", "assistant", "result"]
      assert_receive {^ref, {:done, :succeeded}}, 1_000

      assert_receive {^reference, ^evidence}
      refute_receive {^reference, _}, 50

      assert evidence.outcome == {:ok, result}
      assert evidence.runner == Runner.Forcola
      assert evidence.execution == :started
      assert evidence.child_status == 0
      assert evidence.cleanup == :confirmed
      assert evidence.reason == nil
      assert evidence.session_id == "native-session"

      assert %{
               status: :succeeded,
               session_id: "native-session",
               frames: 4,
               frames_dropped: 0,
               rate_limit: %RateLimitObservation{status: "allowed"},
               elapsed_ms: elapsed
             } = Run.snapshot(run)

      assert is_integer(elapsed)
      # Repeated awaits return the same outcome and record.
      assert Run.await(run) == {:ok, result, evidence}
    end

    test "a nonzero exit without a result is a command failure with its evidence", context do
      config = fixture(context, "echo boom >&2\nexit 3\n")
      {:ok, run} = Run.start(Query.new("hi"), config)

      assert {:error, %Error{kind: :command_failed, exit_code: 3}, evidence} =
               Run.await(run, 5_000)

      assert evidence.child_status == 3
      assert evidence.stderr =~ "boom"
      assert %{status: :failed} = Run.snapshot(run)
      ref = run.ref
      assert_receive {^ref, {:done, :failed}}
    end
  end

  describe "timeouts" do
    test "an await timeout leaves the run going", context do
      config = fixture(context, emit(init()) <> "sleep 0.5\n" <> emit(result()))
      {:ok, run} = Run.start(Query.new("hi"), config)

      assert Run.await(run, 50) == :timeout
      assert %{status: :running} = Run.snapshot(run)
      assert {:ok, %Result{result: "done"}, %ExecutionEvidence{}} = Run.await(run, 5_000)
    end

    test "the whole-run timeout is a :timeout error with its evidence", context do
      config = fixture(context, emit(init()) <> "exec sleep 30\n", timeout: 300)
      {:ok, run} = Run.start(Query.new("hi"), config)

      assert {:error, %Error{kind: :timeout}, evidence} = Run.await(run, 10_000)
      assert evidence.reason == :timeout
      assert evidence.session_id == "native-session"
    end

    test "snapshot answers while the child is blocked", context do
      config = fixture(context, emit(init()) <> "exec sleep 30\n")
      {:ok, run} = Run.start(Query.new("hi"), config)
      ref = run.ref
      assert_receive {^ref, {:frame, %StreamEvent{type: "system"}}}, 5_000

      {micros, snapshot} = :timer.tc(fn -> Run.snapshot(run) end)
      assert %{status: :running, session_id: "native-session", frames: 1} = snapshot
      assert micros < 100_000

      assert {:error, %Error{kind: :cancelled}, _} = Run.cancel(run, 5_000)
    end
  end

  describe "cancel" do
    test "before any output: cancelled, child killed, idempotent", context do
      config = fixture(context, "echo $$ > #{context.pidfile}\nexec sleep 30\n")
      reference = make_ref()
      {:ok, run} = Run.start(Query.new("hi"), config, execution_observer: {self(), reference})
      await_file(context.pidfile)

      assert {:error, %Error{kind: :cancelled} = error, evidence} = Run.cancel(run, 5_000)
      assert evidence.reason == :cancelled
      assert evidence.outcome == {:error, error}
      assert evidence.cleanup == :unknown
      assert evidence.execution == :unknown
      assert evidence.stdout == ""
      assert_dead(context.pidfile)

      # Idempotent, and await sees the same outcome; exactly one record.
      assert Run.cancel(run) == {:error, error, evidence}
      assert Run.await(run) == {:error, error, evidence}
      assert_receive {^reference, ^evidence}
      refute_receive {^reference, _}, 50
      assert %{status: :cancelled} = Run.snapshot(run)
      ref = run.ref
      assert_receive {^ref, {:done, :cancelled}}
    end

    test "after output: cancelled with the observed output and session", context do
      script = emit(init()) <> "echo $$ > #{context.pidfile}\nexec sleep 30\n"
      config = fixture(context, script)
      {:ok, run} = Run.start(Query.new("hi"), config)
      ref = run.ref
      assert_receive {^ref, {:frame, %StreamEvent{type: "system"}}}, 5_000
      await_file(context.pidfile)

      assert {:error, %Error{kind: :cancelled}, evidence} = Run.cancel(run, 5_000)
      assert evidence.reason == :cancelled
      assert evidence.execution == :started
      assert evidence.session_id == "native-session"
      assert evidence.stdout =~ "native-session"
      assert evidence.cleanup == :unknown
      assert_dead(context.pidfile)
    end

    test "on a finished run returns its own outcome", context do
      config = fixture(context, emit(result()))
      {:ok, run} = Run.start(Query.new("hi"), config)
      assert {:ok, result, evidence} = Run.await(run, 5_000)
      assert Run.cancel(run) == {:ok, result, evidence}
      assert evidence.reason == nil
    end

    test "a runner that ignores cancel is stopped after the grace period" do
      reference = make_ref()
      config = Config.new(binary: "/bin/sh", runner: __MODULE__.IgnoresCancel, runner_options: [])

      {:ok, run} =
        Run.start(Query.new("hi"), config,
          cancel_grace_ms: 100,
          execution_observer: {self(), reference}
        )

      assert {:error, %Error{kind: :cancelled}, evidence} = Run.cancel(run, 5_000)
      assert evidence.reason == :cancelled
      assert evidence.cleanup == :unknown
      assert evidence.runner == __MODULE__.IgnoresCancel
      assert_receive {^reference, ^evidence}
      refute_receive {^reference, _}, 50
    end
  end

  describe "owner exit" do
    test "cancels the run and stops the run process", context do
      config = fixture(context, emit(init()) <> "echo $$ > #{context.pidfile}\nexec sleep 30\n")
      test = self()

      owner =
        spawn(fn ->
          {:ok, run} = Run.start(Query.new("hi"), config, events_to: test)
          send(test, {:run, run})

          receive do
            :exit -> :ok
          end
        end)

      assert_receive {:run, run}, 5_000
      await_file(context.pidfile)
      monitor = Process.monitor(run.pid)
      send(owner, :exit)

      assert_receive {:DOWN, ^monitor, :process, _, :normal}, 5_000
      assert_dead(context.pidfile)
      ref = run.ref
      assert_receive {^ref, {:done, :cancelled}}
      assert {:error, %Error{kind: :not_found}} = Run.await(run)
      assert {:error, %Error{kind: :not_found}} = Run.snapshot(run)
    end
  end

  describe "review fixes" do
    test "a worker killed after its runner returned publishes exactly one record" do
      # A blocking exec-stop telemetry handler holds the execution process
      # between the runner's return and its report to the run process; the
      # cancel grace then kills it there.
      test = self()
      handler = "run-test-block-#{System.unique_integer([:positive])}"

      :telemetry.attach(
        handler,
        [:claude_wrapper, :exec, :stop],
        fn _event, _measurements, _metadata, _config ->
          send(test, {:blocked, self()})
          Process.sleep(:infinity)
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      reference = make_ref()
      config = Config.new(binary: "/bin/sh", runner: __MODULE__.Finishes, runner_options: [])

      {:ok, run} =
        Run.start(Query.new("hi"), config,
          cancel_grace_ms: 50,
          execution_observer: {self(), reference}
        )

      assert_receive {:blocked, _worker}, 5_000
      assert {:error, %Error{kind: :cancelled}, evidence} = Run.cancel(run, 5_000)
      assert evidence.reason == :cancelled
      assert_receive {^reference, ^evidence}
      refute_receive {^reference, _}, 100
    end

    test "timed-out and exited waiters leave no state behind" do
      config = Config.new(binary: "/bin/sh", runner: __MODULE__.IgnoresCancel, runner_options: [])
      {:ok, run} = Run.start(Query.new("hi"), config, cancel_grace_ms: 50)

      for _ <- 1..5, do: assert(Run.await(run, 10) == :timeout)
      assert :sys.get_state(run.pid).waiters == %{}

      waiter = spawn(fn -> Run.await(run, :infinity) end)
      wait_until(fn -> map_size(:sys.get_state(run.pid).waiters) == 1 end)
      Process.exit(waiter, :kill)
      wait_until(fn -> :sys.get_state(run.pid).waiters == %{} end)

      assert {:error, %Error{kind: :cancelled}, _} = Run.cancel(run, 5_000)
    end

    test "a finite await is bounded while the run process is suspended" do
      config = Config.new(binary: "/bin/sh", runner: __MODULE__.IgnoresCancel, runner_options: [])
      {:ok, run} = Run.start(Query.new("hi"), config, cancel_grace_ms: 50)

      :sys.suspend(run.pid)
      {micros, reply} = :timer.tc(fn -> Run.await(run, 50) end)
      assert reply == :timeout
      assert micros < 1_000_000
      :sys.resume(run.pid)

      # The queued request is dropped by the caller's abandon message or the
      # deadline backstop, whichever the run process sees first.
      wait_until(fn -> :sys.get_state(run.pid).waiters == %{} end)
      assert {:error, %Error{kind: :cancelled}, _} = Run.cancel(run, 5_000)
    end

    test "cancel observes a complete final event written without a newline", context do
      json = Jason.encode!(init())

      script =
        "printf '%s' #{Command.shell_escape(json)}\necho $$ > #{context.pidfile}\nexec sleep 30\n"

      {:ok, run} = Run.start(Query.new("hi"), fixture(context, script))
      # The unterminated bytes produce no frame until the cancel; give them
      # time to reach the collector after the child records its pid.
      await_file(context.pidfile)
      Process.sleep(200)

      assert {:error, %Error{kind: :cancelled}, evidence} = Run.cancel(run, 5_000)
      assert evidence.stdout == json
      ref = run.ref
      assert_receive {^ref, {:frame, %StreamEvent{type: "system"}}}
      assert %{session_id: "native-session", frames: 1} = Run.snapshot(run)
    end

    test "session, rate-limit and evidence observers arrive in that order", context do
      config = fixture(context, emit(init()) <> emit(rate_limit()) <> emit(result()))
      reference = make_ref()
      observer = {self(), reference}

      {:ok, run} =
        Run.start(Query.new("hi"), config,
          session_observer: observer,
          rate_limit_observer: observer,
          execution_observer: observer,
          events_to: nil
        )

      assert {:ok, _result, evidence} = Run.await(run, 5_000)

      messages =
        for _ <- 1..3 do
          assert_receive {^reference, message}
          message
        end

      assert [
               %ClaudeWrapper.SessionObservation{session_id: "native-session"},
               %RateLimitObservation{status: "allowed"},
               ^evidence
             ] = messages

      refute_receive {^reference, _}, 50
      refute_received {_, {:frame, _}}
    end
  end

  describe "slow owner" do
    test "frames beyond the queue bound are dropped and counted", context do
      lines = Enum.map_join(1..5, "", fn n -> emit(%{"type" => "assistant", "n" => n}) end)
      config = fixture(context, lines <> emit(result()))

      sink =
        spawn(fn ->
          receive do
            :never -> :ok
          end
        end)

      {:ok, run} = Run.start(Query.new("hi"), config, events_to: sink, max_queued_frames: 2)
      assert {:ok, %Result{}, _} = Run.await(run, 5_000)

      assert %{frames: 6, frames_dropped: 4} = Run.snapshot(run)
      {:messages, messages} = Process.info(sink, :messages)
      ref = run.ref

      assert [
               {^ref, {:frame, %StreamEvent{data: %{"n" => 1}}}},
               {^ref, {:frame, %StreamEvent{data: %{"n" => 2}}}},
               {^ref, {:done, :succeeded}}
             ] = messages

      Process.exit(sink, :kill)
    end
  end

  describe "preflight" do
    test "rejections are returned before spawning, with one not-started record", context do
      calls = Path.join(context.directory, "calls")
      config = fixture(context, "echo called >> #{calls}\n" <> emit(result()))
      reference = make_ref()
      observer = {self(), reference}

      assert {:error, %Error{kind: :invalid_session_observer}} =
               Run.start(Query.new("hi"), config, execution_observer: observer, bogus: 1)

      assert_receive {^reference, %ExecutionEvidence{execution: :not_started}}

      assert {:error, %Error{kind: :invalid_rate_limit_observer}} =
               Run.start(Query.new("hi"), config,
                 execution_observer: observer,
                 rate_limit_observer: :nope
               )

      assert_receive {^reference, %ExecutionEvidence{execution: :not_started}}

      assert {:error, %Error{kind: :invalid_run_options, reason: {:events_to, :nope}}} =
               Run.start(Query.new("hi"), config, execution_observer: observer, events_to: :nope)

      assert_receive {^reference, %ExecutionEvidence{execution: :not_started}}

      assert {:error, %Error{kind: :invalid_run_options, reason: {:duplicate, :events_to}}} =
               Run.start(Query.new("hi"), config, events_to: nil, events_to: nil)

      assert {:error, %Error{kind: :invalid_execution_observer}} =
               Run.start(Query.new("hi"), config, execution_observer: :nope)

      bad_options = %{config | runner_options: [max_output_bytes: 0]}

      assert {:error, %Error{kind: :invalid_runner_options}} =
               Run.start(Query.new("hi"), bad_options, execution_observer: observer)

      assert_receive {^reference, %ExecutionEvidence{execution: :not_started}}

      port = %{config | runner: Runner.Port}

      assert {:error, %Error{kind: :evidence_unsupported}} =
               Run.start(Query.new("hi"), port, execution_observer: observer)

      assert_receive {^reference, %ExecutionEvidence{execution: :not_started}}
      refute_receive {^reference, _}, 50
      refute File.exists?(calls)
    end
  end

  defmodule IgnoresCancel do
    @moduledoc false
    def run(_binary, _args, _opts, _timeout), do: {:error, :unsupported}
    def stream_lines(_binary, _args, _opts, _timeout), do: []

    def run_evidenced(_binary, _args, _opts, _timeout, _observer) do
      Process.sleep(:infinity)
    end
  end

  defmodule Finishes do
    @moduledoc false
    def run(_binary, _args, _opts, _timeout), do: {:error, :unsupported}
    def stream_lines(_binary, _args, _opts, _timeout), do: []

    def run_evidenced(_binary, _args, _opts, _timeout, _observer) do
      line = ~s({"type":"result","subtype":"success","result":"done"})
      native = %{execution: :started, child_status: 0, cleanup: :confirmed, stdout: line}
      {{:ok, {line, 0, ""}}, native}
    end
  end

  # --- helpers ---

  defp wait_until(fun, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      fun.() ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        wait_until(fun, deadline)

      true ->
        flunk("condition not met")
    end
  end

  defp fixture(context, script, opts \\ []) do
    binary = Path.join(context.directory, "fake claude #{System.unique_integer([:positive])}")
    File.write!(binary, "#!/bin/sh\n" <> script)
    File.chmod!(binary, 0o755)

    [binary: binary, timeout: 10_000, runner: Runner.Forcola, runner_options: []]
    |> Keyword.merge(opts)
    |> Config.new()
  end

  defp init, do: %{"type" => "system", "subtype" => "init", "session_id" => "native-session"}

  defp rate_limit,
    do: %{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"status" => "allowed", "rateLimitType" => "five_hour"}
    }

  defp assistant, do: %{"type" => "assistant", "message" => %{"content" => []}}

  defp result,
    do: %{
      "type" => "result",
      "subtype" => "success",
      "result" => "done",
      "session_id" => "native-session"
    }

  defp emit(data), do: "printf '%s\\n' #{Command.shell_escape(Jason.encode!(data))}\n"

  defp await_file(path, deadline \\ System.monotonic_time(:millisecond) + 5_000) do
    cond do
      File.exists?(path) and String.trim(File.read!(path)) != "" ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_file(path, deadline)

      true ->
        flunk("#{path} was not written")
    end
  end

  defp assert_dead(pidfile) do
    pid = pidfile |> File.read!() |> String.trim()
    await_dead(pid, System.monotonic_time(:millisecond) + 5_000)
  end

  defp await_dead(pid, deadline) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} ->
        assert System.monotonic_time(:millisecond) < deadline, "process #{pid} survived cancel"
        Process.sleep(20)
        await_dead(pid, deadline)

      {_output, _code} ->
        :ok
    end
  end
end
