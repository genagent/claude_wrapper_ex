defmodule ClaudeWrapper.RunningCostTest do
  @moduledoc "Result costs are the session's running total (#319)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Result, Session}

  @fake Path.expand("../fixtures/fake_claude", __DIR__)

  defp result(sid, cost), do: %Result{result: "", session_id: sid, cost_usd: cost}

  describe "Result.turn_cost/2, turn_costs/1 and total_cost/1" do
    test "a session's total is its latest result, and turn costs are the differences" do
      results = [result("s", 0.25), result("s", 0.5), result("s", 1.0)]
      assert Result.total_cost(results) == 1.0
      assert Result.turn_costs(results) == [0.25, 0.25, 0.5]
    end

    test "results with no cost are skipped and map to nil" do
      results = [result("s", 0.25), result("s", nil), result("s", 0.75)]
      assert Result.total_cost(results) == 0.75
      assert Result.turn_costs(results) == [0.25, nil, 0.5]
    end

    test "a new session id starts a new running total" do
      results = [result("a", 0.25), result("a", 0.5), result("b", 0.125)]
      assert Result.total_cost(results) == 0.625
      assert Result.turn_costs(results) == [0.25, 0.25, 0.125]
    end

    test "a total that goes down starts a new running total" do
      results = [result("s", 0.5), result("s", 0.25)]
      assert Result.total_cost(results) == 0.75
      assert Result.turn_costs(results) == [0.5, 0.25]
    end

    test "an integer zero cost is a float total" do
      assert Result.total_cost([result("s", 0)]) === 0.0
      assert Result.total_cost([]) === 0.0
    end
  end

  test "Session.total_cost/1 over resumed turns is the latest total, not a sum" do
    calls = Path.join(System.tmp_dir!(), "running-cost-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(calls) end)

    config =
      Config.new(
        binary: @fake,
        env: [{"FAKE_CLAUDE_SCENARIO", "running_total"}, {"FAKE_CLAUDE_CALLS", calls}]
      )

    parent = self()
    handler = "running-cost-#{inspect(parent)}"

    :telemetry.attach(
      handler,
      [:claude_wrapper, :session, :turn, :stop],
      # Handlers are global and run in the emitting process; other async
      # tests emit session turns too, so keep only this test's.
      fn _event, _meas, meta, _ ->
        if self() == parent, do: send(parent, {:turn_stop, meta})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)

    session =
      Enum.reduce(1..3, Session.new(config), fn _, session ->
        {:ok, session, _} = Session.send(session, "p")
        session
      end)

    assert Enum.map(Session.turns(session), & &1.cost_usd) == [0.01, 0.02, 0.03]
    assert Session.total_cost(session) == 0.03

    for {cost, expected} <- Enum.zip(Session.turn_costs(session), [0.01, 0.01, 0.01]) do
      assert_in_delta cost, expected, 1.0e-9
    end

    for _ <- 1..3 do
      assert_receive {:turn_stop, %{turn_cost_usd: cost}}
      assert_in_delta cost, 0.01, 1.0e-9
    end
  end
end
