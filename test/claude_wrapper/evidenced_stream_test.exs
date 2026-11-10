defmodule ClaudeWrapper.EvidencedStreamTest do
  @moduledoc "Query.stream/3 with an execution observer and runner options (#314)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Error, ExecutionEvidence, Query, StreamEvent}

  defmodule ScriptRunner do
    @moduledoc false
    # run_evidenced/5 runs the `:script` closure carried in the runner
    # options, so each test scripts its own run without shared state.
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("run/4 must not be called")

    @impl true
    def run_evidenced(binary, args, opts, timeout, observer) do
      script = Keyword.fetch!(opts[:runner_options], :script)
      script.(%{binary: binary, args: args, opts: opts, timeout: timeout, observer: observer})
    end

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout),
      do: raise("stream_lines/4 must not be called")
  end

  defmodule LegacyRunner do
    @moduledoc false
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: raise("must not be called")

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: raise("must not be called")
  end

  @init ~s({"type":"system","subtype":"init","session_id":"s-1"})
  @assistant ~s({"type":"assistant","message":{"content":[{"type":"text","text":"hi"}]},"session_id":"s-1"})
  @result ~s({"type":"result","subtype":"success","is_error":false,"result":"hi","session_id":"s-1"})

  @exited %{
    execution: :started,
    child_status: 0,
    termination: :exit,
    output_truncated: false,
    cleanup: :confirmed,
    scope: :process_group,
    guard_close: :ok
  }

  # Feed each line to the line observer, as a runner does, and return stdout.
  defp emit(observer, lines) do
    _last =
      Enum.reduce(lines, observer, fn line, observer ->
        case observer.(line) do
          {:continue, next} -> next
          _ -> observer
        end
      end)

    Enum.map_join(lines, "", &(&1 <> "\n"))
  end

  defp config(script, opts \\ []) do
    {runner_options, opts} = Keyword.pop(opts, :runner_options, [])

    Config.new(
      [
        binary: "/fake/claude",
        runner: ScriptRunner,
        runner_options: [script: script] ++ runner_options
      ] ++
        opts
    )
  end

  defp stream(config, ref),
    do: Query.stream(Query.new("hi"), config, execution_observer: {self(), ref})

  defp await_evidence(ref) do
    assert_receive {^ref, %ExecutionEvidence{} = evidence}, 5_000
    refute_receive {^ref, %ExecutionEvidence{}}, 100
    evidence
  end

  test "a clean run yields its frames and sends one evidence record" do
    ref = make_ref()

    script = fn %{observer: observer} ->
      stdout = emit(observer, [@init, @assistant, @result])
      {{:ok, {stdout, 0, ""}}, Map.merge(@exited, %{stdout: stdout})}
    end

    events = config(script) |> stream(ref) |> Enum.to_list()

    assert [
             %StreamEvent{type: "system"},
             %StreamEvent{type: "assistant"},
             %StreamEvent{type: "result"}
           ] = events

    evidence = await_evidence(ref)
    assert {:ok, %ClaudeWrapper.Result{result: "hi"}} = evidence.outcome
    assert evidence.cleanup == :confirmed
    assert evidence.session_id == "s-1"
  end

  test "runner options alone make the stream evidenced" do
    test = self()

    script = fn %{observer: observer, opts: opts} ->
      send(test, {:options, opts[:runner_options]})
      stdout = emit(observer, [@init, @result])
      {{:ok, {stdout, 0, ""}}, Map.merge(@exited, %{stdout: stdout})}
    end

    events =
      script
      |> config(runner_options: [kill_grace_ms: 100])
      |> then(&Query.stream(Query.new("hi"), &1))
      |> Enum.to_list()

    assert [%StreamEvent{type: "system"}, %StreamEvent{type: "result"}] = events
    assert_received {:options, options}
    assert options[:kill_grace_ms] == 100
  end

  test "Config idle_timeout_ms becomes the runner option unless one is set" do
    test = self()

    script = fn %{observer: observer, opts: opts} ->
      send(test, {:idle, opts[:runner_options][:idle_timeout_ms]})
      stdout = emit(observer, [@result])
      {{:ok, {stdout, 0, ""}}, Map.merge(@exited, %{stdout: stdout})}
    end

    script |> config(idle_timeout_ms: 750) |> stream(make_ref()) |> Enum.to_list()
    assert_received {:idle, 750}

    script
    |> config(idle_timeout_ms: 750, runner_options: [idle_timeout_ms: 50])
    |> stream(make_ref())
    |> Enum.to_list()

    assert_received {:idle, 50}
  end

  test "a timeout ends with stream_truncated and the timeout in evidence" do
    ref = make_ref()

    script = fn %{observer: observer} ->
      stdout = emit(observer, [@init])
      {{:error, :timeout}, Map.merge(@exited, %{reason: :timeout, stdout: stdout})}
    end

    events = script |> config(timeout: 1_000) |> stream(ref) |> Enum.to_list()

    assert [
             %StreamEvent{type: "system"},
             %StreamEvent{
               type: "error",
               data: %{"error" => "stream_truncated", "kind" => "timeout"}
             }
           ] = events

    evidence = await_evidence(ref)
    assert evidence.reason == :timeout
    assert {:error, %Error{kind: :timeout}} = evidence.outcome
  end

  test "a nonzero exit without a result ends with stream_truncated" do
    ref = make_ref()

    script = fn %{observer: observer} ->
      stdout = emit(observer, [@init])
      {{:ok, {stdout, 1, "boom"}}, Map.merge(@exited, %{child_status: 1, stdout: stdout})}
    end

    events = script |> config() |> stream(ref) |> Enum.to_list()

    assert [%StreamEvent{type: "system"}, %StreamEvent{data: %{"error" => "stream_truncated"}}] =
             events

    assert {:error, %Error{}} = await_evidence(ref).outcome
  end

  test "a spawn failure ends with stream_truncated and one record" do
    ref = make_ref()

    script = fn _run ->
      {{:error, {:spawn, :enoent}},
       %{ClaudeWrapper.Runner.not_started_evidence() | termination: {:spawn, :enoent}}}
    end

    events = script |> config() |> stream(ref) |> Enum.to_list()

    assert [%StreamEvent{type: "error", data: %{"error" => "stream_truncated"}}] = events
    assert await_evidence(ref).execution == :not_started
  end

  # Emits one line, then waits for Run's cancel request as a runner must.
  defp blocking_script(test) do
    fn %{observer: observer, opts: opts} ->
      stdout = emit(observer, [@init])
      cancel = opts[:cancel]
      send(test, :emitted)

      receive do
        {^cancel, :cancel} ->
          {{:error, :cancelled}, %{execution: :started, reason: :cancelled, stdout: stdout}}
      after
        5_000 -> {{:error, :timeout}, %{execution: :started, reason: :timeout, stdout: stdout}}
      end
    end
  end

  test "an early halt cancels the run and records the cancellation" do
    ref = make_ref()

    assert [%StreamEvent{type: "system"}] =
             self() |> blocking_script() |> config() |> stream(ref) |> Enum.take(1)

    evidence = await_evidence(ref)
    assert evidence.reason == :cancelled
    assert {:error, %Error{kind: :cancelled}} = evidence.outcome
  end

  test "a raise in the consumer cancels the run and records the cancellation" do
    ref = make_ref()
    stream = self() |> blocking_script() |> config() |> stream(ref)

    assert_raise RuntimeError, "consumer failed", fn ->
      Enum.each(stream, fn _event -> raise "consumer failed" end)
    end

    assert await_evidence(ref).reason == :cancelled
  end

  test "dropped lines are reported before the end of the stream" do
    ref = make_ref()

    script = fn %{observer: observer} ->
      stdout = emit(observer, [@init, @result])
      {{:ok, {stdout, 0, ""}}, Map.merge(@exited, %{stdout: stdout, lines_dropped: 2})}
    end

    events = script |> config() |> stream(ref) |> Enum.to_list()

    assert [
             %StreamEvent{type: "system"},
             %StreamEvent{type: "result"},
             %StreamEvent{type: "error", data: %{"error" => "lines_dropped", "count" => 2}}
           ] = events

    await_evidence(ref)
  end

  describe "preflight" do
    test "a runner without run_evidenced/5 is rejected before spawning" do
      ref = make_ref()
      config = Config.new(binary: "/fake/claude", runner: LegacyRunner)

      events = Query.stream(Query.new("hi"), config, execution_observer: {self(), ref})

      assert [%StreamEvent{type: "error", data: %{"error" => "evidence_unsupported"}}] =
               Enum.to_list(events)

      assert await_evidence(ref).execution == :not_started
    end

    test "runner options on a runner without run_evidenced/5 are rejected" do
      config = Config.new(binary: "/fake/claude", runner: LegacyRunner, runner_options: [a: 1])

      assert [%StreamEvent{type: "error", data: %{"error" => "evidence_unsupported"}}] =
               Query.new("hi") |> Query.stream(config) |> Enum.to_list()
    end

    test "an invalid execution observer is rejected" do
      config = config(fn _ -> raise "must not run" end)

      assert [%StreamEvent{type: "error", data: %{"error" => "invalid_execution_observer"}}] =
               Query.new("hi")
               |> Query.stream(config, execution_observer: :nope)
               |> Enum.to_list()
    end

    test "ClaudeWrapper.stream/2 passes the execution observer through" do
      ref = make_ref()

      script = fn %{observer: observer} ->
        stdout = emit(observer, [@init, @result])
        {{:ok, {stdout, 0, ""}}, Map.merge(@exited, %{stdout: stdout})}
      end

      events =
        ClaudeWrapper.stream("hi",
          binary: "/fake/claude",
          runner: ScriptRunner,
          runner_options: [script: script],
          execution_observer: {self(), ref}
        )
        |> Enum.to_list()

      assert [%StreamEvent{type: "system"}, %StreamEvent{type: "result"}] = events
      await_evidence(ref)
    end
  end

  describe "Runner.Forcola" do
    @describetag :forcola
    @describetag :tmp_dir

    defp forcola_config(dir, body) do
      path = Path.join(dir, "fake_claude")
      File.write!(path, "#!/bin/sh\n" <> body)
      File.chmod!(path, 0o755)
      Config.new(binary: path, runner: ClaudeWrapper.Runner.Forcola, timeout: 10_000)
    end

    test "a clean run yields frames and confirmed cleanup", %{tmp_dir: dir} do
      ref = make_ref()
      config = forcola_config(dir, "echo '#{@init}'\necho '#{@result}'\n")

      assert [%StreamEvent{type: "system"}, %StreamEvent{type: "result"}] =
               config |> stream(ref) |> Enum.to_list()

      evidence = await_evidence(ref)
      assert evidence.execution == :started
      assert evidence.cleanup == :confirmed
      assert {:ok, %ClaudeWrapper.Result{}} = evidence.outcome
    end

    test "an early halt stops the CLI and records the cancellation", %{tmp_dir: dir} do
      ref = make_ref()
      marker = Path.join(dir, "finished")
      config = forcola_config(dir, "echo '#{@init}'\nsleep 1\ntouch '#{marker}'\n")

      assert [%StreamEvent{type: "system"}] = config |> stream(ref) |> Enum.take(1)
      assert await_evidence(ref).reason == :cancelled

      # Past the fake's own 1 s sleep: the group was stopped before it.
      Process.sleep(1_500)
      refute File.exists?(marker)
    end
  end
end
