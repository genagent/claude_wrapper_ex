defmodule ClaudeWrapper.Runner.ForcolaEvidenceTest do
  # Fake-only coverage of the Forcola evidenced option mapping and outcome
  # translation. It needs no Forcola release; real-Forcola coverage lives in
  # test/claude_wrapper/forcola_evidenced_test.exs (tag :forcola_evidence).
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Runner
  alias ClaudeWrapper.Runner.ForcolaEvidence

  defmodule WithEvidence do
    @moduledoc false
    defstruct [:status, stdout: "", stderr: "", evidence: nil]
  end

  defmodule WithoutEvidence do
    @moduledoc false
    defstruct [:status, stdout: "", stderr: ""]
  end

  describe "build/2" do
    test "applies the default output bound and keeps stderr separate" do
      assert {:ok, opts, 1_048_576} = ForcolaEvidence.build([runner_options: []], 1_000)
      assert opts[:timeout_ms] == 1_000
      assert opts[:max_output_bytes] == 67_108_864
      assert opts[:merge_stderr] == false
      refute Keyword.has_key?(opts, :output_observer)
    end

    test "a nil timeout keeps the finite 24-hour bound" do
      assert {:ok, opts, _} = ForcolaEvidence.build([], nil)
      assert opts[:timeout_ms] == 86_400_000
    end

    test "forwards cd, env and every reviewed Forcola option by name" do
      options = [
        shim_path: "/opt/forcola/shim",
        env_mode: :replace,
        idle_timeout_ms: 250,
        max_output_bytes: 4_096,
        interrupt_signal: :int,
        interrupt_grace_ms: 100,
        kill_grace_ms: 0,
        max_line_bytes: 512
      ]

      opts = [cd: "/work/a", env: [{"ANTHROPIC_BASE_URL", "http://a"}], runner_options: options]
      assert {:ok, forcola, 512} = ForcolaEvidence.build(opts, 5_000)

      for {key, value} <- Keyword.delete(options, :max_line_bytes) do
        assert forcola[key] == value, "#{key} was not forwarded"
      end

      assert forcola[:cd] == "/work/a"
      assert forcola[:env] == [{"ANTHROPIC_BASE_URL", "http://a"}]
      refute Keyword.has_key?(forcola, :max_line_bytes)
    end

    test "rejects unknown and invalid options before anything runs" do
      for {options, reason} <- [
            {[unknown: 1], {:unknown, :unknown}},
            {[poisoned: true], {:unknown, :poisoned}},
            {[max_output_bytes: 0], {:max_output_bytes, 0}},
            {[idle_timeout_ms: -1], {:idle_timeout_ms, -1}},
            {[idle_timeout_ms: 4_294_967_296], {:idle_timeout_ms, 4_294_967_296}},
            {[max_line_bytes: :big], {:max_line_bytes, :big}},
            {[env_mode: :merge], {:env_mode, :merge}},
            {[shim_path: "relative/shim"], {:shim_path, "relative/shim"}},
            {[interrupt_signal: :term, interrupt_grace_ms: 10], {:interrupt_signal, :term}},
            {[interrupt_signal: :int], {:interrupt_signal, :requires_interrupt_grace_ms}},
            {[interrupt_grace_ms: 10], {:interrupt_signal, :requires_interrupt_grace_ms}},
            {[kill_grace_ms: -5], {:kill_grace_ms, -5}}
          ] do
        assert {:error, {:invalid_runner_options, ^reason}} =
                 ForcolaEvidence.build([runner_options: options], 1_000)
      end
    end

    test "rejects malformed option lists, timeouts and env entries" do
      duplicate = [a: 1, a: 2]
      expected = {:runner_options, duplicate}

      assert {:error, {:invalid_runner_options, ^expected}} =
               ForcolaEvidence.build([runner_options: duplicate], 1_000)

      assert {:error, {:invalid_runner_options, {:timeout, 0}}} = ForcolaEvidence.build([], 0)

      for entry <- [{"", "x"}, {"A=B", "x"}, {"A", "x" <> <<0>>}, {~c"A", ~c"x"}, {"A", false}] do
        assert {:error, {:invalid_runner_options, {:env, ^entry}}} =
                 ForcolaEvidence.build([env: [entry]], 1_000)
      end
    end
  end

  describe "supported?/1" do
    test "requires an :evidence field on the result struct" do
      assert ForcolaEvidence.supported?(WithEvidence)
      refute ForcolaEvidence.supported?(WithoutEvidence)
      refute ForcolaEvidence.supported?(NoSuchModule.Anywhere)
    end
  end

  describe "translate/1" do
    test "a clean exit keeps every native fact separately" do
      assert {{:ok, {"out\n", 0, ""}}, evidence} = translate({:ok, result(0, native([]))}, 1)
      assert evidence.execution == :started
      assert evidence.child_status == 0
      assert evidence.cleanup == :confirmed
      assert evidence.scope == :process_group
      assert evidence.guard_close == :ok
      assert evidence.lines_dropped == 1
    end

    test "exit 0 with unconfirmed cleanup is a signal error, child status retained" do
      outcome = {:ok, result({:signal, :unconfirmed}, native(cleanup: :unconfirmed))}
      assert {{:error, {:signal, :unconfirmed}}, evidence} = translate(outcome)
      assert evidence.child_status == 0
      assert evidence.cleanup == :unconfirmed
    end

    test "early result followed by a timeout keeps partial bytes and the bound" do
      stdout = ~s({"type":"result","result":"done"}\n)
      ev = native(child_status: nil, child_signal: 15, reason: :timeout)
      outcome = {:error, {:timeout, result({:signal, 15}, ev, stdout)}}

      assert {{:error, :timeout}, evidence} = translate(outcome)
      assert evidence.stdout == stdout
      assert evidence.reason == :timeout
      assert evidence.child_signal == 15
    end

    test "idle, output and observer bounds map to distinct errors" do
      for {reason, expected} <- [
            {:idle_timeout, :idle_timeout},
            {:max_output_bytes, {:limit, :max_output_bytes}},
            {:observer_overflow, {:limit, :observer_overflow}}
          ] do
        ev = native(reason: reason, output_truncated: true)
        outcome = {:error, {reason, result({:signal, 15}, ev, "partial")}}

        assert {{:error, ^expected}, evidence} = translate(outcome)
        assert evidence.stdout == "partial"
        assert evidence.output_truncated == true
      end
    end

    test "spawn failures after SPAWN keep partial evidence; bare spawn errors did not start" do
      ev = native(termination: {:spawn, "exec failed"}, child_status: nil, cleanup: :unknown)
      outcome = {:error, {:spawn, {:invalid_exit, result({:signal, :unconfirmed}, ev)}}}

      assert {{:error, {:spawn, :invalid_exit}}, evidence} = translate(outcome)
      assert evidence.execution == :started
      assert evidence.cleanup == :unknown

      assert {{:error, {:spawn, :incompatible_shim}}, not_started} =
               translate({:error, {:spawn, :incompatible_shim}})

      assert not_started.execution == :not_started
      assert not_started.child_status == nil
      assert not_started.cleanup == :not_applicable
      assert not_started.termination == {:spawn, :incompatible_shim}
    end

    test "missing evidence and helper death stay unknown, never confirmed" do
      assert {{:ok, {"", 0, ""}}, evidence} = translate({:ok, %WithoutEvidence{status: 0}})
      assert evidence.cleanup == :unknown
      assert evidence.scope == :unknown
      assert evidence.guard_close == :unknown
      assert evidence.execution == :unknown
      assert evidence.child_status == nil

      assert {{:error, {:helper_down, :killed}}, down} =
               ForcolaEvidence.translate({:helper_down, :killed, %{lines_dropped: 2}})

      assert down.cleanup == :unknown
      assert down.execution == :unknown
      assert down.lines_dropped == 2
    end

    test "observer failure preserves completed native evidence and overrides success" do
      stats = %{lines_dropped: 0, observer_error: {:throw, :observer_failed}}

      assert {{:error, {:observer_failed, :throw, :observer_failed}}, evidence} =
               ForcolaEvidence.translate({:done, {:ok, result(0, native([]))}, stats})

      assert evidence.child_status == 0
      assert evidence.cleanup == :confirmed
      assert evidence.guard_close == :ok
      assert evidence.stdout == "out\n"
    end

    test "observer failure followed by helper death preserves partial facts with unknown cleanup" do
      stats = %{
        lines_dropped: 1,
        observer_error: {:exit, :observer_failed},
        stdout: "partial",
        stderr: "diagnostic",
        output_truncated: true
      }

      assert {{:error, {:observer_failed, :exit, :observer_failed}}, evidence} =
               ForcolaEvidence.translate({:helper_down, :killed, stats})

      assert evidence.stdout == "partial"
      assert evidence.stderr == "diagnostic"
      assert evidence.execution == :started
      assert evidence.cleanup == :unknown
      assert evidence.child_status == nil
      assert evidence.output_truncated == true
    end

    test "an unexpected outcome is an io error with unknown evidence" do
      assert {{:error, {:io, {:unexpected_outcome, :weird}}}, evidence} = translate(:weird)
      assert evidence.cleanup == :unknown
    end

    test "not-started evidence fabricates no native status" do
      evidence = Runner.not_started_evidence()
      assert evidence.child_status == nil
      assert evidence.child_signal == nil
      assert evidence.execution == :not_started
    end
  end

  defp result(status, evidence, stdout \\ "out\n") do
    %WithEvidence{status: status, stdout: stdout, stderr: "", evidence: evidence}
  end

  defp native(overrides) do
    Map.merge(
      %{
        child_status: 0,
        child_signal: nil,
        termination: :exit,
        reason: nil,
        output_truncated: false,
        cleanup: :confirmed,
        scope: :process_group,
        guard_close: :ok
      },
      Map.new(overrides)
    )
  end

  defp translate(outcome, dropped \\ 0),
    do: ForcolaEvidence.translate({:done, outcome, %{lines_dropped: dropped}})
end
