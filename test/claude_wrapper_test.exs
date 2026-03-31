defmodule ClaudeWrapperTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Query, Result, StreamEvent}

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
end
