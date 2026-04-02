defmodule ClaudeWrapper.WorkshopTest do
  use ExUnit.Case, async: false

  alias ClaudeWrapper.Workshop

  setup do
    # Full teardown/restart for clean slate
    Workshop.stop()
    on_exit(fn -> Workshop.stop() end)
    :ok
  end

  describe "configure/1" do
    test "sets global config" do
      assert :ok = Workshop.configure(model: "sonnet", working_dir: "/tmp")
    end

    test "can be called with no options" do
      assert :ok = Workshop.configure()
    end

    test "accepts context option" do
      assert :ok = Workshop.configure(context: "Elixir project.")
    end
  end

  describe "agent/1,2,3" do
    test "creates an agent with just a name" do
      assert :ok = Workshop.agent(:scratch)
      assert :scratch in Workshop.agents()
    end

    test "creates an agent with name and role" do
      assert :ok = Workshop.agent(:impl, "You write code.")
      assert :impl in Workshop.agents()
    end

    test "creates an agent with name, role, and opts" do
      assert :ok = Workshop.agent(:impl, "You write code.", max_turns: 15)
      assert :impl in Workshop.agents()
    end

    test "creates an agent with name and opts (no role)" do
      assert :ok = Workshop.agent(:impl, model: "opus")
      assert :impl in Workshop.agents()
    end

    test "replaces existing agent with same name" do
      Workshop.agent(:impl, "Role 1")
      Workshop.agent(:impl, "Role 2")
      assert Workshop.agents() == [:impl]
    end
  end

  describe "agents/0" do
    test "returns empty list initially" do
      assert Workshop.agents() == []
    end

    test "returns sorted list of agent names" do
      Workshop.agent(:zeta)
      Workshop.agent(:alpha)
      Workshop.agent(:mid)
      assert Workshop.agents() == [:alpha, :mid, :zeta]
    end
  end

  describe "dismiss/1" do
    test "removes an agent" do
      Workshop.agent(:impl)
      assert :impl in Workshop.agents()
      Workshop.dismiss(:impl)
      refute :impl in Workshop.agents()
    end

    test "is a no-op for unknown agents" do
      assert :ok = Workshop.dismiss(:nonexistent)
    end
  end

  describe "reset/1" do
    test "resets an agent's state" do
      Workshop.agent(:impl, "You write code.")
      Workshop.reset(:impl)
      assert :impl in Workshop.agents()
    end

    test "raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.reset(:nonexistent)
      end
    end
  end

  describe "reset_all/0" do
    test "removes all agents and clears config" do
      Workshop.configure(model: "sonnet")
      Workshop.agent(:impl)
      Workshop.agent(:reviewer)
      Workshop.reset_all()
      assert Workshop.agents() == []
    end
  end

  describe "status/0" do
    test "works with no agents" do
      assert :ok = Workshop.status()
    end

    test "works with agents" do
      Workshop.agent(:impl, "Coder")
      Workshop.agent(:reviewer, "Reviewer")
      assert :ok = Workshop.status()
    end
  end

  describe "result/1,2" do
    test "returns nil for fresh agent" do
      Workshop.agent(:impl)
      assert Workshop.result(:impl) == nil
    end

    test "returns nil for fresh agent with :full" do
      Workshop.agent(:impl)
      assert Workshop.result(:impl, :full) == nil
    end

    test ":text is the default mode" do
      Workshop.agent(:impl)
      assert Workshop.result(:impl) == Workshop.result(:impl, :text)
    end
  end

  describe "info/1" do
    test "returns agent info map" do
      Workshop.configure(model: "sonnet")
      Workshop.agent(:impl, "You write code.", max_turns: 15)
      info = Workshop.info(:impl)

      assert info.name == :impl
      assert info.status == :idle
      assert info.model == "sonnet"
      assert info.role == "You write code."
      assert info.cost == 0.0
      assert info.turns == 0
      assert info.max_turns == 15
      assert info.session_id == nil
    end

    test "includes allowed_tools when set" do
      Workshop.agent(:reviewer, "Reviewer", allowed_tools: ["Read", "Bash"])
      info = Workshop.info(:reviewer)
      assert info.allowed_tools == ["Read", "Bash"]
    end

    test "raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.info(:nonexistent)
      end
    end
  end

  describe "inspect_agent/1,2" do
    test "returns command string" do
      Workshop.agent(:impl, "You write code.", model: "sonnet")
      cmd = Workshop.inspect_agent(:impl)

      assert cmd =~ "claude"
      assert cmd =~ "--model"
      assert cmd =~ "sonnet"
      assert cmd =~ "--system-prompt"
      assert cmd =~ "--output-format"
      assert cmd =~ "json"
      assert cmd =~ "PROMPT"
    end

    test "uses provided prompt" do
      Workshop.agent(:impl)
      cmd = Workshop.inspect_agent(:impl, "fix the bug")
      assert cmd =~ "fix the bug"
    end

    test "includes resume flag when session exists" do
      # Fresh agent has no session_id, so no --resume
      Workshop.agent(:impl)
      cmd = Workshop.inspect_agent(:impl)
      refute cmd =~ "--resume"
    end
  end

  describe "total_cost/0" do
    test "returns 0.0 with no agents" do
      assert Workshop.total_cost() == 0.0
    end

    test "returns 0.0 with fresh agents" do
      Workshop.agent(:impl)
      assert Workshop.total_cost() == 0.0
    end
  end

  describe "stream/2" do
    test "raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.stream(:nonexistent, "hello")
      end
    end
  end

  describe "put_session" do
    test "SessionServer.put_session updates the session" do
      config = ClaudeWrapper.Config.new()
      {:ok, pid} = ClaudeWrapper.SessionServer.start_link(config: config)

      session = ClaudeWrapper.SessionServer.get_session(pid)
      assert ClaudeWrapper.Session.session_id(session) == nil

      updated = %{session | session_id: "test-sid"}
      :ok = ClaudeWrapper.SessionServer.put_session(pid, updated)

      assert ClaudeWrapper.SessionServer.session_id(pid) == "test-sid"
      GenServer.stop(pid)
    end
  end

  describe "error handling" do
    test "ask raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.ask(:nonexistent, "hello")
      end
    end

    test "cast raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.cast(:nonexistent, "hello")
      end
    end

    test "await raises for unknown agent" do
      assert_raise ArgumentError, fn ->
        Workshop.await(:nonexistent)
      end
    end
  end
end
