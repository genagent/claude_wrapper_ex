defmodule ClaudeWrapper.QueryTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Query

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
          tmux: true
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
          plugin_dirs: ["/p1", "/p2"]
        )

      assert q.tools == ["Read", "Edit"]
      assert q.files == ["doc.txt", "img.png"]
      assert q.plugin_dirs == ["/p1", "/p2"]
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
end
