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

    test "json_schema/2 encodes a map schema and keeps strings verbatim" do
      q = Query.new("x") |> Query.json_schema(%{"type" => "object"})
      assert q.json_schema == ~s({"type":"object"})
      assert Query.apply_opts(Query.new("x"), json_schema: ~s({"a":1})).json_schema == ~s({"a":1})
      assert "--json-schema" in Query.build_args(q)
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

    test "false or nil leaves the flag unchanged" do
      q =
        "p"
        |> Query.new()
        |> Query.apply_opts(
          dangerously_skip_permissions: false,
          worktree: false,
          brief: nil,
          hermetic: nil
        )

      refute q.dangerously_skip_permissions
      refute q.worktree
      refute q.brief
      assert q.hermetic == nil
    end

    test "any other value for a boolean flag raises (#325)" do
      for value <- [0, "true", :yes] do
        assert_raise ArgumentError, ~r/invalid value .* for option :fork_session/, fn ->
          Query.apply_opts(Query.new("p"), fork_session: value)
        end
      end

      assert_raise ArgumentError, ~r/:strict_mcp_config/, fn ->
        Query.apply_opts(Query.new("p"), strict_mcp_config: "true")
      end
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

  describe "session selectors (#325)" do
    defp selector_args(opts),
      do: "p" |> Query.new() |> Query.apply_opts(opts) |> Query.build_args()

    test "valid combinations build" do
      assert "--resume" in selector_args(resume: "a")
      assert "--continue" in selector_args(continue_session: true)
      assert "--session-id" in selector_args(session_id: "u")
      args = selector_args(session_id: "u", resume: "a", fork_session: true)
      assert "--fork-session" in args and "--session-id" in args
      assert "--fork-session" in selector_args(continue_session: true, fork_session: true)
    end

    test "conflicting selectors raise before anything is spawned" do
      assert_raise ArgumentError, ~r/either :resume or :continue_session/, fn ->
        selector_args(resume: "a", continue_session: true)
      end

      assert_raise ArgumentError, ~r/:fork_session needs/, fn ->
        selector_args(fork_session: true)
      end

      assert_raise ArgumentError, ~r/:session_id with :resume/, fn ->
        selector_args(session_id: "u", resume: "a")
      end

      assert_raise ArgumentError, ~r/:session_id with :resume/, fn ->
        selector_args(session_id: "u", continue_session: true)
      end
    end
  end

  describe "apply_opts/2 -- robustness" do
    test "unknown opts raise, naming every unknown key (#325)" do
      error =
        assert_raise ArgumentError, fn ->
          Query.apply_opts(Query.new("p"),
            permision_mode: :plan,
            hermetc: true,
            permision_mode: :plan,
            model: "sonnet"
          )
        end

      assert error.message =~ ":permision_mode, :hermetc"
    end

    test "a non-keyword entry raises" do
      assert_raise ArgumentError, ~r/keyword list/, fn ->
        Query.apply_opts(Query.new("p"), [{"model", "sonnet"}])
      end
    end

    test "list options take a list or one string; anything else raises" do
      q = Query.apply_opts(Query.new("p"), allowed_tools: "Read", disallowed_tools: ["Bash"])
      args = Query.build_args(q)
      assert "Read" in args
      assert "Bash" in args

      assert_raise ArgumentError, ~r/:allowed_tools/, fn ->
        Query.apply_opts(Query.new("p"), allowed_tools: :read)
      end
    end

    test "no known option name is reported as unknown" do
      for key <- Query.known_opts() do
        try do
          Query.apply_opts(Query.new("p"), [{key, nil}])
        rescue
          e in ArgumentError -> refute e.message =~ "unknown option", inspect(key)
          FunctionClauseError -> :ok
        end
      end
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
          fork_session: true,
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

  describe "build_args/1 enum + betas handling (#219, #220)" do
    test "emits the exact CLI value for each permission_mode / effort atom" do
      permission_modes = [
        {:default, "default"},
        {:accept_edits, "acceptEdits"},
        {:bypass_permissions, "bypassPermissions"},
        {:dont_ask, "dontAsk"},
        {:plan, "plan"},
        {:auto, "auto"}
      ]

      for {atom, cli} <- permission_modes do
        args = "p" |> Query.new() |> Query.apply_opts(permission_mode: atom) |> Query.build_args()
        assert ["--permission-mode", cli] |> subsequence?(args)
      end

      for {atom, cli} <- [low: "low", medium: "medium", high: "high", xhigh: "xhigh", max: "max"] do
        args = "p" |> Query.new() |> Query.apply_opts(effort: atom) |> Query.build_args()
        assert ["--effort", cli] |> subsequence?(args)
      end
    end

    test "an out-of-vocabulary enum atom raises an actionable error (not FunctionClauseError)" do
      assert_raise ArgumentError, ~r/invalid permission_mode :yolo; expected one of/, fn ->
        "p" |> Query.new() |> Query.apply_opts(permission_mode: :yolo) |> Query.build_args()
      end

      assert_raise ArgumentError, ~r/invalid effort :extreme/, fn ->
        "p" |> Query.new() |> Query.apply_opts(effort: :extreme) |> Query.build_args()
      end
    end

    test "--betas accepts a variadic list and a single string (#219)" do
      list_args = "p" |> Query.new() |> Query.betas(["beta-a", "beta-b"]) |> Query.build_args()
      assert ["--betas", "beta-a", "beta-b"] |> subsequence?(list_args)

      string_args = "p" |> Query.new() |> Query.betas("beta-a") |> Query.build_args()
      assert ["--betas", "beta-a"] |> subsequence?(string_args)
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

    test "an invalid scope raises (#325)" do
      for value <- [:bogus, "full"] do
        assert_raise ArgumentError, ~r/:hermetic/, fn ->
          Query.apply_opts(Query.new("p"), hermetic: value)
        end
      end
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

  describe "build_args/1 file + tool + thinking flags (#222)" do
    test "the hidden one-shot flags round-trip through apply_opts + build_args" do
      q =
        Query.new("p")
        |> Query.apply_opts(
          system_prompt_file: "/sp.txt",
          append_system_prompt_file: "/asp.txt",
          permission_prompt_tool: "mcp__x__approve",
          max_thinking_tokens: 4096
        )

      args = Query.build_args(q)

      assert subsequence?(["--system-prompt-file", "/sp.txt"], args)
      assert subsequence?(["--append-system-prompt-file", "/asp.txt"], args)
      assert subsequence?(["--permission-prompt-tool", "mcp__x__approve"], args)
      # the integer budget is stringified
      assert subsequence?(["--max-thinking-tokens", "4096"], args)

      # spawn-safe: they flow through spawn_args unchanged (not transport/print flags)
      assert subsequence?(["--system-prompt-file", "/sp.txt"], Query.spawn_args(q))
    end

    test "the direct setter sets max_thinking_tokens" do
      assert Query.new("p") |> Query.max_thinking_tokens(4096) |> Map.get(:max_thinking_tokens) ==
               4096
    end
  end

  describe "remaining print flags (#328)" do
    @new_flags ~w(--restricted --permission-prompts --system-prompt-snapshot --autocompact
                  --allow-dangerously-skip-permissions --chrome --no-chrome
                  --forward-subagent-text --append-subagent-system-prompt
                  --append-subagent-system-prompt-file --advisor)

    defp args_for(opts), do: "p" |> Query.new() |> Query.apply_opts(opts) |> Query.build_args()

    test "unset fields emit none of the new flags" do
      args = Query.build_args(Query.new("p"))

      for flag <- @new_flags, do: refute(flag in args, "#{flag} emitted while unset")
      refute "--prompt-suggestions" in args

      q = Query.new("p")
      assert q.chrome == nil
      assert q.prompt_suggestions == nil
      assert q.extra_args == []
    end

    test "each setter emits its exact operands" do
      args =
        Query.new("p")
        |> Query.restricted()
        |> Query.permission_prompts(:none)
        |> Query.system_prompt_snapshot(:off)
        |> Query.autocompact(250_000)
        |> Query.allow_dangerously_skip_permissions()
        |> Query.chrome(true)
        |> Query.forward_subagent_text()
        |> Query.append_subagent_system_prompt("sub text")
        |> Query.append_subagent_system_prompt_file("/sub.txt")
        |> Query.advisor("opus")
        |> Query.build_args()

      assert "--restricted" in args
      assert subsequence?(["--permission-prompts", "none"], args)
      assert subsequence?(["--system-prompt-snapshot", "off"], args)
      assert subsequence?(["--autocompact", "250000"], args)
      assert "--allow-dangerously-skip-permissions" in args
      assert "--chrome" in args
      refute "--no-chrome" in args
      assert "--forward-subagent-text" in args
      assert subsequence?(["--append-subagent-system-prompt", "sub text"], args)
      assert subsequence?(["--append-subagent-system-prompt-file", "/sub.txt"], args)
      assert subsequence?(["--advisor", "opus"], args)
      assert Enum.take(args, -2) == ["--", "p"]
    end

    test "each keyword option routes to its setter" do
      args =
        args_for(
          restricted: true,
          permission_prompts: :host,
          system_prompt_snapshot: :on,
          autocompact: :auto,
          allow_dangerously_skip_permissions: true,
          chrome: false,
          forward_subagent_text: true,
          append_subagent_system_prompt: "a",
          append_subagent_system_prompt_file: "/b",
          advisor: "c",
          extra_args: ["--x", "1"]
        )

      assert "--restricted" in args
      assert subsequence?(["--permission-prompts", "host"], args)
      assert subsequence?(["--system-prompt-snapshot", "on"], args)
      assert subsequence?(["--autocompact", "auto"], args)
      assert "--allow-dangerously-skip-permissions" in args
      assert "--no-chrome" in args
      refute "--chrome" in args
      assert "--forward-subagent-text" in args
      assert subsequence?(["--append-subagent-system-prompt", "a"], args)
      assert subsequence?(["--append-subagent-system-prompt-file", "/b"], args)
      assert subsequence?(["--advisor", "c"], args)
      assert subsequence?(["--x", "1", "--", "p"], args)
    end

    test "boolean keyword options ignore false and nil" do
      args =
        args_for(
          restricted: false,
          allow_dangerously_skip_permissions: nil,
          forward_subagent_text: false
        )

      refute "--restricted" in args
      refute "--allow-dangerously-skip-permissions" in args
      refute "--forward-subagent-text" in args
    end

    test "allow_dangerously_skip_permissions does not enable bypass" do
      args = args_for(allow_dangerously_skip_permissions: true)

      assert "--allow-dangerously-skip-permissions" in args
      refute "--dangerously-skip-permissions" in args
      refute "--permission-mode" in args
    end

    test "chrome: true/false/nil" do
      assert "--chrome" in args_for(chrome: true)
      assert "--no-chrome" in args_for(chrome: false)

      unset = args_for(chrome: nil)
      refute "--chrome" in unset
      refute "--no-chrome" in unset

      assert "--no-chrome" in (Query.new("p") |> Query.chrome(false) |> Query.build_args())

      assert_raise ArgumentError, ~r/invalid value "yes" for option :chrome/, fn ->
        args_for(chrome: "yes")
      end
    end

    test "prompt_suggestions: unset, true (bare flag) and false (explicit value)" do
      refute "--prompt-suggestions" in args_for([])
      refute "--prompt-suggestions" in args_for(prompt_suggestions: nil)

      bare = Query.new("p") |> Query.prompt_suggestions() |> Query.build_args()
      assert subsequence?(["--prompt-suggestions", "--"], bare)

      assert subsequence?(["--prompt-suggestions", "--"], args_for(prompt_suggestions: true))

      explicit_true = Query.new("p") |> Query.prompt_suggestions(true) |> Query.build_args()
      assert subsequence?(["--prompt-suggestions", "--"], explicit_true)

      off = Query.new("p") |> Query.prompt_suggestions(false) |> Query.build_args()
      assert subsequence?(["--prompt-suggestions", "false"], off)
      assert subsequence?(["--prompt-suggestions", "false"], args_for(prompt_suggestions: false))

      assert_raise ArgumentError, ~r/:prompt_suggestions/, fn ->
        args_for(prompt_suggestions: "false")
      end
    end

    test "invalid enum values raise through invalid_enum!" do
      assert_raise ArgumentError, ~r/invalid permission_prompts :ask; expected one of/, fn ->
        args_for(permission_prompts: :ask)
      end

      assert_raise ArgumentError, ~r/invalid system_prompt_snapshot "off"; expected one of/, fn ->
        args_for(system_prompt_snapshot: "off")
      end
    end

    test "autocompact accepts :auto and any positive integer, emitted in decimal" do
      assert subsequence?(["--autocompact", "auto"], args_for(autocompact: :auto))
      assert subsequence?(["--autocompact", "1"], args_for(autocompact: 1))
      assert subsequence?(["--autocompact", "200"], args_for(autocompact: 200))
      assert subsequence?(["--autocompact", "100000"], args_for(autocompact: 100_000))
      assert subsequence?(["--autocompact", "2000000"], args_for(autocompact: 2_000_000))
    end

    test "autocompact rejects non-positive and malformed values" do
      for value <- [0, -1, 150_000.0, "200000", :manual] do
        assert_raise ArgumentError, ~r/invalid autocompact/, fn ->
          args_for(autocompact: value)
        end
      end
    end

    test "permission_mode :manual emits manual and :default still emits default" do
      assert subsequence?(["--permission-mode", "manual"], args_for(permission_mode: :manual))
      assert subsequence?(["--permission-mode", "default"], args_for(permission_mode: :default))
      assert Query.permission_mode_arg(:manual) == "manual"

      assert_raise ArgumentError, ~r/:manual\]/, fn -> args_for(permission_mode: :nope) end
    end

    test "the new flags survive spawn_args (the duplex path)" do
      args =
        Query.new("p")
        |> Query.forward_subagent_text()
        |> Query.system_prompt_snapshot(:off)
        |> Query.chrome(false)
        |> Query.advisor("opus")
        |> Query.extra_args(["--late", "v"])
        |> Query.spawn_args()

      assert "--forward-subagent-text" in args
      assert subsequence?(["--system-prompt-snapshot", "off"], args)
      assert "--no-chrome" in args
      assert subsequence?(["--advisor", "opus"], args)
      assert Enum.take(args, -2) == ["--late", "v"]
      refute "--" in args
      refute "p" in args
    end
  end

  describe "extra_args (#328)" do
    test "preserves order and token boundaries and sits right before the separator" do
      args =
        Query.new("the prompt")
        |> Query.model("sonnet")
        |> Query.extra_args(["--flag one", "two"])
        |> Query.extra_args(["--three"])
        |> Query.build_args()

      assert Enum.take(args, -5) == ["--flag one", "two", "--three", "--", "the prompt"]
    end

    test "keyword lists accumulate across repeated keys" do
      q = Query.apply_opts(Query.new("p"), extra_args: ["--a"], extra_args: ["--b", "c"])
      assert q.extra_args == ["--a", "--b", "c"]
      assert Query.apply_opts(Query.new("p"), extra_args: nil).extra_args == []
    end

    test "rejects anything other than a list of strings" do
      for value <- ["--a", [:a], ["--a", 1], %{a: 1}, :a] do
        assert_raise ArgumentError, ~r/extra_args must be a list of strings/, fn ->
          Query.apply_opts(Query.new("p"), extra_args: value)
        end

        assert_raise ArgumentError, ~r/extra_args must be a list of strings/, fn ->
          Query.extra_args(Query.new("p"), value)
        end
      end
    end

    test "rejects a -- element" do
      assert_raise ArgumentError, ~r/must not contain "--"/, fn ->
        Query.extra_args(Query.new("p"), ["--a", "--", "x"])
      end
    end

    test "a struct field set directly is checked when the arguments are built" do
      assert_raise ArgumentError, ~r/extra_args must be a list of strings/, fn ->
        Query.build_args(%{Query.new("p") | extra_args: [1]})
      end
    end

    test "the prompt is still delivered through argv and stdin" do
      dir = Path.join(System.tmp_dir!(), "extra-args-#{System.unique_integer([:positive])}")

      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf!(dir) end)
      fake = Path.join(dir, "claude")
      out = Path.join(dir, "out")

      # Records argv (one per line) and, when no `--` separator is present
      # (stdin delivery), stdin; then prints a result.
      File.write!(fake, """
      #!/bin/sh
      printf '%s\\n' "$@" > '#{out}.argv'
      case " $* " in
        *" -- "*) : > '#{out}.stdin' ;;
        *) cat > '#{out}.stdin' ;;
      esac
      printf '{"type":"result","subtype":"success","is_error":false,"result":"ok","session_id":"s","duration_ms":1,"num_turns":1,"total_cost_usd":0}\\n'
      """)

      File.chmod!(fake, 0o755)
      config = ClaudeWrapper.Config.new(binary: fake)
      query = Query.new("hello there") |> Query.extra_args(["--extra", "v"])

      assert {:ok, _} = Query.execute(query, config)
      argv = File.read!(out <> ".argv") |> String.split("\n", trim: true)
      assert Enum.take(argv, -2) == ["--extra", "v"]
      refute "hello there" in argv
      assert File.read!(out <> ".stdin") == "hello there"

      assert {:ok, _} = Query.execute(Query.prompt_input(query, :argv), config)
      argv = File.read!(out <> ".argv") |> String.split("\n", trim: true)
      assert Enum.take(argv, -4) == ["--extra", "v", "--", "hello there"]
    end
  end
end
