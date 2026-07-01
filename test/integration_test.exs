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

  # Session persistence is eventually consistent across separate `claude`
  # subprocess invocations: a rapid `--resume` can momentarily miss the
  # prior turn ("No conversation found"). Retry with a short backoff --
  # the same resilience a real consumer would want (and what
  # ClaudeWrapper.Retry exists for).
  defp send_resilient(session, prompt, opts, attempts \\ 4)

  defp send_resilient(session, prompt, opts, 1) do
    Session.send(session, prompt, opts)
  end

  defp send_resilient(session, prompt, opts, attempts) do
    case Session.send(session, prompt, opts) do
      {:ok, _session, _result} = ok ->
        ok

      {:error, _} ->
        Process.sleep(750)
        send_resilient(session, prompt, opts, attempts - 1)
    end
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

  describe "max-turns" do
    test "surfaces a typed :max_turns_exceeded error", %{config: config} do
      # Force a tool turn so a single --max-turns is exceeded: the model
      # must actually run the command to know its output, which costs one
      # turn, leaving none to report back.
      result =
        Query.new(
          "Using the Bash tool, run `echo $((6 * 7))` and then tell me the exact number it printed."
        )
        |> Query.max_turns(1)
        |> Query.dangerously_skip_permissions()
        |> Query.no_session_persistence()
        |> Query.execute(config)

      assert {:error, %ClaudeWrapper.Error{kind: :max_turns_exceeded, exit_code: code}} = result
      assert is_integer(code)
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
        send_resilient(session, "Respond with exactly: Got it, 42.",
          dangerously_skip_permissions: true
        )

      assert is_binary(result1.result)
      assert Session.turn_count(session) == 1
      assert Session.session_id(session) != nil

      {:ok, session, result2} =
        send_resilient(session, "What number was in your last response?",
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
      assert %ClaudeWrapper.Result{} =
               CIEx.chat("Respond with exactly: hello",
                 max_turns: 1,
                 dangerously_skip_permissions: true,
                 no_session_persistence: true
               )

      assert CIEx.session_id() != nil
      assert CIEx.last().result =~ "hello"

      assert %ClaudeWrapper.Result{} = CIEx.say("Respond with exactly: goodbye")
      assert CIEx.last().result =~ "goodbye"

      total = CIEx.cost()
      assert is_float(total)
      assert total > 0.0
    end

    test "high-level flow: chat with attach, say, fork, sessions" do
      tmp = Path.join(System.tmp_dir!(), "cwx_iex_flow_#{System.unique_integer([:positive])}")
      File.mkdir_p!(tmp)
      File.write!(Path.join(tmp, "note.txt"), "The secret token is BANANA.")
      on_exit(fn -> File.rm_rf!(tmp) end)

      # chat with an attached file. Persisted (no :no_session_persistence)
      # so the session can show up in sessions/0 below. working_dir is the
      # temp dir so history is keyed to this project slug.
      result =
        CIEx.chat("Read the attached file and reply with exactly the secret token.",
          working_dir: tmp,
          attach: Path.join(tmp, "note.txt"),
          max_turns: 1,
          dangerously_skip_permissions: true
        )

      assert %ClaudeWrapper.Result{} = result
      first_id = CIEx.session_id()
      assert is_binary(first_id)

      # say continues the same session.
      assert %ClaudeWrapper.Result{} = CIEx.say("Respond with exactly: continued")
      assert CIEx.last().result =~ "continued"

      # fork branches into a new session; current/0 switches to the branch.
      assert %ClaudeWrapper.Result{} = CIEx.fork("Respond with exactly: forked")
      branch_id = CIEx.session_id()
      assert is_binary(branch_id)
      assert branch_id != first_id

      # sessions/0 reads on-disk history for the ambient working_dir and
      # projects each row to the documented summary shape.
      summaries = CIEx.sessions()
      assert is_list(summaries)

      for s <- summaries do
        assert Map.has_key?(s, :id)
        assert Map.has_key?(s, :first_prompt)
        assert Map.has_key?(s, :turns)
        assert Map.has_key?(s, :last_used)
        assert Map.has_key?(s, :tokens)
        assert Map.has_key?(s, :cost_usd)
      end
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

    test "interrupt cancels an in-flight turn", %{config: config} do
      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          extra_args: [
            "--permission-mode",
            "plan",
            "--no-session-persistence"
          ]
        )

      try do
        :ok = DuplexSession.subscribe(pid)

        # Long prompt; we'll interrupt before the model finishes.
        prompt = """
        Write a detailed essay (at least 2000 words) about the history
        of operating systems, covering Multics, Unix, Plan 9, BeOS, NT,
        Linux, and macOS. Be exhaustive and thorough.
        """

        send_task =
          Task.async(fn ->
            DuplexSession.send(pid, prompt, 120_000)
          end)

        # Wait for streaming to actually start so the interrupt has
        # something to cancel. stream_event fires on the first delta,
        # which is much earlier than the first complete assistant
        # message.
        assert_receive {:claude, {:stream_event, _}}, 60_000

        assert :ok = DuplexSession.interrupt(pid, 10_000)

        # The original send/3 should still resolve (with whatever the
        # CLI emits as the cancel-flavored result). We do not assert
        # on `result.result` content because the partial output is
        # intentionally non-deterministic.
        {:ok, %ClaudeWrapper.Result{}} = Task.await(send_task, 60_000)
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

        assert {:error, %ClaudeWrapper.Error{kind: :turn_in_flight}} =
                 DuplexSession.send(pid, "second", 1_000)

        assert_receive {:first_done, {:ok, %ClaudeWrapper.Result{}}}, 120_000
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "DuplexIEx" do
    alias ClaudeWrapper.DuplexIEx

    setup do
      on_exit(fn ->
        try do
          DuplexIEx.close()
        catch
          _, _ -> :ok
        end
      end)

      :ok
    end

    test "start, say, close full round-trip" do
      output =
        ExUnit.CaptureIO.capture_io(fn ->
          assert :ok = DuplexIEx.start(working_dir: File.cwd!())
          assert :ok = DuplexIEx.say("Respond with exactly: hello duplex iex.", timeout: 60_000)
          assert is_binary(DuplexIEx.session_id())
          assert :ok = DuplexIEx.close()
        end)

      assert output =~ "Claude session started"
      assert output =~ "hello"
      assert output =~ "Session closed"
    end
  end

  describe "DuplexSession health" do
    test "alive?/exit_status/wait_for_exit across a clean shutdown", %{config: config} do
      {:ok, pid} =
        DuplexSession.start_link(
          config: config,
          extra_args: ["--permission-mode", "plan", "--no-session-persistence"]
        )

      # No turn is sent, so this spends no tokens -- it just verifies the
      # health helpers against a real, live stream-json subprocess.
      assert DuplexSession.alive?(pid)
      assert DuplexSession.exit_status(pid) == :running

      :ok = DuplexSession.stop(pid)

      refute DuplexSession.alive?(pid)
      assert DuplexSession.wait_for_exit(pid) == :completed
      assert DuplexSession.exit_status(pid) == :completed
    end
  end

  describe "Conversation" do
    alias ClaudeWrapper.Conversation

    test "accumulates history over a real turn", %{config: config} do
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
        conv = Conversation.new(pid)

        assert {:ok, conv, %ClaudeWrapper.Result{} = result} =
                 Conversation.send(conv, "Respond with exactly: hi", 120_000)

        assert is_binary(result.result)
        assert Conversation.turn_count(conv) == 1
        assert Conversation.last_result(conv) == result
        assert Conversation.history(conv) == [result]
        assert Conversation.session_id(conv) != nil
      after
        DuplexSession.stop(pid)
      end
    end
  end

  describe "read modules (live ~/.claude)" do
    test "History reads real project transcripts" do
      {:ok, root} = ClaudeWrapper.History.home()
      assert {:ok, projects} = ClaudeWrapper.History.list_projects(root)
      assert is_list(projects)

      for p <- Enum.take(projects, 1) do
        assert %ClaudeWrapper.History.ProjectSummary{slug: slug} = p
        assert is_binary(slug)
        assert {:ok, sessions} = ClaudeWrapper.History.list_sessions(root, slug: slug, limit: 1)

        for s <- Enum.take(sessions, 1) do
          assert {:ok, %ClaudeWrapper.History.SessionLog{entries: entries}} =
                   ClaudeWrapper.History.read_session(root, s.session_id)

          assert is_list(entries)
        end
      end
    end

    test "Settings loads real layers" do
      assert {:ok, %ClaudeWrapper.Settings{paths: paths}} =
               ClaudeWrapper.Settings.load(project_root: File.cwd!())

      assert is_binary(paths.user)
    end

    test "Agents lists and reads real definition files" do
      {:ok, root} = ClaudeWrapper.Agents.home()
      assert {:ok, agents} = ClaudeWrapper.Agents.list(root)
      assert is_list(agents)

      for a <- Enum.take(agents, 1) do
        assert %ClaudeWrapper.Agents.Summary{file_stem: stem} = a
        assert {:ok, %ClaudeWrapper.Agents.Definition{}} = ClaudeWrapper.Agents.get(root, stem)
      end
    end

    test "Skills lists real skill dirs" do
      {:ok, root} = ClaudeWrapper.Skills.home()
      assert {:ok, skills} = ClaudeWrapper.Skills.list(root)
      assert is_list(skills)
    end

    test "Jobs lists real job state" do
      {:ok, root} = ClaudeWrapper.Jobs.home()
      assert {:ok, jobs} = ClaudeWrapper.Jobs.list(root)
      assert is_list(jobs)
    end

    test "Worktrees lists this repo's worktrees" do
      assert {:ok, wt} = ClaudeWrapper.Worktrees.for_repo(File.cwd!())
      assert {:ok, list} = ClaudeWrapper.Worktrees.list(wt)
      assert Enum.any?(list, & &1.is_main?)
    end

    test "CliVersion parses the real --version" do
      assert {:ok, %{version: raw}} = ClaudeWrapper.version()
      assert {:ok, %ClaudeWrapper.CliVersion{} = v} = ClaudeWrapper.CliVersion.parse(raw)

      assert ClaudeWrapper.CliVersion.satisfies_minimum?(
               v,
               ClaudeWrapper.CliVersion.new(2, 0, 0)
             )
    end
  end

  describe "command smokes (live, non-mutating)" do
    alias ClaudeWrapper.Commands.{Doctor, Mcp, Plugin, Version}

    test "mcp list", %{config: config} do
      assert {:ok, output} = Mcp.list(config)
      assert is_binary(output)
    end

    test "plugin list", %{config: config} do
      assert {:ok, _plugins} = Plugin.list(config)
    end

    test "auth status" do
      assert {:ok, status} = ClaudeWrapper.auth_status()
      assert is_map(status)
    end

    test "doctor", %{config: config} do
      assert {:ok, _output} = Doctor.execute(config)
    end

    test "version", %{config: config} do
      assert {:ok, _version_info} = Version.execute(config)
    end
  end
end
