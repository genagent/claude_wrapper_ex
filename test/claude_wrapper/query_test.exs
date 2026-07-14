defmodule ClaudeWrapper.QueryTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.Query

  # True when `sub` appears as a contiguous run inside `list` (a flag
  # immediately followed by its value(s)).
  defp subsequence?(sub, list) do
    len = length(sub)

    list
    |> Enum.chunk_every(len, 1, :discard)
    |> Enum.any?(&(&1 == sub))
  end

  describe "apply_opts/2 -- scalar opts" do
    test "applies all scalar string/value opts" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          model: "sonnet",
          system_prompt: "be terse",
          append_system_prompt: "use british english",
          max_turns: 7,
          max_budget_usd: 1.5,
          permission_mode: :plan,
          effort: :high,
          json_schema: ~s({"type":"object"}),
          agent: "reviewer",
          agents_json: ~s({"reviewer":{}}),
          session_id: "fixed-session",
          resume: "prior-session",
          fallback_model: "haiku",
          output_format: :json,
          input_format: :stream_json,
          settings: ~s({"foo":"bar"}),
          debug_filter: "api,hooks",
          debug_file: "/tmp/dbg.log",
          betas: "feature-x",
          name: "my session",
          setting_sources: "user,project"
        )

      assert q.model == "sonnet"
      assert q.system_prompt == "be terse"
      assert q.append_system_prompt == "use british english"
      assert q.max_turns == 7
      assert q.max_budget_usd == 1.5
      assert q.permission_mode == :plan
      assert q.effort == :high
      assert q.json_schema =~ "object"
      assert q.agent == "reviewer"
      assert q.agents_json =~ "reviewer"
      assert q.session_id == "fixed-session"
      assert q.resume == "prior-session"
      assert q.fallback_model == "haiku"
      assert q.output_format == :json
      assert q.input_format == :stream_json
      assert q.settings =~ "bar"
      assert q.debug_filter == "api,hooks"
      assert q.debug_file == "/tmp/dbg.log"
      assert q.betas == "feature-x"
      assert q.name == "my session"
      assert q.setting_sources == "user,project"
    end
  end

  describe "apply_opts/2 -- boolean flags" do
    test "true applies the flag" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          dangerously_skip_permissions: true,
          continue_session: true,
          no_session_persistence: true,
          worktree: true,
          brief: true,
          fork_session: true,
          strict_mcp_config: true,
          include_partial_messages: true,
          tmux: true,
          safe_mode: true
        )

      assert q.dangerously_skip_permissions
      assert q.continue_session
      assert q.no_session_persistence
      assert q.worktree
      assert q.brief
      assert q.fork_session
      assert q.strict_mcp_config
      assert q.include_partial_messages
      assert q.tmux
      assert q.safe_mode
    end

    test "false (or any non-true) leaves the flag unchanged" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          dangerously_skip_permissions: false,
          worktree: false,
          brief: nil,
          fork_session: 0
        )

      refute q.dangerously_skip_permissions
      refute q.worktree
      refute q.brief
      refute q.fork_session
    end
  end

  describe "apply_opts/2 -- list opts" do
    test "allowed_tools and disallowed_tools accept lists" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          allowed_tools: ["Read", "Bash"],
          disallowed_tools: ["WebFetch", "Edit"]
        )

      assert q.allowed_tools == ["Read", "Bash"]
      assert q.disallowed_tools == ["WebFetch", "Edit"]
    end

    test "tools, files, plugin_dirs accept lists" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          tools: ["Read", "Edit"],
          files: ["doc.txt", "img.png"],
          plugin_dirs: ["/p1", "/p2"],
          plugin_urls: ["https://x/a.zip", "https://x/b.zip"]
        )

      assert q.tools == ["Read", "Edit"]
      assert q.files == ["doc.txt", "img.png"]
      assert q.plugin_dirs == ["/p1", "/p2"]
      assert q.plugin_urls == ["https://x/a.zip", "https://x/b.zip"]
    end

    test "add_dir accepts a list or a single binary" do
      q1 = Query.apply_opts(Query.new("p"), add_dir: ["/a", "/b"])
      assert q1.add_dir == ["/a", "/b"]

      q2 = Query.apply_opts(Query.new("p"), add_dir: "/a")
      assert q2.add_dir == ["/a"]
    end

    test "mcp_config accepts a list or a single binary" do
      q1 = Query.apply_opts(Query.new("p"), mcp_config: ["/a.json", "/b.json"])
      assert q1.mcp_config == ["/a.json", "/b.json"]

      q2 = Query.apply_opts(Query.new("p"), mcp_config: "/single.json")
      assert q2.mcp_config == ["/single.json"]
    end
  end

  describe "apply_opts/2 -- robustness" do
    test "unknown opts are silently ignored" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          unknown_thing: 42,
          some_future_opt: "value",
          model: "sonnet"
        )

      # Known ones still apply.
      assert q.model == "sonnet"
      # Struct integrity preserved.
      assert %Query{} = q
    end

    test "empty opts list is a no-op" do
      q = Query.new("p")
      assert Query.apply_opts(q, []) == q
    end

    test "options applied left-to-right; later wins" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(model: "haiku", model: "sonnet")

      assert q.model == "sonnet"
    end
  end

  describe "spawn_args/1" do
    test "drops the prompt and the transport-format flags" do
      args =
        "hello there"
        |> Query.new()
        |> Query.apply_opts(
          output_format: :stream_json,
          input_format: :stream_json,
          include_partial_messages: true
        )
        |> Query.spawn_args()

      refute "hello there" in args
      refute "--print" in args
      refute "--output-format" in args
      refute "--input-format" in args
      refute "--include-partial-messages" in args
    end

    test "passes spawn-time knobs through" do
      args =
        ""
        |> Query.new()
        |> Query.apply_opts(
          model: "sonnet",
          system_prompt: "be terse",
          permission_mode: :plan,
          allowed_tools: ["Read", "Bash"],
          disallowed_tools: ["WebFetch"],
          mcp_config: ["/mcp.json"],
          add_dir: ["/extra"],
          effort: :high,
          max_turns: 20,
          max_budget_usd: 5.0,
          json_schema: ~s({"type":"object"}),
          session_id: "sess-1",
          resume: "prior",
          fallback_model: "haiku",
          strict_mcp_config: true,
          no_session_persistence: true
        )
        |> Query.spawn_args()

      assert ["--model", "sonnet"] |> subsequence?(args)
      assert ["--system-prompt", "be terse"] |> subsequence?(args)
      assert ["--permission-mode", "plan"] |> subsequence?(args)
      assert ["--allowed-tools", "Read", "Bash"] |> subsequence?(args)
      assert ["--disallowed-tools", "WebFetch"] |> subsequence?(args)
      assert ["--mcp-config", "/mcp.json"] |> subsequence?(args)
      assert ["--add-dir", "/extra"] |> subsequence?(args)
      assert ["--effort", "high"] |> subsequence?(args)
      assert ["--max-turns", "20"] |> subsequence?(args)
      assert ["--max-budget-usd", "5.0"] |> subsequence?(args)
      assert ["--json-schema", ~s({"type":"object"})] |> subsequence?(args)
      assert ["--session-id", "sess-1"] |> subsequence?(args)
      assert ["--resume", "prior"] |> subsequence?(args)
      assert ["--fallback-model", "haiku"] |> subsequence?(args)
      assert "--strict-mcp-config" in args
      assert "--no-session-persistence" in args
    end

    test "an empty query yields no flags" do
      assert Query.spawn_args(Query.new("")) == []
    end
  end

  describe "build_args/1 prompt handling (#197)" do
    test "emits a bare --print and the prompt last, after a -- separator" do
      args = Query.build_args(Query.new("do the thing"))

      assert "--print" in args
      assert Enum.take(args, -2) == ["--", "do the thing"]
    end

    test "a dash-prefixed prompt goes after -- so the CLI does not parse it as a flag" do
      args = Query.build_args(Query.new("--version is what I want summarized"))

      assert Enum.take(args, -2) == ["--", "--version is what I want summarized"]
    end
  end

  describe "hermetic preset (#193)" do
    test "hermetic: true defaults to the full seal" do
      q = "p" |> Query.new() |> Query.apply_opts(hermetic: true)
      assert q.hermetic == :full

      args = Query.build_args(q)
      assert ["--setting-sources", ""] |> subsequence?(args)
      assert "--strict-mcp-config" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
    end

    test ":full drops every ambient layer" do
      args =
        "p" |> Query.new() |> Query.apply_opts(hermetic: :full) |> Query.build_args()

      assert ["--setting-sources", ""] |> subsequence?(args)
      assert "--strict-mcp-config" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
    end

    test ":project keeps the user's global config" do
      args =
        "p" |> Query.new() |> Query.apply_opts(hermetic: :project) |> Query.build_args()

      assert ["--setting-sources", "user"] |> subsequence?(args)
      assert "--strict-mcp-config" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
    end

    test "an explicit setting_sources wins over the scope default, order-independently" do
      # setting_sources set before hermetic in the keyword list ...
      before = [setting_sources: "user,project", hermetic: :full]
      args_before = "p" |> Query.new() |> Query.apply_opts(before) |> Query.build_args()
      assert ["--setting-sources", "user,project"] |> subsequence?(args_before)

      # ... and after it. Same result either way.
      after_ = [hermetic: :full, setting_sources: "user,project"]
      args_after = "p" |> Query.new() |> Query.apply_opts(after_) |> Query.build_args()
      assert ["--setting-sources", "user,project"] |> subsequence?(args_after)

      # The two booleans are still forced regardless.
      assert "--strict-mcp-config" in args_after
      assert "--exclude-dynamic-system-prompt-sections" in args_after
    end

    test "hermetic never emits --bare (seals promptspace, not auth)" do
      args = "p" |> Query.new() |> Query.apply_opts(hermetic: :full) |> Query.build_args()
      refute "--bare" in args
    end

    test "an invalid scope is ignored, leaving no seal" do
      q = "p" |> Query.new() |> Query.apply_opts(hermetic: :bogus)
      assert q.hermetic == nil

      args = Query.build_args(q)
      refute "--setting-sources" in args
      refute "--strict-mcp-config" in args
      refute "--exclude-dynamic-system-prompt-sections" in args
    end

    test "no hermetic opt leaves the surface untouched" do
      args = "p" |> Query.new() |> Query.build_args()
      refute "--setting-sources" in args
      refute "--strict-mcp-config" in args
      refute "--exclude-dynamic-system-prompt-sections" in args
    end

    test "the seal carries through spawn_args (the duplex path)" do
      args = "p" |> Query.new() |> Query.apply_opts(hermetic: :project) |> Query.spawn_args()
      assert ["--setting-sources", "user"] |> subsequence?(args)
      assert "--strict-mcp-config" in args
    end
  end

  describe "regression coverage for #40" do
    test "all opts the issue called out as missing now apply" do
      missing = [
        worktree: true,
        allowed_tools: ["Read"],
        disallowed_tools: ["Bash"],
        add_dir: ["/path"],
        mcp_config: ["/mcp.json"],
        settings: "{}",
        files: ["x"],
        tools: ["Read"],
        append_system_prompt: "appended",
        fallback_model: "haiku",
        output_format: :json,
        agents_json: "{}",
        fork_session: true,
        strict_mcp_config: true
      ]

      q = "p" |> Query.new() |> Query.apply_opts(missing)

      assert q.worktree
      assert q.allowed_tools == ["Read"]
      assert q.disallowed_tools == ["Bash"]
      assert q.add_dir == ["/path"]
      assert q.mcp_config == ["/mcp.json"]
      assert q.settings == "{}"
      assert q.files == ["x"]
      assert q.tools == ["Read"]
      assert q.append_system_prompt == "appended"
      assert q.fallback_model == "haiku"
      assert q.output_format == :json
      assert q.agents_json == "{}"
      assert q.fork_session
      assert q.strict_mcp_config
    end
  end

  describe "handle_nonzero_exit/2 -- rail-stop caps" do
    test "surfaces :max_turns_exceeded with parsed cap and run figures" do
      stdout =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => "Reached maximum number of turns (3)",
          "session_id" => "sess-abc",
          "num_turns" => 3,
          "total_cost_usd" => 0.0512,
          "duration_ms" => 1234
        })

      assert {:error, %Error{kind: :max_turns_exceeded} = error} =
               Query.handle_nonzero_exit(1, stdout)

      assert error.exit_code == 1
      assert error.stdout == stdout

      assert error.reason == %{
               cap: 3,
               cost_usd: 0.0512,
               num_turns: 3,
               session_id: "sess-abc"
             }
    end

    test "surfaces :max_budget_exceeded with parsed cap and run figures" do
      stdout =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_budget_usd",
          "is_error" => true,
          "result" => "Reached maximum budget ($5.00)",
          "session_id" => "sess-def",
          "num_turns" => 7,
          "total_cost_usd" => 5.12,
          "duration_ms" => 9999
        })

      assert {:error, %Error{kind: :max_budget_exceeded} = error} =
               Query.handle_nonzero_exit(1, stdout)

      assert error.reason == %{
               cap: 5.0,
               cost_usd: 5.12,
               num_turns: 7,
               session_id: "sess-def"
             }
    end

    test "tolerates a missing cap in the result message" do
      stdout =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_turns",
          "is_error" => true,
          "result" => "stopped",
          "num_turns" => 2
        })

      assert {:error, %Error{kind: :max_turns_exceeded, reason: reason}} =
               Query.handle_nonzero_exit(1, stdout)

      assert reason.cap == nil
      assert reason.cost_usd == nil
      assert reason.num_turns == 2
      assert reason.session_id == nil
    end

    test ":max_budget_exceeded is distinct from the client-side :budget_exceeded" do
      stdout =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "error_max_budget_usd",
          "result" => "Reached maximum budget ($1)"
        })

      assert {:error, %Error{kind: :max_budget_exceeded, reason: %{cap: 1.0}}} =
               Query.handle_nonzero_exit(1, stdout)
    end

    test "a non-rail-stop error result keeps its is_error flag and returns :ok" do
      stdout =
        Jason.encode!(%{
          "type" => "result",
          "subtype" => "success",
          "is_error" => true,
          "result" => "some other failure",
          "num_turns" => 1
        })

      assert {:ok, %ClaudeWrapper.Result{is_error: true}} =
               Query.handle_nonzero_exit(1, stdout)
    end

    test "non-JSON output falls back to a command failure" do
      assert {:error, %Error{kind: kind}} = Query.handle_nonzero_exit(1, "boom: not json")
      assert kind in [:command_failed, :auth]
    end
  end
end
