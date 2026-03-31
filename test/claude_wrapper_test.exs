defmodule ClaudeWrapperTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, McpConfig, Query, Result, Retry, Session, StreamEvent}

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
      assert {:error, {:json_decode, _}} = StreamEvent.parse("not json")
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
  end
end
