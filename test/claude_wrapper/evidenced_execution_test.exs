defmodule ClaudeWrapper.EvidencedExecutionTest do
  # Not async: tests poison and restore the :claude_wrapper application env to
  # prove per-config selection never reads (or writes) it when overridden.
  # Fake runners only; real-Forcola coverage is forcola_evidenced_test.exs.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{
    Command,
    Config,
    DuplexSession,
    Error,
    ExecutionEvidence,
    Query,
    RateLimitObservation,
    Result,
    Runner,
    SessionObservation,
    StreamEvent
  }

  @sink :claude_wrapper_evidenced_test_sink

  defmodule Sink do
    @moduledoc false
    def notify(message) do
      case Process.whereis(:claude_wrapper_evidenced_test_sink) do
        nil -> :ok
        pid -> send(pid, message)
      end
    end
  end

  defmodule ScriptRunner do
    @moduledoc false
    # Fake runner. run_evidenced/5 delegates to a `:script` closure carried in
    # the per-config runner options (a key only this fake accepts); the
    # legacy callbacks report to the test sink and return canned output.
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(binary, args, opts, timeout) do
      Sink.notify({:run, binary, args, opts, timeout})
      {:ok, {~s({"type":"result","subtype":"success","result":"legacy"}), 0}}
    end

    @impl true
    def run_observed(binary, args, opts, timeout, _observer) do
      Sink.notify({:run_observed, binary, args, opts, timeout})
      {:ok, {~s({"type":"result","subtype":"success","result":"observed"}\n), 0, ""}}
    end

    @impl true
    def run_evidenced(binary, args, opts, timeout, observer) do
      script = Keyword.fetch!(opts[:runner_options], :script)
      script.(%{binary: binary, args: args, opts: opts, timeout: timeout, observer: observer})
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      Sink.notify({:stream_lines, binary, args, opts, timeout})
      []
    end
  end

  defmodule LegacyOnlyRunner do
    @moduledoc false
    # Implements every callback except run_evidenced/5.
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_binary, _args, _opts, _timeout), do: invoked(:run)

    @impl true
    def run_observed(_binary, _args, _opts, _timeout, _observer), do: invoked(:run_observed)

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: invoked(:stream_lines)

    defp invoked(callback) do
      Sink.notify({:invoked, callback})
      raise "LegacyOnlyRunner.#{callback} must not be invoked"
    end
  end

  defmodule PoisonRunner do
    @moduledoc false
    @behaviour ClaudeWrapper.Runner

    @impl true
    def run(_, _, _, _), do: raise("poisoned application runner was used")

    @impl true
    def run_observed(_, _, _, _, _), do: raise("poisoned application runner was used")

    @impl true
    def run_evidenced(_, _, _, _, _), do: raise("poisoned application runner was used")

    @impl true
    def stream_lines(_, _, _, _), do: raise("poisoned application runner was used")
  end

  defmodule OpenRecordingAdapter do
    @moduledoc false
    # Duplex transport double that records open/1 and spawns nothing.
    @behaviour ClaudeWrapper.DuplexSession.Adapter

    @impl true
    def open(opts) do
      Sink.notify({:adapter_open, Keyword.fetch!(opts, :config)})
      {:ok, make_ref()}
    end

    @impl true
    def command(_handle, _iodata), do: :ok

    @impl true
    def close(_handle), do: :ok
  end

  defmodule EchoCommand do
    @moduledoc false
    defstruct []
    def args(%__MODULE__{}), do: ["--version"]
    def parse_output(stdout, _code), do: {:ok, stdout}
  end

  setup do
    previous = Application.get_all_env(:claude_wrapper)
    Process.register(self(), @sink)

    on_exit(fn ->
      for {key, _} <- Application.get_all_env(:claude_wrapper),
          do: Application.delete_env(:claude_wrapper, key)

      for {key, value} <- previous, do: Application.put_env(:claude_wrapper, key, value)
    end)

    %{reference: make_ref()}
  end

  describe "Config runner fields" do
    test "default to nil and validate their shape" do
      config = Config.new()
      assert config.runner == nil
      assert config.runner_options == nil

      assert %Config{runner: ScriptRunner, runner_options: []} =
               Config.new(runner: ScriptRunner, runner_options: [])

      assert_raise ArgumentError, ~r/runner must be a module/, fn -> Config.new(runner: "x") end
      assert_raise ArgumentError, ~r/runner must be a module/, fn -> Config.new(runner: true) end

      for bad <- [%{a: 1}, [1, 2], [a: 1, a: 2], :opts] do
        assert_raise ArgumentError, ~r/runner_options/, fn -> Config.new(runner_options: bad) end
      end
    end

    test "per-config values win and application defaults apply only when absent" do
      poison_application_defaults()

      assert Runner.impl(Config.new()) == PoisonRunner
      assert Runner.options(Config.new()) == [poisoned: true, env_mode: :replace]
      assert Runner.impl(Config.new(runner: ScriptRunner)) == ScriptRunner
      assert Runner.options(Config.new(runner_options: [])) == []

      explicit = [idle_timeout_ms: 5]
      assert Runner.options(Config.new(runner_options: explicit)) == explicit
    end

    test "Config.exec refuses runner options it cannot honor" do
      config = Config.new(binary: "/definitely/missing", runner_options: [env_mode: :replace])
      assert_raise ArgumentError, ~r/runner_options/, fn -> Config.exec(config, ["--version"]) end
    end
  end

  describe "isolation" do
    test "two simultaneous same-provider configs stay distinct with poisoned defaults" do
      poison_application_defaults()
      app_before = Application.get_all_env(:claude_wrapper)
      os_before = System.get_env()
      test = self()

      script = fn label ->
        fn call ->
          send(test, {:started, label, self(), call})

          receive do
            :release -> :ok
          end

          stdout = result_line() <> "\n"
          {{:ok, {stdout, 0, ""}}, clean(stdout)}
        end
      end

      tasks =
        for label <- [:a, :b] do
          opts = [
            binary: "/opt/#{label}/claude",
            working_dir: "/work/#{label}",
            env: [
              {"ANTHROPIC_BASE_URL", "https://#{label}.example.test"},
              {"ANTHROPIC_API_KEY", "key-#{label}"},
              {"CLAUDE_CONFIG_DIR", "/config/#{label}"}
            ],
            timeout: 5_000,
            runner: ScriptRunner,
            runner_options: [script: script.(label)],
            model: "model-#{label}",
            mcp_config: "/mcp/#{label}.json"
          ]

          Task.async(fn -> ClaudeWrapper.query("hi", opts) end)
        end

      calls =
        Map.new(1..2, fn _ ->
          assert_receive {:started, label, pid, call}, 2_000
          {label, {pid, call}}
        end)

      # Both executions are in flight at the same time before either returns.
      assert Enum.sort(Map.keys(calls)) == [:a, :b]
      for {_label, {pid, _call}} <- calls, do: send(pid, :release)
      assert [{:ok, %Result{}}, {:ok, %Result{}}] = Task.await_many(tasks)

      for label <- [:a, :b] do
        {_pid, call} = calls[label]
        env = call.opts[:env]
        assert call.binary == "/opt/#{label}/claude"
        assert call.opts[:cd] == "/work/#{label}"
        assert {"ANTHROPIC_BASE_URL", "https://#{label}.example.test"} in env
        assert {"ANTHROPIC_API_KEY", "key-#{label}"} in env
        assert {"CLAUDE_CONFIG_DIR", "/config/#{label}"} in env
        assert call.timeout == 5_000
        assert window(call.args, "--model") == ["--model", "model-#{label}"]
        assert window(call.args, "--mcp-config") == ["--mcp-config", "/mcp/#{label}.json"]
        assert Keyword.keys(call.opts[:runner_options]) == [:script]
        refute Enum.any?(call.args, &String.contains?(&1, "runner"))
      end

      assert Application.get_all_env(:claude_wrapper) == app_before
      assert System.get_env() == os_before
    end

    test "an explicit [] overrides poisoned default options and keeps the JSON path" do
      poison_application_defaults()
      config = Config.new(binary: "/fake/claude", runner: ScriptRunner, runner_options: [])

      assert {:ok, %Result{result: "legacy"}} = Query.execute(Query.new("hi"), config)
      assert_received {:run, "/fake/claude", args, _opts, _timeout}
      assert window(args, "--output-format") == ["--output-format", "json"]
    end

    test "default options with a runner lacking evidenced execution fail before invocation" do
      Application.put_env(:claude_wrapper, :runner_options, idle_timeout_ms: 100)
      config = Config.new(binary: "/fake/claude", runner: LegacyOnlyRunner)

      assert {:error, %Error{kind: :evidence_unsupported, reason: reason}} =
               Query.execute(Query.new("hi"), config)

      assert reason == %{runner: LegacyOnlyRunner, reason: :run_evidenced_not_implemented}
      refute_received {:invoked, _}
    end

    test "legacy observed execution uses the per-config runner when no evidence is requested",
         context do
      config = Config.new(binary: "/fake/claude", runner: ScriptRunner, runner_options: [])

      assert {:ok, %Result{result: "observed"}} =
               Query.execute(Query.new("hi"), config,
                 session_observer: {self(), context.reference}
               )

      assert_received {:run_observed, "/fake/claude", _args, _opts, _timeout}
    end
  end

  describe "terminal evidence" do
    test "exactly one record, after the native ID and before the final reply", context do
      reference = context.reference
      observer = {self(), reference}
      lines = [init(), rate_line(), init("later"), result_line()]

      script = fn call ->
        emit_lines(call.observer, lines)
        stdout = Enum.join(lines, "\n") <> "\n"
        {{:ok, {stdout, 0, ""}}, clean(stdout)}
      end

      config = script_config(script)
      test = self()

      spawn(fn ->
        reply =
          Query.execute(Query.new("hi"), config,
            session_observer: observer,
            rate_limit_observer: observer,
            execution_observer: observer
          )

        send(test, {reference, {:returned, reply}})
      end)

      # Messages are taken strictly in mailbox order.
      assert %SessionObservation{session_id: "native-session"} = next(reference)
      assert %RateLimitObservation{status: "allowed"} = next(reference)
      assert %ExecutionEvidence{} = evidence = next(reference)
      assert {:returned, {:ok, %Result{result: "done"}} = reply} = next(reference)
      refute_receive {^reference, _}, 50

      assert evidence.outcome == reply
      assert evidence.runner == ScriptRunner
      assert evidence.session_id == "native-session"
      assert %Result{result: "done"} = evidence.result
      assert evidence.cleanup == :confirmed
      assert evidence.scope == :process_group
      assert evidence.execution == :started
    end

    test "runner raises, throws and exits send one terminal fact after the early ID" do
      for {kind, reason, fail} <- failures() do
        reference = make_ref()
        observer = {self(), reference}
        parent = self()

        script = fn call ->
          emit_lines(call.observer, [init(), rate_line(), result_line()])
          fail.()
        end

        spawn(fn ->
          reply =
            Query.execute(Query.new("hi"), script_config(script),
              session_observer: observer,
              rate_limit_observer: observer,
              execution_observer: observer
            )

          send(parent, {reference, {:returned, reply}})
        end)

        assert %SessionObservation{session_id: "native-session"} = next(reference)
        assert %RateLimitObservation{} = next(reference)
        assert %ExecutionEvidence{} = evidence = next(reference)
        assert {:returned, {:error, %Error{kind: :io, reason: failure}} = reply} = next(reference)
        assert failure == {:runner_failed, kind, reason}
        assert evidence.outcome == reply
        assert evidence.session_id == "native-session"
        assert %Result{result: "done"} = evidence.result
        assert evidence.stdout == Enum.join([init(), rate_line(), result_line()], "\n") <> "\n"
        assert evidence.execution == :started
        assert evidence.child_status == nil
        assert evidence.cleanup == :unknown
        assert evidence.guard_close == :unknown
        refute_receive {^reference, _}, 10
      end

      # The same failure conversion applies to options-only execution.
      config = script_config(fn _ -> throw(:options_only) end)

      assert {:error, %Error{reason: {:runner_failed, :throw, :options_only}}} =
               Query.execute(Query.new("hi"), config)

      refute_received {_, %ExecutionEvidence{}}
    end

    test "failure before output has unknown execution and cleans private state", context do
      before = Process.get()
      config = script_config(fn _ -> exit(:early_failure) end)
      {reply, evidence} = execute_with_evidence(config, context)
      assert {:error, %Error{kind: :io, reason: {:runner_failed, :exit, :early_failure}}} = reply
      assert evidence.execution == :unknown
      assert evidence.session_id == nil
      assert evidence.stdout == ""
      assert evidence.child_status == nil
      assert evidence.cleanup == :unknown
      assert Process.get() == before
    end

    test "callback failure retains only a bounded prefix of observed stdout", context do
      script = fn call ->
        emit_lines(call.observer, [init(), String.duplicate("x", 1_048_576), result_line()])
        raise "after output"
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)
      assert {:error, %Error{kind: :io}} = reply
      assert byte_size(evidence.stdout) == 1_048_576
      assert String.starts_with?(evidence.stdout, init() <> "\n")
      assert evidence.output_truncated == true
      assert evidence.session_id == "native-session"
      assert evidence.result == nil
    end

    test "legacy callbacks preserve their exception behavior" do
      config = Config.new(binary: "/fake/claude", runner: PoisonRunner, runner_options: [])

      assert_raise RuntimeError, "poisoned application runner was used", fn ->
        Query.execute(Query.new("hi"), config)
      end
    end

    test "collector helper failures retain bounded frames, ID and terminal result", context do
      script = fn call ->
        run = fn {pid, ref} ->
          send(pid, {ref, {:stdout, init() <> "\n" <> result_line() <> "\ntrailing"}})
          send(pid, {ref, {:stderr, "diagnostic"}})
          exit(:native_failure)
        end

        run
        |> Runner.Collector.run(call.observer)
        |> Runner.ForcolaEvidence.translate()
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)
      assert {:error, %Error{kind: :io, reason: {:helper_down, :native_failure}}} = reply
      assert evidence.session_id == "native-session"
      assert %Result{result: "done"} = evidence.result
      assert String.ends_with?(evidence.stdout, "trailing")
      assert evidence.stderr == "diagnostic"
      assert evidence.cleanup == :unknown
      assert evidence.guard_close == :unknown
      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "collector observer failure sends one terminal record after the announced ID" do
      reference = make_ref()
      parent = self()
      observer = {parent, reference}
      stdout = init() <> "\n" <> result_line() <> "\n"

      script = fn call ->
        run = fn {pid, ref} ->
          send(pid, {ref, {:stdout, stdout}})
          {:ok, %{status: 0, stdout: stdout, stderr: "", evidence: clean(stdout)}}
        end

        failing_observer = fn line ->
          call.observer.(line)
          throw(:after_native_id)
        end

        run |> Runner.Collector.run(failing_observer) |> Runner.ForcolaEvidence.translate()
      end

      spawn(fn ->
        reply =
          Query.execute(Query.new("hi"), script_config(script),
            session_observer: observer,
            execution_observer: observer
          )

        send(parent, {reference, {:returned, reply}})
      end)

      assert %SessionObservation{session_id: "native-session"} = next(reference)
      assert %ExecutionEvidence{} = evidence = next(reference)

      assert {:returned,
              {:error, %Error{kind: :io, reason: {:observer_failed, :throw, :after_native_id}}} =
                reply} = next(reference)

      assert evidence.outcome == reply
      assert evidence.session_id == "native-session"
      assert %Result{result: "done"} = evidence.result
      assert evidence.cleanup == :confirmed
      assert evidence.child_status == 0
      refute_receive {^reference, _}, 10
    end

    test "an early result followed by a timeout keeps the result and ID but is not success",
         context do
      script = fn call ->
        emit_lines(call.observer, [init(), result_line()])
        stdout = init() <> "\n" <> result_line() <> "\n"
        native = clean(stdout, %{child_status: nil, child_signal: 15, reason: :timeout})
        {{:error, :timeout}, native}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:error, %Error{kind: :timeout, reason: 1_000}} = reply
      assert %Result{result: "done"} = evidence.result
      assert evidence.session_id == "native-session"
      assert evidence.reason == :timeout
      assert evidence.child_status == nil
      assert evidence.child_signal == 15
    end

    test "an early result followed by a nonzero exit records the raw child status", context do
      script = fn call ->
        emit_lines(call.observer, [init(), result_line()])
        stdout = init() <> "\n" <> result_line() <> "\n"
        {{:ok, {stdout, 3, "late failure"}}, clean(stdout, %{child_status: 3})}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      # Legacy tuple semantics: a non-rail terminal result with a nonzero exit
      # stays {:ok, result}; the evidence keeps the nonzero child status.
      assert {:ok, %Result{}} = reply
      assert evidence.child_status == 3
      assert evidence.stderr == ""
    end

    test "a non-string rail-stop result on a nonzero exit is typed and keeps native facts" do
      reference = make_ref()
      parent = self()
      observer = {parent, reference}

      line =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_turns",
          "result" => 42,
          "session_id" => "native-session"
        })

      stdout = init() <> "\n" <> line <> "\n"

      script = fn call ->
        emit_lines(call.observer, [init(), line])
        {{:ok, {stdout, 1, ""}}, clean(stdout, %{child_status: 1})}
      end

      spawn(fn ->
        reply =
          Query.execute(Query.new("hi"), script_config(script),
            session_observer: observer,
            execution_observer: observer
          )

        send(parent, {reference, {:returned, reply}})
      end)

      assert %SessionObservation{session_id: "native-session"} = next(reference)
      assert %ExecutionEvidence{} = evidence = next(reference)

      assert {:returned, {:error, %Error{} = error} = reply} = next(reference)
      refute_receive {^reference, _}, 10

      assert error.kind == :max_turns_exceeded
      assert error.exit_code == 1
      assert error.reason.cap == nil
      assert error.reason.session_id == "native-session"
      assert evidence.outcome == reply
      assert evidence.session_id == "native-session"
      assert %Result{result: 42} = evidence.result
      assert evidence.child_status == 1
      assert evidence.cleanup == :confirmed
      assert evidence.stdout == stdout
    end

    test "a reply conversion failure is typed and keeps the collected native facts", context do
      script = fn call ->
        emit_lines(call.observer, [init()])
        stdout = init() <> "\nnot a result\n"
        {{:ok, {stdout, 1, :not_a_binary}}, clean(stdout, %{child_status: 1})}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:error, %Error{kind: :io, reason: reason}} = reply
      assert {:reply_failed, :error, :function_clause} = reason
      assert evidence.session_id == "native-session"
      assert evidence.execution == :started
      assert evidence.child_status == 1
      assert evidence.cleanup == :confirmed
      assert evidence.scope == :process_group
      assert evidence.guard_close == :ok
      assert evidence.stdout == init() <> "\nnot a result\n"
    end

    test "zero child exit with unconfirmed cleanup is an error, not clean completion", context do
      script = fn call ->
        emit_lines(call.observer, [init(), result_line()])
        stdout = init() <> "\n" <> result_line() <> "\n"
        {{:error, {:signal, :unconfirmed}}, clean(stdout, %{cleanup: :unconfirmed})}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:error, %Error{kind: :io, reason: {:signal, :unconfirmed}}} = reply
      assert evidence.child_status == 0
      assert evidence.cleanup == :unconfirmed
      assert %Result{} = evidence.result
    end

    test "malformed or missing native facts are recorded as unknown", context do
      script = fn _call ->
        native = %{
          execution: :yes,
          child_status: -1,
          child_signal: "TERM",
          cleanup: :mostly,
          scope: "group",
          guard_close: :maybe,
          output_truncated: nil,
          reason: :surprise,
          stdout: 42
        }

        {{:ok, {result_line(), 0, ""}}, native}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:ok, %Result{}} = reply
      assert evidence.execution == :unknown
      assert evidence.child_status == nil
      assert evidence.child_signal == nil
      assert evidence.cleanup == :unknown
      assert evidence.scope == :unknown
      assert evidence.guard_close == :unknown
      assert evidence.output_truncated == :unknown
      assert evidence.reason == :unknown
      assert evidence.termination == :unknown
      assert evidence.stdout == ""
    end

    test "an invalid runner return is an io error with all-unknown evidence", context do
      {reply, evidence} = execute_with_evidence(script_config(fn _ -> :garbage end), context)

      assert {:error, %Error{kind: :io, reason: {:invalid_runner_return, :garbage}}} = reply
      assert evidence.cleanup == :unknown
      assert evidence.execution == :unknown
    end

    test "bounded failures map to typed errors with partial bytes in the evidence", context do
      cases = [
        {:idle_timeout, :timeout, :idle_timeout},
        {{:limit, :max_output_bytes}, :output_limit, :max_output_bytes},
        {{:limit, :observer_overflow}, :output_limit, :observer_overflow}
      ]

      for {outcome, kind, reason} <- cases do
        script = fn _call ->
          {{:error, outcome}, clean("partial", %{reason: reason, output_truncated: true})}
        end

        config = script_config(script, runner_options: [script: script, idle_timeout_ms: 25])

        {reply, evidence} = execute_with_evidence(config, context)
        assert {:error, %Error{kind: ^kind}} = reply
        assert evidence.stdout == "partial"
        assert evidence.reason == reason
        assert evidence.output_truncated == true
      end
    end

    test "runner-side option rejection is typed and records no execution", context do
      script = fn _call ->
        {{:error, {:invalid_runner_options, {:unknown, :bogus}}}, Runner.not_started_evidence()}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:error, %Error{kind: :invalid_runner_options, reason: {:unknown, :bogus}}} = reply
      assert evidence.execution == :not_started
      assert evidence.child_status == nil
      assert evidence.cleanup == :not_applicable
    end

    test "helper death keeps the announced ID and stays unknown", context do
      script = fn call ->
        emit_lines(call.observer, [init()])
        native = %{execution: :unknown, cleanup: :unknown, scope: :unknown}
        {{:error, {:helper_down, :killed}}, native}
      end

      {reply, evidence} = execute_with_evidence(script_config(script), context)

      assert {:error, %Error{kind: :io, reason: {:helper_down, :killed}}} = reply
      assert evidence.session_id == "native-session"
      assert evidence.cleanup == :unknown
      assert evidence.guard_close == :unknown
      assert evidence.result == nil
    end

    test "no private messages linger in the execution caller", context do
      script = fn call ->
        emit_lines(call.observer, [init(), init("other"), result_line()])
        {{:ok, {result_line(), 0, ""}}, clean(result_line())}
      end

      sink = spawn(fn -> Process.sleep(:infinity) end)
      on_exit(fn -> Process.exit(sink, :kill) end)

      assert {:ok, %Result{}} =
               Query.execute(Query.new("hi"), script_config(script),
                 session_observer: {sink, context.reference},
                 execution_observer: {sink, context.reference}
               )

      assert {:messages, []} = Process.info(self(), :messages)
      assert {:message_queue_len, 2} = Process.info(sink, :message_queue_len)
    end
  end

  describe "preflight rejection" do
    test "an unsupported runner is rejected before invocation with not-started evidence",
         context do
      config = Config.new(binary: "/fake/claude", runner: LegacyOnlyRunner, runner_options: [])

      {reply, evidence} = execute_with_evidence(config, context)

      assert {:error, %Error{kind: :evidence_unsupported}} = reply
      refute_received {:invoked, _}
      assert evidence.execution == :not_started
      assert evidence.termination == :not_started
      assert evidence.child_status == nil
      assert evidence.child_signal == nil
      assert evidence.cleanup == :not_applicable
      assert evidence.guard_close == :not_applicable
    end

    test "an invalid execution observer is rejected and nothing is sent" do
      config = script_config(fn _ -> flunk("must not run") end)

      for value <- [self(), {self(), :not_reference}, {"pid", make_ref()}] do
        assert {:error, %Error{kind: :invalid_execution_observer}} =
                 Query.execute(Query.new("hi"), config, execution_observer: value)
      end

      # Ambiguous: two otherwise valid pairs.
      observer = {self(), make_ref()}

      assert {:error, %Error{kind: :invalid_execution_observer}} =
               Query.execute(Query.new("hi"), config,
                 execution_observer: observer,
                 execution_observer: observer
               )

      # Not a keyword list, so no observer is trusted.
      assert {:error, %Error{kind: :invalid_session_observer}} =
               Query.execute(Query.new("hi"), config, [{:execution_observer, observer}, :junk])

      assert {:messages, []} = Process.info(self(), :messages)
    end

    test "unknown or duplicate options with a valid observer deliver one not-started record",
         context do
      script = fn _call ->
        Sink.notify({:invoked, :run_evidenced})
        {{:error, :unexpected}, Runner.not_started_evidence()}
      end

      config = script_config(script)
      reference = context.reference
      observer = {self(), reference}

      unknown = [unexpected: true]
      duplicate = [session_observer: observer, session_observer: observer]

      for rest <- [unknown, duplicate] do
        reply = Query.execute(Query.new("hi"), config, [{:execution_observer, observer} | rest])
        assert {:error, %Error{kind: :invalid_session_observer}} = reply

        assert_received {^reference, %ExecutionEvidence{} = evidence}
        refute_received {^reference, _}
        assert evidence.outcome == reply
        assert evidence.runner == ScriptRunner
        assert evidence.execution == :not_started
        assert evidence.termination == :not_started
        assert evidence.child_status == nil
        assert evidence.cleanup == :not_applicable
        assert evidence.session_id == nil
        assert evidence.result == nil
      end

      refute_received {:invoked, _}
    end

    test "other invalid observers still deliver one not-started record", context do
      config = script_config(fn _ -> flunk("must not run") end)
      reference = context.reference

      assert {:error, %Error{kind: :invalid_session_observer}} =
               Query.execute(Query.new("hi"), config,
                 session_observer: :bad,
                 execution_observer: {self(), reference}
               )

      assert_received {^reference, %ExecutionEvidence{execution: :not_started} = evidence}
      assert {:error, %Error{kind: :invalid_session_observer}} = evidence.outcome
      refute_received {^reference, _}
    end
  end

  describe "paths that cannot honor runner options" do
    test "stream yields one terminal error event and spawns nothing" do
      config = Config.new(binary: "/fake/claude", runner: ScriptRunner, runner_options: [a: 1])
      events = Enum.to_list(Query.stream(Query.new("hi"), config))

      assert [%StreamEvent{type: "error", data: %{"error" => "runner_options_unsupported"}}] =
               events

      refute_received {:stream_lines, _, _, _, _}
    end

    test "stream with an execution observer is rejected", context do
      opts = [
        binary: "/fake/claude",
        runner: ScriptRunner,
        execution_observer: {self(), context.reference}
      ]

      events = Enum.to_list(ClaudeWrapper.stream("hi", opts))

      assert [%StreamEvent{type: "error", data: %{"error" => "execution_observer_unsupported"}}] =
               events

      refute_received {:stream_lines, _, _, _, _}
    end

    test "stream without options uses the per-config runner" do
      poison_application_defaults()
      config = Config.new(binary: "/fake/claude", runner: ScriptRunner, runner_options: [])
      events = Enum.to_list(Query.stream(Query.new("hi"), config))
      assert [%StreamEvent{data: %{"error" => "stream_truncated"}}] = events
      assert_received {:stream_lines, "/fake/claude", _args, _opts, _timeout}
    end

    test "Command.run and raw/2 reject runner options before spawning" do
      opts = [binary: "/fake/claude", runner: ScriptRunner, runner_options: [a: 1]]
      config = Config.new(opts)

      assert {:error, %Error{kind: :invalid_runner_options, reason: {:unsupported_mode, mode}}} =
               Command.run(EchoCommand, %EchoCommand{}, config)

      assert mode == :command

      assert {:error, %Error{kind: :invalid_runner_options, reason: {:unsupported_mode, :raw}}} =
               ClaudeWrapper.raw(["--version"], opts)

      refute_received {:run, _, _, _, _}
    end

    test "DuplexSession rejects resolved runner options before opening an adapter" do
      strict = [env_mode: :replace, idle_timeout_ms: 1]
      per_config = Config.new(binary: "/never/spawn", runner_options: strict)

      Application.put_env(:claude_wrapper, :runner_options, strict)
      app_default = Config.new(binary: "/never/spawn")

      mode = {:unsupported_mode, :duplex}

      for config <- [per_config, app_default] do
        opts = [config: config, adapter: OpenRecordingAdapter]

        assert {:error, %Error{kind: :invalid_runner_options, reason: ^mode}} =
                 DuplexSession.start_link(opts)

        # init/1 enforces the same rule for starts that bypass start_link/1.
        assert {:error, %Error{kind: :invalid_runner_options, reason: ^mode}} =
                 GenServer.start(DuplexSession, opts)
      end

      refute_received {:adapter_open, _}

      # An explicit [] overrides the application default and opens normally.
      explicit = Config.new(binary: "/never/spawn", runner_options: [])

      assert {:ok, pid} =
               DuplexSession.start_link(config: explicit, adapter: OpenRecordingAdapter)

      assert_received {:adapter_open, ^explicit}
      :ok = GenServer.stop(pid)
    end

    test "Command.run and raw/2 use the per-config runner" do
      poison_application_defaults()
      opts = [binary: "/fake/claude", runner: ScriptRunner, runner_options: []]

      assert {:ok, _output} = Command.run(EchoCommand, %EchoCommand{}, Config.new(opts))
      assert_received {:run, "/fake/claude", ["--version"], _opts, _timeout}

      assert {:ok, _output} = ClaudeWrapper.raw(["config", "list"], opts)
      assert_received {:run, "/fake/claude", ["config", "list"], _opts, _timeout}
    end
  end

  defp failures do
    [
      {:error, %ArgumentError{message: "runner failed"},
       fn -> raise ArgumentError, "runner failed" end},
      {:throw, :runner_threw, fn -> throw(:runner_threw) end},
      {:exit, :runner_exited, fn -> exit(:runner_exited) end}
    ]
  end

  defp poison_application_defaults do
    Application.put_env(:claude_wrapper, :runner, PoisonRunner)
    Application.put_env(:claude_wrapper, :runner_options, poisoned: true, env_mode: :replace)
  end

  defp script_config(script, overrides \\ []) do
    [binary: "/fake/claude", timeout: 1_000, runner: ScriptRunner]
    |> Keyword.put(:runner_options, script: script)
    |> Keyword.merge(overrides)
    |> Config.new()
  end

  defp clean(stdout, overrides \\ %{}) do
    Map.merge(
      %{
        execution: :started,
        child_status: 0,
        child_signal: nil,
        termination: :exit,
        reason: nil,
        output_truncated: false,
        cleanup: :confirmed,
        scope: :process_group,
        guard_close: :ok,
        stdout: stdout,
        stderr: "",
        lines_dropped: 0
      },
      overrides
    )
  end

  # Drive the trusted observer the way a runner does, honoring replacement.
  defp emit_lines(observer, lines) do
    Enum.reduce(lines, observer, fn
      _line, nil ->
        nil

      line, current ->
        case current.(line) do
          {:continue, next} -> next
          :continue -> current
          :observed -> nil
        end
    end)
  end

  defp execute_with_evidence(config, context) do
    reference = context.reference
    reply = Query.execute(Query.new("hi"), config, execution_observer: {self(), reference})
    assert_received {^reference, %ExecutionEvidence{} = evidence}
    refute_received {^reference, %ExecutionEvidence{}}
    assert evidence.outcome == reply
    {reply, evidence}
  end

  defp next(reference) do
    receive do
      {^reference, message} -> message
    after
      1_000 -> flunk("no message for the reference")
    end
  end

  defp window(args, flag) do
    case Enum.drop_while(args, &(&1 != flag)) do
      [^flag, value | _] -> [flag, value]
      _ -> nil
    end
  end

  defp init(id \\ "native-session"),
    do: Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => id})

  defp result_line do
    Jason.encode!(%{
      "type" => "result",
      "subtype" => "success",
      "result" => "done",
      "session_id" => "native-session"
    })
  end

  defp rate_line do
    Jason.encode!(%{
      "type" => "rate_limit_event",
      "rate_limit_info" => %{"status" => "allowed", "rateLimitType" => "five_hour"}
    })
  end
end
