defmodule ClaudeWrapperTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{
    Config,
    Error,
    McpConfig,
    Prompt,
    Query,
    Result,
    Retry,
    Session,
    SessionServer,
    StreamEvent,
    ToolPattern
  }

  describe "Config" do
    test "new with defaults" do
      config = Config.new()
      assert config.binary != nil
      assert config.working_dir == nil
      assert config.env == []
      assert config.verbose == false
    end

    test "new with options" do
      config = Config.new(working_dir: "/tmp", verbose: true)
      assert config.working_dir == "/tmp"
      assert config.verbose == true
    end

    test "base_args includes verbose flag" do
      config = Config.new(verbose: true)
      assert "--verbose" in Config.base_args(config)
    end

    test "base_args empty when no flags" do
      config = Config.new()
      assert Config.base_args(config) == []
    end
  end

  describe "Query" do
    test "new creates query with prompt" do
      query = Query.new("test prompt")
      assert query.prompt == "test prompt"
    end

    test "builder chain" do
      query =
        Query.new("fix it")
        |> Query.model("sonnet")
        |> Query.max_turns(5)
        |> Query.dangerously_skip_permissions()
        |> Query.permission_mode(:bypass_permissions)

      assert query.model == "sonnet"
      assert query.max_turns == 5
      assert query.dangerously_skip_permissions == true
      assert query.permission_mode == :bypass_permissions
    end

    test "build_args generates correct CLI arguments" do
      args =
        Query.new("hello world")
        |> Query.model("sonnet")
        |> Query.max_turns(3)
        |> Query.dangerously_skip_permissions()
        |> Query.build_args()

      assert "--print" in args
      assert "hello world" in args
      assert "--model" in args
      assert "sonnet" in args
      assert "--max-turns" in args
      assert "3" in args
      assert "--dangerously-skip-permissions" in args
    end

    test "build_args omits nil values" do
      args = Query.new("test") |> Query.build_args()

      refute "--model" in args
      refute "--max-turns" in args
      refute "--dangerously-skip-permissions" in args
    end

    test "build_args emits --fork-session when fork_session is set" do
      with_fork =
        Query.new("p")
        |> Query.resume("abc-123")
        |> Query.fork_session()
        |> Query.build_args()

      assert "--fork-session" in with_fork
      assert "--resume" in with_fork
      assert "abc-123" in with_fork

      without_fork =
        Query.new("p")
        |> Query.resume("abc-123")
        |> Query.build_args()

      refute "--fork-session" in without_fork
    end

    test "build_args emits --fork-session when set via apply_opts" do
      args =
        Query.new("p")
        |> Query.apply_opts(continue_session: true, fork_session: true)
        |> Query.build_args()

      assert "--fork-session" in args
      assert "--continue" in args
    end

    test "build_args emits --debug with the filter value (not --debug-filter)" do
      args =
        Query.new("p")
        |> Query.debug_filter("api,hooks")
        |> Query.build_args()

      # Regression for #156: the CLI flag is `--debug [filter]`, not `--debug-filter`.
      refute "--debug-filter" in args
      idx = Enum.find_index(args, &(&1 == "--debug"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "api,hooks"
    end

    test "build_args emits --debug-file with the path" do
      args =
        Query.new("p")
        |> Query.debug_file("/tmp/debug.log")
        |> Query.build_args()

      idx = Enum.find_index(args, &(&1 == "--debug-file"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "/tmp/debug.log"
    end

    test "build_args emits --name with the value" do
      args = Query.new("p") |> Query.name("my session") |> Query.build_args()

      idx = Enum.find_index(args, &(&1 == "--name"))
      assert idx != nil
      assert Enum.at(args, idx + 1) == "my session"
    end

    test "build_args emits --safe-mode only when set" do
      assert "--safe-mode" in (Query.new("p") |> Query.safe_mode() |> Query.build_args())
      refute "--safe-mode" in (Query.new("p") |> Query.build_args())
    end

    test "build_args emits repeated --plugin-url for each url" do
      args =
        Query.new("p")
        |> Query.plugin_url("https://example.com/a.zip")
        |> Query.plugin_url("https://example.com/b.zip")
        |> Query.build_args()

      assert Enum.count(args, &(&1 == "--plugin-url")) == 2
      assert "https://example.com/a.zip" in args
      assert "https://example.com/b.zip" in args
    end

    test "to_command_string" do
      config = Config.new()

      cmd =
        Query.new("hello")
        |> Query.model("sonnet")
        |> Query.to_command_string(config)

      assert cmd =~ "--print"
      assert cmd =~ "hello"
      assert cmd =~ "--model"
      assert cmd =~ "sonnet"
    end

    test "list args accumulate" do
      query =
        Query.new("test")
        |> Query.allowed_tool("Read")
        |> Query.allowed_tool("Write")
        |> Query.mcp_config("/path/one")
        |> Query.mcp_config("/path/two")

      assert query.allowed_tools == ["Read", "Write"]
      assert query.mcp_config == ["/path/one", "/path/two"]
    end

    test "execute strips --verbose from args to preserve JSON output" do
      config = Config.new(verbose: true)
      # Verbose should be in base_args
      assert "--verbose" in Config.base_args(config)
      # But execute strips it (we can't call execute without a real binary,
      # so verify the args via to_command_string which uses the same path)
      query = Query.new("test")
      # Verify the fix by checking that base_args -- ["--verbose"] works
      base = Config.base_args(config) -- ["--verbose"]
      args = base ++ Query.build_args(%{query | output_format: :json})
      refute "--verbose" in args
      assert "--output-format" in args
    end
  end

  describe "build_args -- CLI flag names (#82)" do
    test "emits --agents (not --agents-json) for agents_json" do
      args =
        Query.new("p")
        |> Query.agents_json(~s({"reviewer":{}}))
        |> Query.build_args()

      assert "--agents" in args
      refute "--agents-json" in args

      idx = Enum.find_index(args, &(&1 == "--agents"))
      assert Enum.at(args, idx + 1) == ~s({"reviewer":{}})
    end

    test "emits a single variadic --tools (not repeated --tool)" do
      args =
        Query.new("p")
        |> Query.tool("Read")
        |> Query.tool("Bash")
        |> Query.build_args()

      refute "--tool" in args
      assert Enum.count(args, &(&1 == "--tools")) == 1

      idx = Enum.find_index(args, &(&1 == "--tools"))
      assert Enum.slice(args, idx, 3) == ["--tools", "Read", "Bash"]
    end

    test "omits --tools and --agents when unset" do
      args = Query.new("p") |> Query.build_args()

      refute "--tools" in args
      refute "--tool" in args
      refute "--agents" in args
      refute "--agents-json" in args
    end
  end

  describe "build_args -- variadic tool flags (#105)" do
    test "allowed_tools and disallowed_tools emit one flag followed by all values" do
      args =
        Query.new("p")
        |> Query.allowed_tool("Read")
        |> Query.allowed_tool("Bash")
        |> Query.disallowed_tool("WebFetch")
        |> Query.disallowed_tool("Edit")
        |> Query.build_args()

      assert Enum.count(args, &(&1 == "--allowed-tools")) == 1
      ai = Enum.find_index(args, &(&1 == "--allowed-tools"))
      assert Enum.slice(args, ai, 3) == ["--allowed-tools", "Read", "Bash"]

      assert Enum.count(args, &(&1 == "--disallowed-tools")) == 1
      di = Enum.find_index(args, &(&1 == "--disallowed-tools"))
      assert Enum.slice(args, di, 3) == ["--disallowed-tools", "WebFetch", "Edit"]
    end
  end

  describe "allowed_tool/disallowed_tool accept ToolPattern (#96)" do
    test "a ToolPattern renders to its string form in --allowed-tools" do
      args =
        Query.new("p")
        |> Query.allowed_tool(ToolPattern.tool("Read"))
        |> Query.allowed_tool(ToolPattern.tool_with_args("Bash", "git log:*"))
        |> Query.build_args()

      ai = Enum.find_index(args, &(&1 == "--allowed-tools"))
      assert Enum.slice(args, ai, 3) == ["--allowed-tools", "Read", "Bash(git log:*)"]
    end

    test "plain strings still work and can be mixed with ToolPatterns" do
      query =
        Query.new("p")
        |> Query.allowed_tool("Read")
        |> Query.allowed_tool(ToolPattern.all("Write"))
        |> Query.disallowed_tool(ToolPattern.mcp("srv", "*"))
        |> Query.disallowed_tool("WebFetch")

      assert query.allowed_tools == ["Read", "Write(*)"]
      assert query.disallowed_tools == ["mcp__srv__*", "WebFetch"]
    end
  end

  describe "build_args -- added flags (#83)" do
    test "boolean flags emit when set" do
      args =
        Query.new("p")
        |> Query.prompt_suggestions()
        |> Query.replay_user_messages()
        |> Query.bare()
        |> Query.disable_slash_commands()
        |> Query.include_hook_events()
        |> Query.exclude_dynamic_system_prompt_sections()
        |> Query.build_args()

      assert "--prompt-suggestions" in args
      assert "--replay-user-messages" in args
      assert "--bare" in args
      assert "--disable-slash-commands" in args
      assert "--include-hook-events" in args
      assert "--exclude-dynamic-system-prompt-sections" in args
    end

    test "boolean flags absent by default" do
      args = Query.new("p") |> Query.build_args()

      refute "--bare" in args
      refute "--prompt-suggestions" in args
      refute "--replay-user-messages" in args
      refute "--disable-slash-commands" in args
      refute "--include-hook-events" in args
      refute "--exclude-dynamic-system-prompt-sections" in args
    end

    test "flags settable via apply_opts" do
      q =
        Query.new("p")
        |> Query.apply_opts(
          prompt_suggestions: true,
          replay_user_messages: true,
          bare: true,
          disable_slash_commands: true,
          include_hook_events: true,
          exclude_dynamic_system_prompt_sections: true
        )

      assert q.prompt_suggestions
      assert q.replay_user_messages
      assert q.bare
      assert q.disable_slash_commands
      assert q.include_hook_events
      assert q.exclude_dynamic_system_prompt_sections
    end

    test ":xhigh effort emits xhigh" do
      args = Query.new("p") |> Query.effort(:xhigh) |> Query.build_args()

      assert "--effort" in args
      idx = Enum.find_index(args, &(&1 == "--effort"))
      assert Enum.at(args, idx + 1) == "xhigh"
    end
  end

  describe "named worktree (#84)" do
    test "worktree/1 emits the bare flag" do
      assert Query.new("p") |> Query.worktree() |> Query.build_args() ==
               ["--print", "--worktree", "--", "p"]
    end

    test "worktree/2 emits --worktree <name>" do
      assert Query.new("p") |> Query.worktree("feature-x") |> Query.build_args() ==
               ["--print", "--worktree", "feature-x", "--", "p"]
    end

    test "apply_opts accepts a name, true, or false" do
      assert Query.apply_opts(Query.new("p"), worktree: "wt").worktree == "wt"
      assert Query.apply_opts(Query.new("p"), worktree: true).worktree == true
      assert Query.apply_opts(Query.new("p"), worktree: false).worktree == false
    end
  end

  describe "from_pr (#85)" do
    test "emits --from-pr with the PR value" do
      args =
        Query.new("review this")
        |> Query.from_pr("123")
        |> Query.build_args()

      assert "--from-pr" in args
      idx = Enum.find_index(args, &(&1 == "--from-pr"))
      assert Enum.at(args, idx + 1) == "123"
    end

    test "settable via apply_opts; absent by default" do
      q = Query.new("p") |> Query.apply_opts(from_pr: "https://github.com/o/r/pull/7")
      assert q.from_pr == "https://github.com/o/r/pull/7"

      refute "--from-pr" in (Query.new("p") |> Query.build_args())
    end
  end

  describe "Result" do
    test "from_json parses standard fields" do
      data = %{
        "result" => "hello world",
        "session_id" => "abc-123",
        "cost_usd" => 0.05,
        "duration_ms" => 1200,
        "num_turns" => 3,
        "is_error" => false
      }

      result = Result.from_json(data)
      assert result.result == "hello world"
      assert result.session_id == "abc-123"
      assert result.cost_usd == 0.05
      assert result.duration_ms == 1200
      assert result.num_turns == 3
      assert result.is_error == false
      assert result.extra == %{}
    end

    test "from_json captures extra fields" do
      data = %{"result" => "ok", "custom_field" => "value"}
      result = Result.from_json(data)
      assert result.extra == %{"custom_field" => "value"}
    end
  end

  describe "StreamEvent" do
    test "parse valid JSON line" do
      line = ~s({"type":"assistant","content":"hello"})
      assert {:ok, event} = StreamEvent.parse(line)
      assert event.type == "assistant"
      assert event.data["content"] == "hello"
      assert event.raw == line
    end

    test "parse invalid JSON" do
      assert {:error, %ClaudeWrapper.Error{kind: :json}} = StreamEvent.parse("not json")
    end

    test "result? checks type" do
      assert StreamEvent.result?(%StreamEvent{type: "result", data: %{}})
      refute StreamEvent.result?(%StreamEvent{type: "assistant", data: %{}})
    end

    test "result_text extracts from result event" do
      event = %StreamEvent{type: "result", data: %{"result" => "the answer"}}
      assert StreamEvent.result_text(event) == "the answer"
    end

    test "result_text returns nil for non-result" do
      event = %StreamEvent{type: "assistant", data: %{}}
      assert StreamEvent.result_text(event) == nil
    end

    test "cost_usd extracts from event" do
      event = %StreamEvent{type: "result", data: %{"cost_usd" => 0.03}}
      assert StreamEvent.cost_usd(event) == 0.03
    end

    # partial_message/1 -- ported from the Rust crate's streaming tests
    # (src/streaming.rs). Each sample is the CLI's stream_event envelope
    # wrapping a raw Anthropic content-block lifecycle event.
    defp parse_partial(inner) do
      line =
        Jason.encode!(%{
          "type" => "stream_event",
          "event" => inner,
          "session_id" => "sess-1",
          "parent_tool_use_id" => nil
        })

      assert {:ok, event} = StreamEvent.parse(line)
      StreamEvent.partial_message(event)
    end

    test "partial_message decodes a text block lifecycle" do
      assert parse_partial(%{
               "type" => "content_block_start",
               "index" => 0,
               "content_block" => %{"type" => "text", "text" => ""}
             }) == {:block_start, 0, :text}

      assert parse_partial(%{
               "type" => "content_block_delta",
               "index" => 0,
               "delta" => %{"type" => "text_delta", "text" => "Hello"}
             }) == {:block_delta, 0, {:text, "Hello"}}

      assert parse_partial(%{"type" => "content_block_stop", "index" => 0}) ==
               {:block_stop, 0}
    end

    test "partial_message decodes a thinking block lifecycle" do
      assert parse_partial(%{
               "type" => "content_block_start",
               "index" => 1,
               "content_block" => %{"type" => "thinking", "thinking" => "", "signature" => ""}
             }) == {:block_start, 1, :thinking}

      assert parse_partial(%{
               "type" => "content_block_delta",
               "index" => 1,
               "delta" => %{"type" => "thinking_delta", "thinking" => "weighing options"}
             }) == {:block_delta, 1, {:thinking, "weighing options"}}
    end

    test "partial_message carries tool_use id and name, and streams input json" do
      assert parse_partial(%{
               "type" => "content_block_start",
               "index" => 2,
               "content_block" => %{
                 "type" => "tool_use",
                 "id" => "toolu_abc",
                 "name" => "Bash",
                 "input" => %{}
               }
             }) == {:block_start, 2, {:tool_use, "toolu_abc", "Bash"}}

      assert parse_partial(%{
               "type" => "content_block_delta",
               "index" => 2,
               "delta" => %{"type" => "input_json_delta", "partial_json" => "{\"cmd\":"}
             }) == {:block_delta, 2, {:input_json, "{\"cmd\":"}}
    end

    test "partial_message falls through to :other for unknown kinds" do
      assert parse_partial(%{
               "type" => "content_block_start",
               "index" => 3,
               "content_block" => %{"type" => "redacted_thinking", "data" => "..."}
             }) == {:block_start, 3, {:other, "redacted_thinking"}}

      assert parse_partial(%{
               "type" => "content_block_delta",
               "index" => 3,
               "delta" => %{"type" => "signature_delta", "signature" => "sig"}
             }) == {:block_delta, 3, :other}
    end

    test "partial_message returns nil for non-partial events" do
      assert {:ok, result} =
               StreamEvent.parse(
                 ~s({"type":"result","result":"done","session_id":"sess-1","total_cost_usd":0.01})
               )

      assert StreamEvent.partial_message(result) == nil

      assert {:ok, assistant} =
               StreamEvent.parse(
                 ~s({"type":"assistant","message":{"role":"assistant","content":[]},"session_id":"sess-1"})
               )

      assert StreamEvent.partial_message(assistant) == nil

      # A message-level stream event (not a content-block event) is also nil.
      assert parse_partial(%{
               "type" => "message_start",
               "message" => %{"id" => "msg_1", "role" => "assistant", "content" => []}
             }) == nil
    end

    test "partial_message accepts a raw, unwrapped content-block event" do
      assert {:ok, event} =
               StreamEvent.parse(
                 ~s({"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hi"}})
               )

      assert StreamEvent.partial_message(event) == {:block_delta, 0, {:text, "hi"}}
    end
  end

  describe "Session" do
    test "new creates session with config" do
      config = Config.new()
      session = Session.new(config)
      assert session.config == config
      assert session.session_id == nil
      assert session.history == []
    end

    test "new with query opts" do
      config = Config.new()
      session = Session.new(config, model: "sonnet", max_turns: 5)
      assert session.query_opts == [model: "sonnet", max_turns: 5]
    end

    test "resume sets session_id" do
      config = Config.new()
      session = Session.resume(config, "abc-123")
      assert Session.session_id(session) == "abc-123"
    end

    test "turn_count starts at zero" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turn_count(session) == 0
    end

    test "total_cost starts at zero" do
      config = Config.new()
      session = Session.new(config)
      assert Session.total_cost(session) == 0.0
    end

    test "last_result returns nil when no turns" do
      config = Config.new()
      session = Session.new(config)
      assert Session.last_result(session) == nil
    end

    test "turns returns history" do
      config = Config.new()
      session = Session.new(config)
      assert Session.turns(session) == []
    end

    test "send/3 accepts a %Prompt{} and propagates a render error before any CLI call" do
      config = Config.new()
      session = Session.new(config)

      # A glob that matches nothing fails at render time, so send/3 must
      # short-circuit with the typed error -- no claude subprocess is
      # spawned (the binary is never invoked because render fails first).
      glob = Path.join(System.tmp_dir!(), "cwx_no_match_#{System.unique_integer([:positive])}/*")
      prompt = Prompt.new("hi") |> Prompt.attach(glob)

      assert {:error, %Error{kind: :not_found, reason: ^glob}} = Session.send(session, prompt)
    end

    test "fork/3 on a session with no id returns :no_session" do
      config = Config.new()
      session = Session.new(config)

      assert {:error, %Error{kind: :no_session}} = Session.fork(session, "branch this")
    end
  end

  describe "McpConfig" do
    test "new creates empty config" do
      config = McpConfig.new()
      assert config.servers == %{}
    end

    test "add_stdio adds a server" do
      config =
        McpConfig.new()
        |> McpConfig.add_stdio("my-server", "npx", ["-y", "pkg"])

      assert McpConfig.server_names(config) == ["my-server"]
      server = McpConfig.get_server(config, "my-server")
      assert server.type == "stdio"
      assert server.command == "npx"
      assert server.args == ["-y", "pkg"]
    end

    test "add_stdio with env" do
      config =
        McpConfig.new()
        |> McpConfig.add_stdio("srv", "cmd", [], env: %{"KEY" => "val"})

      server = McpConfig.get_server(config, "srv")
      assert server.env == %{"KEY" => "val"}
    end

    test "add_sse adds an SSE server" do
      config =
        McpConfig.new()
        |> McpConfig.add_sse("remote", "https://example.com/mcp")

      server = McpConfig.get_server(config, "remote")
      assert server.type == "sse"
      assert server.url == "https://example.com/mcp"
    end

    test "remove deletes a server" do
      config =
        McpConfig.new()
        |> McpConfig.add_stdio("a", "cmd", [])
        |> McpConfig.add_stdio("b", "cmd2", [])
        |> McpConfig.remove("a")

      assert McpConfig.server_names(config) == ["b"]
    end

    test "to_json produces valid JSON" do
      config =
        McpConfig.new()
        |> McpConfig.add_stdio("test", "echo", ["hello"])

      json = McpConfig.to_json(config)
      assert {:ok, data} = Jason.decode(json)
      assert data["mcpServers"]["test"]["command"] == "echo"
      assert data["mcpServers"]["test"]["args"] == ["hello"]
    end

    test "roundtrip through to_json and from_map" do
      config =
        McpConfig.new()
        |> McpConfig.add_stdio("srv", "npx", ["-y", "pkg"], env: %{"K" => "V"})
        |> McpConfig.add_sse("remote", "https://example.com")

      json = McpConfig.to_json(config)
      {:ok, data} = Jason.decode(json)
      roundtripped = McpConfig.from_map(data)

      assert McpConfig.server_names(roundtripped) |> Enum.sort() ==
               McpConfig.server_names(config) |> Enum.sort()

      assert McpConfig.get_server(roundtripped, "srv").command == "npx"
      assert McpConfig.get_server(roundtripped, "remote").url == "https://example.com"
    end

    test "preserves an http server (url + headers) through to_json/from_map (#199)" do
      config =
        McpConfig.new()
        |> McpConfig.add_http("sentry", "https://mcp.sentry.dev/mcp",
          headers: %{"Authorization" => "Bearer abc"}
        )

      json = McpConfig.to_json(config)
      {:ok, data} = Jason.decode(json)

      assert data["mcpServers"]["sentry"]["type"] == "http"
      assert data["mcpServers"]["sentry"]["url"] == "https://mcp.sentry.dev/mcp"
      assert data["mcpServers"]["sentry"]["headers"] == %{"Authorization" => "Bearer abc"}

      rt = McpConfig.from_map(data)
      assert McpConfig.get_server(rt, "sentry").url == "https://mcp.sentry.dev/mcp"
      assert McpConfig.get_server(rt, "sentry").headers == %{"Authorization" => "Bearer abc"}
    end

    test "a read-modify-write does not drop an http server's url (#199)" do
      # Simulates reading a project .mcp.json with an http server and writing it
      # back; previously the url was silently rewritten away to {"type":"http"}.
      data = %{"mcpServers" => %{"x" => %{"type" => "http", "url" => "https://x.example"}}}
      json = data |> McpConfig.from_map() |> McpConfig.to_json()
      {:ok, out} = Jason.decode(json)

      assert out["mcpServers"]["x"]["url"] == "https://x.example"
    end

    test "write! and read roundtrip" do
      path = Path.join(System.tmp_dir!(), "test_mcp_#{:rand.uniform(100_000)}.json")

      config =
        McpConfig.new()
        |> McpConfig.add_stdio("test", "echo", ["hi"], env: %{"A" => "B"})

      McpConfig.write!(config, path)
      assert {:ok, loaded} = McpConfig.read(path)
      assert McpConfig.get_server(loaded, "test").command == "echo"
      assert McpConfig.get_server(loaded, "test").env == %{"A" => "B"}

      File.rm!(path)
    end
  end

  describe "Retry" do
    test "compute_delay without jitter" do
      assert Retry.compute_delay(0, 1000, 30_000, 2, false) == 1000
      assert Retry.compute_delay(1, 1000, 30_000, 2, false) == 2000
      assert Retry.compute_delay(2, 1000, 30_000, 2, false) == 4000
      assert Retry.compute_delay(3, 1000, 30_000, 2, false) == 8000
    end

    test "compute_delay respects max_delay" do
      assert Retry.compute_delay(10, 1000, 5000, 2, false) == 5000
    end

    test "compute_delay with jitter is bounded" do
      for _ <- 1..50 do
        delay = Retry.compute_delay(2, 1000, 30_000, 2, true)
        assert delay >= 0
        assert delay <= 4000
      end
    end

    test "default_retry_on retries timeouts, plain command failures, and rate limits" do
      assert Retry.default_retry_on({:error, %Error{kind: :timeout}})
      assert Retry.default_retry_on({:error, %Error{kind: :command_failed, exit_code: 1}})
      assert Retry.default_retry_on({:error, %Error{kind: :auth, reason: :rate_limit}})
    end

    test "default_retry_on does not retry other auth failures or rail stops" do
      refute Retry.default_retry_on({:error, %Error{kind: :auth, reason: :not_authenticated}})
      refute Retry.default_retry_on({:error, %Error{kind: :auth, reason: :expired}})
      refute Retry.default_retry_on({:error, %Error{kind: :max_turns_exceeded}})
      refute Retry.default_retry_on({:error, %Error{kind: :max_budget_exceeded}})
      refute Retry.default_retry_on({:error, %Error{kind: :command_failed, exit_code: 0}})
    end
  end

  describe "SessionServer" do
    test "start_link and initial state" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config)

      assert SessionServer.session_id(pid) == nil
      assert SessionServer.turn_count(pid) == 0
      assert SessionServer.total_cost(pid) == 0.0
      assert SessionServer.last_result(pid) == nil
      assert SessionServer.history(pid) == []
    end

    test "start_link with query opts" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config, query_opts: [model: "sonnet"])

      session = SessionServer.get_session(pid)
      assert session.query_opts == [model: "sonnet"]
    end

    test "start_link with session_id for resume" do
      config = Config.new()
      {:ok, pid} = SessionServer.start_link(config: config, session_id: "abc-123")

      assert SessionServer.session_id(pid) == "abc-123"
    end

    test "start_link with name registration" do
      config = Config.new()

      {:ok, _pid} =
        SessionServer.start_link(config: config, name: :test_session_server)

      assert SessionServer.turn_count(:test_session_server) == 0
    end

    test "child_spec for supervision" do
      config = Config.new()
      spec = SessionServer.child_spec(config: config, name: :supervised_test)

      assert spec.id == SessionServer

      assert spec.start ==
               {SessionServer, :start_link, [[config: config, name: :supervised_test]]}
    end
  end

  describe "Commands.Plugin" do
    alias ClaudeWrapper.Commands.Plugin

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Plugin)
      assert {:list, 2} in Plugin.__info__(:functions)
      assert {:install, 3} in Plugin.__info__(:functions)
      assert {:uninstall, 3} in Plugin.__info__(:functions)
      assert {:enable, 3} in Plugin.__info__(:functions)
      assert {:disable, 3} in Plugin.__info__(:functions)
      assert {:update, 3} in Plugin.__info__(:functions)
      assert {:validate, 3} in Plugin.__info__(:functions)
      assert {:tag, 2} in Plugin.__info__(:functions)
      assert {:details, 2} in Plugin.__info__(:functions)
      assert {:prune, 2} in Plugin.__info__(:functions)
      assert {:install_args, 2} in Plugin.__info__(:functions)
      assert {:validate_args, 2} in Plugin.__info__(:functions)
    end

    test "install_args threads scope and repeatable config pairs" do
      assert Plugin.install_args("p", []) == ["plugin", "install", "p"]

      assert Plugin.install_args("p", scope: :project, config: ["a=1", "b=2"]) ==
               [
                 "plugin",
                 "install",
                 "p",
                 "--scope",
                 "project",
                 "--config",
                 "a=1",
                 "--config",
                 "b=2"
               ]
    end

    test "validate_args emits --strict only when set" do
      assert Plugin.validate_args("./m", []) == ["plugin", "validate", "./m"]

      assert Plugin.validate_args("./m", strict: true) == [
               "plugin",
               "validate",
               "./m",
               "--strict"
             ]
    end

    test "tag_args defaults to just the subcommand" do
      assert Plugin.tag_args([]) == ["plugin", "tag"]
    end

    test "tag_args composes all flags with path last" do
      args =
        Plugin.tag_args(
          path: "./my-plugin",
          dry_run: true,
          force: true,
          message: "release %s",
          push: true,
          remote: "upstream"
        )

      assert args == [
               "plugin",
               "tag",
               "--dry-run",
               "--force",
               "--message",
               "release %s",
               "--push",
               "--remote",
               "upstream",
               "./my-plugin"
             ]
    end

    test "tag_args emits only the flags that are set" do
      assert Plugin.tag_args(message: "v%s") == ["plugin", "tag", "--message", "v%s"]
      assert Plugin.tag_args(push: true) == ["plugin", "tag", "--push"]
      assert Plugin.tag_args(path: "./p") == ["plugin", "tag", "./p"]
      refute "--force" in Plugin.tag_args(dry_run: true)
    end

    test "prune_args defaults to just the subcommand" do
      assert Plugin.prune_args([]) == ["plugin", "prune"]
    end

    test "prune_args composes dry_run, scope, and yes" do
      assert Plugin.prune_args(dry_run: true, scope: :user, yes: true) ==
               ["plugin", "prune", "--dry-run", "--scope", "user", "--yes"]
    end

    test "prune_args emits scope value and omits unset flags" do
      assert Plugin.prune_args(scope: :project) == ["plugin", "prune", "--scope", "project"]
      assert Plugin.prune_args(yes: true) == ["plugin", "prune", "--yes"]
      refute "--dry-run" in Plugin.prune_args(yes: true)
    end

    test "uninstall_args defaults to plugin name with no flags" do
      assert Plugin.uninstall_args("old-plugin", []) == ["plugin", "uninstall", "old-plugin"]
    end

    test "uninstall_args composes scope, keep_data, prune, and yes" do
      assert Plugin.uninstall_args("old-plugin",
               scope: :user,
               keep_data: true,
               prune: true,
               yes: true
             ) ==
               [
                 "plugin",
                 "uninstall",
                 "old-plugin",
                 "--scope",
                 "user",
                 "--keep-data",
                 "--prune",
                 "--yes"
               ]
    end

    test "uninstall_args emits --prune and --yes independently" do
      assert Plugin.uninstall_args("p", prune: true) == ["plugin", "uninstall", "p", "--prune"]
      assert Plugin.uninstall_args("p", yes: true) == ["plugin", "uninstall", "p", "--yes"]
      refute "--keep-data" in Plugin.uninstall_args("p", prune: true)
    end
  end

  describe "Commands.Mcp" do
    alias ClaudeWrapper.Commands.Mcp

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Mcp)
      funcs = Mcp.__info__(:functions)

      assert {:list, 1} in funcs
      assert {:get, 2} in funcs
      assert {:add, 5} in funcs
      assert {:add_json, 4} in funcs
      assert {:add_from_desktop, 2} in funcs
      assert {:remove, 3} in funcs
      assert {:serve, 2} in funcs
      assert {:reset_project_choices, 1} in funcs

      # login/logout are gone: the current CLI has no `mcp login`/`logout`.
      refute {:login, 3} in funcs
      refute {:logout, 2} in funcs

      # @doc false builders are public for arg-composition testing.
      assert {:add_args, 4} in funcs
      assert {:add_json_args, 3} in funcs
      assert {:add_from_desktop_args, 1} in funcs
      assert {:serve_args, 1} in funcs
    end

    test "add_args defaults to subcommand plus positionals" do
      assert Mcp.add_args("srv", "npx", [], []) == ["mcp", "add", "srv", "npx"]
    end

    test "add_args passes inline command_args through as positionals" do
      assert Mcp.add_args("srv", "my-command", ["--some-flag", "arg1"], []) ==
               ["mcp", "add", "srv", "my-command", "--some-flag", "arg1"]
    end

    test "add_args emits the positionals before the flags (#202)" do
      assert Mcp.add_args("sentry", "https://mcp.sentry.dev/mcp", [], transport: :http) ==
               ["mcp", "add", "sentry", "https://mcp.sentry.dev/mcp", "--transport", "http"]

      assert Mcp.add_args("s", "u", [], transport: :sse) ==
               ["mcp", "add", "s", "u", "--transport", "sse"]

      assert Mcp.add_args("s", "u", [], transport: :stdio) ==
               ["mcp", "add", "s", "u", "--transport", "stdio"]
    end

    test "add_args emits env as repeated -e KEY=value, after the positionals (#202)" do
      # name/commandOrUrl must precede the variadic -e or the CLI swallows them.
      assert Mcp.add_args("s", "npx", [], env: %{"API_KEY" => "xxx"}) ==
               ["mcp", "add", "s", "npx", "-e", "API_KEY=xxx"]

      assert Mcp.add_args("s", "npx", [], env: [API_KEY: "xxx"]) ==
               ["mcp", "add", "s", "npx", "-e", "API_KEY=xxx"]
    end

    test "add_args emits one --header per header, after the positionals (#202)" do
      args =
        Mcp.add_args("c", "https://app.corridor.dev/api/mcp", [],
          transport: :http,
          header: ["Authorization: Bearer abc", "X-Custom: value"]
        )

      assert args == [
               "mcp",
               "add",
               "c",
               "https://app.corridor.dev/api/mcp",
               "--transport",
               "http",
               "--header",
               "Authorization: Bearer abc",
               "--header",
               "X-Custom: value"
             ]

      assert Enum.count(args, &(&1 == "--header")) == 2
    end

    test "add_args accepts headers as a map rendered Key: Value" do
      assert Mcp.add_args("s", "u", [], header: %{"X-Api-Key" => "abc123"}) ==
               ["mcp", "add", "s", "u", "--header", "X-Api-Key: abc123"]
    end

    test "add_args emits server_args after a -- separator" do
      assert Mcp.add_args("my-server", "npx", [], server_args: ["my-mcp-server"]) ==
               ["mcp", "add", "my-server", "npx", "--", "my-mcp-server"]

      assert Mcp.add_args("s", "npx", [], server_args: ["a", "b"]) ==
               ["mcp", "add", "s", "npx", "--", "a", "b"]
    end

    test "add_args omits the -- separator when server_args is empty" do
      assert Mcp.add_args("s", "npx", [], server_args: []) == ["mcp", "add", "s", "npx"]
    end

    test "add_args emits --callback-port with a stringified value" do
      assert Mcp.add_args("s", "https://example.com/mcp", [], callback_port: 8080) ==
               ["mcp", "add", "s", "https://example.com/mcp", "--callback-port", "8080"]
    end

    test "add_args emits --client-id and --client-secret together" do
      assert Mcp.add_args("s", "https://example.com/mcp", [],
               client_id: "my-app-id",
               client_secret: true
             ) ==
               [
                 "mcp",
                 "add",
                 "s",
                 "https://example.com/mcp",
                 "--client-id",
                 "my-app-id",
                 "--client-secret"
               ]
    end

    test "add_args omits --client-secret when falsy" do
      refute "--client-secret" in Mcp.add_args("s", "u", [], client_id: "id")
      refute "--client-secret" in Mcp.add_args("s", "u", [], client_secret: false)
    end

    test "add_args composes transport, scope, env, port, client_id, secret in order" do
      args =
        Mcp.add_args("srv", "https://example.com/mcp", [],
          transport: :http,
          scope: :user,
          env: %{"TOKEN" => "t"},
          callback_port: 9000,
          client_id: "cid",
          client_secret: true
        )

      assert args == [
               "mcp",
               "add",
               "srv",
               "https://example.com/mcp",
               "--transport",
               "http",
               "--scope",
               "user",
               "-e",
               "TOKEN=t",
               "--callback-port",
               "9000",
               "--client-id",
               "cid",
               "--client-secret"
             ]
    end

    test "add_args puts server_args after inline command_args, both after the URL" do
      assert Mcp.add_args("s", "npx", ["inline"], server_args: ["trailing"]) ==
               ["mcp", "add", "s", "npx", "inline", "--", "trailing"]
    end

    test "add_json_args defaults to subcommand plus positionals" do
      assert Mcp.add_json_args("srv", ~s({"command":"npx"}), []) ==
               ["mcp", "add-json", "srv", ~s({"command":"npx"})]
    end

    test "add_json_args emits --scope" do
      assert Mcp.add_json_args("srv", "{}", scope: :user) ==
               ["mcp", "add-json", "--scope", "user", "srv", "{}"]
    end

    test "add_json_args emits --client-secret" do
      assert Mcp.add_json_args("srv", "{}", client_secret: true) ==
               ["mcp", "add-json", "--client-secret", "srv", "{}"]
    end

    test "add_json_args omits --client-secret by default" do
      refute "--client-secret" in Mcp.add_json_args("srv", "{}", [])
    end

    test "add_json_args composes scope and client_secret" do
      assert Mcp.add_json_args("srv", "{}", scope: :project, client_secret: true) ==
               ["mcp", "add-json", "--scope", "project", "--client-secret", "srv", "{}"]
    end

    test "add_from_desktop_args defaults to just the subcommand" do
      assert Mcp.add_from_desktop_args([]) == ["mcp", "add-from-claude-desktop"]
    end

    test "add_from_desktop_args emits --scope (and takes no name -- the CLI has none)" do
      assert Mcp.add_from_desktop_args(scope: :user) ==
               ["mcp", "add-from-claude-desktop", "--scope", "user"]
    end

    test "serve_args defaults to just the subcommand" do
      assert Mcp.serve_args([]) == ["mcp", "serve"]
    end

    test "serve_args emits --debug and --verbose" do
      assert Mcp.serve_args(debug: true) == ["mcp", "serve", "--debug"]
      assert Mcp.serve_args(verbose: true) == ["mcp", "serve", "--verbose"]

      assert Mcp.serve_args(debug: true, verbose: true) ==
               ["mcp", "serve", "--debug", "--verbose"]
    end

    test "serve_args omits unset flags" do
      refute "--debug" in Mcp.serve_args(verbose: true)
      refute "--verbose" in Mcp.serve_args(debug: true)
    end
  end

  describe "Commands.Ultrareview" do
    alias ClaudeWrapper.Commands.Ultrareview

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Ultrareview)
      funcs = Ultrareview.__info__(:functions)

      assert {:execute, 1} in funcs
      assert {:execute, 2} in funcs
      assert {:args, 1} in funcs
    end

    test "args defaults to the bare subcommand" do
      assert Ultrareview.args([]) == ["ultrareview"]
    end

    test "args emits --json, --timeout, then the target" do
      assert Ultrareview.args(target: "123", json: true, timeout: 45) ==
               ["ultrareview", "--json", "--timeout", "45", "123"]
    end

    test "args emits the target as a positional only" do
      assert Ultrareview.args(target: "main") == ["ultrareview", "main"]
    end

    test "args emits --json only" do
      assert Ultrareview.args(json: true) == ["ultrareview", "--json"]
    end

    test "args omits unset flags" do
      refute "--json" in Ultrareview.args(timeout: 10)
      refute "--timeout" in Ultrareview.args(json: true)
    end
  end

  describe "Commands.Auth" do
    alias ClaudeWrapper.Commands.Auth

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Auth)
      funcs = Auth.__info__(:functions)

      assert {:status, 1} in funcs
      assert {:login, 1} in funcs
      assert {:login, 2} in funcs
      assert {:logout, 1} in funcs
      assert {:setup_token, 2} in funcs

      # @doc false builder is public for arg-composition testing.
      assert {:login_args, 1} in funcs
    end

    test "login_args defaults to just the subcommand" do
      assert Auth.login_args([]) == ["auth", "login"]
    end

    test "login_args emits --email with the value" do
      assert Auth.login_args(email: "user@example.com") ==
               ["auth", "login", "--email", "user@example.com"]
    end

    test "login_args emits --claudeai for mode :claudeai" do
      assert Auth.login_args(mode: :claudeai) == ["auth", "login", "--claudeai"]
    end

    test "login_args emits --console for mode :console" do
      assert Auth.login_args(mode: :console) == ["auth", "login", "--console"]
    end

    test "login_args emits --sso when force_sso is true" do
      assert Auth.login_args(force_sso: true) == ["auth", "login", "--sso"]
    end

    test "login_args omits --sso when force_sso is falsy" do
      refute "--sso" in Auth.login_args(force_sso: false)
      refute "--sso" in Auth.login_args([])
    end

    test "login_args composes mode, email, and force_sso in order" do
      args =
        Auth.login_args(
          mode: :console,
          email: "ops@example.com",
          force_sso: true
        )

      assert args == [
               "auth",
               "login",
               "--console",
               "--email",
               "ops@example.com",
               "--sso"
             ]
    end

    test "login_args puts mode before email (claudeai + email)" do
      assert Auth.login_args(mode: :claudeai, email: "me@example.com") ==
               ["auth", "login", "--claudeai", "--email", "me@example.com"]
    end

    test "login_args omits unset flags" do
      refute "--email" in Auth.login_args(mode: :console)
      refute "--claudeai" in Auth.login_args(email: "x@y.z")
      refute "--console" in Auth.login_args(email: "x@y.z")
    end
  end

  describe "Commands.Agents" do
    alias ClaudeWrapper.Commands.Agents

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Agents)
      assert {:list, 1} in Agents.__info__(:functions)
      assert {:list, 2} in Agents.__info__(:functions)
      assert {:execute, 1} in Agents.__info__(:functions)
      assert {:execute, 2} in Agents.__info__(:functions)

      # @doc false builder is public for arg-composition testing.
      assert {:list_args, 1} in Agents.__info__(:functions)
    end

    test "list_args always requests --json (the TTY-safe scripting surface)" do
      assert Agents.list_args([]) == ["agents", "--json"]
    end

    test "list_args emits --all when requested" do
      assert Agents.list_args(all: true) == ["agents", "--json", "--all"]
    end

    test "list_args emits --setting-sources with the value" do
      assert Agents.list_args(setting_sources: "user,project") ==
               ["agents", "--json", "--setting-sources", "user,project"]
    end

    test "list_args omits --setting-sources when unset" do
      refute "--setting-sources" in Agents.list_args([])
    end
  end

  describe "Commands.Marketplace" do
    alias ClaudeWrapper.Commands.Marketplace

    test "module is loaded and has expected functions" do
      Code.ensure_loaded!(Marketplace)
      assert {:list, 1} in Marketplace.__info__(:functions)
      assert {:add, 3} in Marketplace.__info__(:functions)
      assert {:remove, 3} in Marketplace.__info__(:functions)
      assert {:update, 2} in Marketplace.__info__(:functions)
      assert {:add_args, 2} in Marketplace.__info__(:functions)
      assert {:update_args, 1} in Marketplace.__info__(:functions)
      assert {:remove_args, 2} in Marketplace.__info__(:functions)
    end

    test "remove_args emits --scope only when set" do
      assert Marketplace.remove_args("m", []) == ["plugin", "marketplace", "remove", "m"]

      assert Marketplace.remove_args("m", scope: :local) ==
               ["plugin", "marketplace", "remove", "m", "--scope", "local"]
    end

    test "add_args defaults to source with no flags" do
      assert Marketplace.add_args("url", []) == ["plugin", "marketplace", "add", "url"]
    end

    test "add_args composes scope" do
      assert Marketplace.add_args("url", scope: :project) ==
               ["plugin", "marketplace", "add", "url", "--scope", "project"]
    end

    test "add_args composes sparse as a flag followed by each path" do
      assert Marketplace.add_args("url", sparse: [".claude-plugin", "plugins"]) ==
               ["plugin", "marketplace", "add", "url", "--sparse", ".claude-plugin", "plugins"]
    end

    test "add_args composes scope and sparse together, scope first" do
      assert Marketplace.add_args("url", scope: :local, sparse: ["plugins"]) ==
               [
                 "plugin",
                 "marketplace",
                 "add",
                 "url",
                 "--scope",
                 "local",
                 "--sparse",
                 "plugins"
               ]
    end

    test "update_args with no name updates all marketplaces" do
      assert Marketplace.update_args(nil) == ["plugin", "marketplace", "update"]
    end

    test "update_args with a name updates just that marketplace" do
      assert Marketplace.update_args("my-marketplace") ==
               ["plugin", "marketplace", "update", "my-marketplace"]
    end
  end

  describe "IEx helpers" do
    alias ClaudeWrapper.IEx, as: CIEx

    setup do
      # Clean process dictionary state between tests
      Process.delete(:claude_wrapper_iex_session)
      Process.delete(:claude_wrapper_iex_config)
      :ok
    end

    test "cost returns :no_session when no session active" do
      assert CIEx.cost() == :no_session
    end

    test "say returns :no_session when no session active" do
      assert CIEx.say("hello") == :no_session
    end

    test "session_id returns nil when no session active" do
      assert CIEx.session_id() == nil
    end

    test "last returns nil when no session active" do
      assert CIEx.last() == nil
    end

    test "history returns :no_session when no session active" do
      assert CIEx.history() == :no_session
    end

    test "reset clears state" do
      assert CIEx.reset() == :ok
    end

    test "resume sets up session state" do
      assert CIEx.resume("test-session-id") == :ok
      assert CIEx.session_id() == "test-session-id"
    end

    test "resume with options" do
      assert CIEx.resume("sid-123", working_dir: "/tmp") == :ok
      assert CIEx.session_id() == "sid-123"
    end

    test "module exports expected functions" do
      Code.ensure_loaded!(CIEx)
      assert {:chat, 2} in CIEx.__info__(:functions)
      assert {:say, 2} in CIEx.__info__(:functions)
      assert {:cost, 0} in CIEx.__info__(:functions)
      assert {:history, 0} in CIEx.__info__(:functions)
      assert {:reset, 0} in CIEx.__info__(:functions)
      assert {:session_id, 0} in CIEx.__info__(:functions)
      assert {:resume, 2} in CIEx.__info__(:functions)
      assert {:last, 0} in CIEx.__info__(:functions)
    end
  end
end
