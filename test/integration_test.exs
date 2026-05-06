defmodule ClaudeWrapper.IntegrationTest do
  @moduledoc """
  Integration tests that run against the real Claude CLI.

  Run with: mix test --include integration
  """
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, DuplexSession, Query, Session}

  @moduletag :integration

  setup do
    config = Config.new()
    {:ok, config: config}
  end

  describe "version" do
    test "returns CLI version" do
      assert {:ok, %{version: version}} = ClaudeWrapper.version()
      assert is_binary(version)
      assert version != ""
    end
  end

  describe "raw" do
    test "runs arbitrary commands" do
      assert {:ok, output} = ClaudeWrapper.raw(["--version"])
      assert is_binary(output)
    end
  end

  describe "query" do
    test "executes a simple prompt", %{config: config} do
      {:ok, result} =
        Query.new("Respond with exactly: hello world")
        |> Query.max_turns(1)
        |> Query.permission_mode(:plan)
        |> Query.no_session_persistence()
        |> Query.execute(config)

      assert is_binary(result.result)
      assert result.result != ""
      assert is_binary(result.session_id)
    end
  end

  describe "stream" do
    test "streams events from a prompt", %{config: config} do
      events =
        Query.new("Say hello")
        |> Query.max_turns(1)
        |> Query.permission_mode(:plan)
        |> Query.no_session_persistence()
        |> Query.stream(config)
        |> Enum.to_list()

      assert events != []

      types = Enum.map(events, & &1.type)
      assert "result" in types
    end
  end

  describe "session" do
    test "multi-turn conversation", %{config: config} do
      session = Session.new(config, max_turns: 1)

      {:ok, session, result1} =
        Session.send(session, "Respond with exactly: Got it, 42.",
          dangerously_skip_permissions: true
        )

      assert is_binary(result1.result)
      assert Session.turn_count(session) == 1
      assert Session.session_id(session) != nil

      {:ok, session, result2} =
        Session.send(session, "What number was in your last response?",
          dangerously_skip_permissions: true
        )

      assert is_binary(result2.result)
      assert Session.turn_count(session) == 2
      assert Session.total_cost(session) > 0.0
    end
  end

  describe "convenience API" do
    test "ClaudeWrapper.query/2 works end-to-end" do
      {:ok, result} =
        ClaudeWrapper.query("Respond with exactly: pong",
          max_turns: 1,
          permission_mode: :plan,
          no_session_persistence: true
        )

      assert result.result =~ "pong"
    end
  end

  describe "IEx helpers" do
    alias ClaudeWrapper.IEx, as: CIEx

    setup do
      CIEx.reset()
      :ok
    end

    test "chat and say multi-turn" do
      assert :ok =
               CIEx.chat("Respond with exactly: hello",
                 max_turns: 1,
                 dangerously_skip_permissions: true,
                 no_session_persistence: true
               )

      assert CIEx.session_id() != nil
      assert CIEx.last().result =~ "hello"

      assert :ok = CIEx.say("Respond with exactly: goodbye")
      assert CIEx.last().result =~ "goodbye"

      total = CIEx.cost()
      assert is_float(total)
      assert total > 0.0
    end
  end

  describe "DuplexSession" do
    test "round-trips a single turn", %{config: config} do
      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          extra_args: [
            "--permission-mode",
            "plan",
            "--max-turns",
            "1",
            "--no-session-persistence"
          ]
        )

      try do
        assert {:ok, %ClaudeWrapper.Result{} = result} =
                 DuplexSession.send(pid, "Respond with exactly: hello world")

        assert is_binary(result.result)
        assert result.result != ""
        assert DuplexSession.session_id(pid) != nil
      after
        DuplexSession.stop(pid)
      end
    end

    test "subscriber sees system_init, assistant, and result in order", %{config: config} do
      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          extra_args: [
            "--permission-mode",
            "plan",
            "--max-turns",
            "1",
            "--no-session-persistence"
          ]
        )

      try do
        :ok = DuplexSession.subscribe(pid)

        send_task =
          Task.async(fn ->
            DuplexSession.send(pid, "Respond with exactly: hello world")
          end)

        # The CLI emits system/init first, then at least one assistant turn,
        # then a result. We assert the boundary events arrive in that order.
        assert_receive {:claude, {:system_init, sid}}, 60_000
        assert is_binary(sid)

        assert_receive {:claude, {:assistant, %{"type" => "assistant"}}}, 120_000
        assert_receive {:claude, {:result, %ClaudeWrapper.Result{}}}, 120_000

        assert {:ok, %ClaudeWrapper.Result{}} = Task.await(send_task, 120_000)
      after
        DuplexSession.stop(pid)
      end
    end

    test "rejects overlapping sends with :turn_in_flight", %{config: config} do
      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          extra_args: [
            "--permission-mode",
            "plan",
            "--max-turns",
            "1",
            "--no-session-persistence"
          ]
        )

      try do
        # Spawn the first send, then immediately try a second; the second
        # should bounce off pending_turn before the first completes.
        parent = self()

        spawn_link(fn ->
          result = DuplexSession.send(pid, "Respond with exactly: first turn done.")
          Kernel.send(parent, {:first_done, result})
        end)

        # Give the first call a moment to register pending_turn.
        Process.sleep(50)

        assert {:error, :turn_in_flight} =
                 DuplexSession.send(pid, "second", 1_000)

        assert_receive {:first_done, {:ok, %ClaudeWrapper.Result{}}}, 120_000
      after
        DuplexSession.stop(pid)
      end
    end
  end
end
