defmodule ClaudeWrapper.BudgetTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Budget

  defp start_budget(opts \\ []) do
    {:ok, pid} = Budget.start_link(opts)
    pid
  end

  describe "record/2 and total/1" do
    test "accumulates recorded costs" do
      b = start_budget()
      assert :ok = Budget.record(b, 0.01)
      assert :ok = Budget.record(b, 0.02)
      assert :ok = Budget.record(b, 0.03)
      assert_in_delta Budget.total(b), 0.06, 1.0e-9
    end

    test "ignores non-positive costs" do
      b = start_budget()
      assert :ok = Budget.record(b, 0.0)
      assert :ok = Budget.record(b, 0)
      assert :ok = Budget.record(b, -0.5)
      assert Budget.total(b) == 0.0
    end

    test "a nil cost is a no-op (recording result.cost_usd directly is safe)" do
      b = start_budget()
      assert :ok = Budget.record(b, nil)
      assert Budget.total(b) == 0.0
    end

    test "accepts integer costs" do
      b = start_budget()
      assert :ok = Budget.record(b, 1)
      assert :ok = Budget.record(b, 2)
      assert_in_delta Budget.total(b), 3.0, 1.0e-9
    end
  end

  describe "remaining/1" do
    test "is nil when no max is set" do
      b = start_budget()
      assert Budget.remaining(b) == nil
    end

    test "tracks max minus total" do
      b = start_budget(max_usd: 1.00)
      assert_in_delta Budget.remaining(b), 1.00, 1.0e-9
      Budget.record(b, 0.40)
      assert_in_delta Budget.remaining(b), 0.60, 1.0e-9
    end

    test "clamps at zero once the ceiling is passed" do
      b = start_budget(max_usd: 1.00)
      Budget.record(b, 10.00)
      assert Budget.remaining(b) == 0.0
    end
  end

  describe "check/1" do
    test "is a no-op when no max is set" do
      b = start_budget()
      Budget.record(b, 1_000.0)
      assert Budget.check(b) == :ok
    end

    test "returns ok below the ceiling, then budget_exceeded once it is reached" do
      b = start_budget(max_usd: 0.10)
      Budget.record(b, 0.05)
      assert Budget.check(b) == :ok

      # total 0.10 -> at the threshold (>=) crosses it
      Budget.record(b, 0.05)

      assert {:error,
              %ClaudeWrapper.Error{
                kind: :budget_exceeded,
                reason: %{total_usd: total, max_usd: max}
              }} = Budget.check(b)

      assert_in_delta total, 0.10, 1.0e-9
      assert_in_delta max, 0.10, 1.0e-9
    end
  end

  describe "max_usd/1 and warn_at_usd/1" do
    test "report the configured thresholds" do
      b = start_budget(max_usd: 2.00, warn_at_usd: 1.50)
      assert Budget.max_usd(b) == 2.00
      assert Budget.warn_at_usd(b) == 1.50
    end

    test "are nil when unconfigured" do
      b = start_budget()
      assert Budget.max_usd(b) == nil
      assert Budget.warn_at_usd(b) == nil
    end
  end

  describe "on_warning callback" do
    test "fires once the first time the warn threshold is crossed" do
      test_pid = self()

      b =
        start_budget(
          warn_at_usd: 0.10,
          on_warning: fn total -> send(test_pid, {:warned, total}) end
        )

      Budget.record(b, 0.05)
      refute_received {:warned, _}

      # total 0.11 -> crosses
      Budget.record(b, 0.06)
      assert_receive {:warned, total}
      assert_in_delta total, 0.11, 1.0e-9

      # further spend does not re-fire
      Budget.record(b, 0.20)
      refute_received {:warned, _}
    end
  end

  describe "on_exceeded callback" do
    test "fires once the first time the max threshold is crossed" do
      test_pid = self()

      b =
        start_budget(
          max_usd: 1.00,
          on_exceeded: fn total -> send(test_pid, {:exceeded, total}) end
        )

      Budget.record(b, 0.50)
      Budget.record(b, 0.49)
      refute_received {:exceeded, _}

      # total 1.01 -> crosses
      Budget.record(b, 0.02)
      assert_receive {:exceeded, total}
      assert_in_delta total, 1.01, 1.0e-9

      # further spend does not re-fire
      Budget.record(b, 0.50)
      refute_received {:exceeded, _}
    end
  end

  describe "reset/1" do
    test "clears the total and re-arms both callbacks" do
      test_pid = self()

      b =
        start_budget(
          warn_at_usd: 0.10,
          max_usd: 0.20,
          on_warning: fn _ -> send(test_pid, :warned) end,
          on_exceeded: fn _ -> send(test_pid, :exceeded) end
        )

      Budget.record(b, 0.25)
      assert_receive :warned
      assert_receive :exceeded
      assert {:error, %ClaudeWrapper.Error{kind: :budget_exceeded}} = Budget.check(b)

      assert :ok = Budget.reset(b)
      assert Budget.total(b) == 0.0
      assert Budget.check(b) == :ok

      # callbacks re-arm and fire again after a reset
      Budget.record(b, 0.25)
      assert_receive :warned
      assert_receive :exceeded
    end
  end

  describe "name registration" do
    test "can be driven by a registered name" do
      name = :"budget_#{System.unique_integer([:positive])}"
      {:ok, _pid} = Budget.start_link(name: name, max_usd: 0.10)

      assert :ok = Budget.record(name, 0.20)
      assert {:error, %ClaudeWrapper.Error{kind: :budget_exceeded}} = Budget.check(name)
    end
  end
end
