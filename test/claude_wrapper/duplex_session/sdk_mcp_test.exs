defmodule ClaudeWrapper.DuplexSession.SdkMcpTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.DuplexSession.SdkMcp

  @schema %{"type" => "object", "properties" => %{"text" => %{"type" => "string"}}}

  defp server(call) do
    SdkMcp.tool_server(
      "app",
      [%{name: "echo", description: "Echo", input_schema: @schema, call: call}],
      version: "1.2.3"
    )
  end

  defp call(server, id, method, params \\ nil) do
    msg = %{"jsonrpc" => "2.0", "id" => id, "method" => method}
    server.(if params, do: Map.put(msg, "params", params), else: msg)
  end

  test "initialize echoes the protocol version and reports tools capability" do
    assert %{
             "id" => 0,
             "result" => %{
               "protocolVersion" => "2025-11-25",
               "capabilities" => %{"tools" => %{}},
               "serverInfo" => %{"name" => "app", "version" => "1.2.3"}
             }
           } = call(server(&{:ok, &1}), 0, "initialize", %{"protocolVersion" => "2025-11-25"})
  end

  test "tools/list describes each tool" do
    assert %{"id" => 1, "result" => %{"tools" => [tool]}} =
             call(server(&{:ok, &1}), 1, "tools/list")

    assert tool == %{"name" => "echo", "description" => "Echo", "inputSchema" => @schema}
  end

  test "tools/call returns text, content lists, and tool errors" do
    params = %{"name" => "echo", "arguments" => %{"text" => "hi"}}

    assert %{"result" => %{"content" => [%{"type" => "text", "text" => "hi"}]}} =
             call(server(fn %{"text" => t} -> {:ok, t} end), 2, "tools/call", params)

    blocks = [%{"type" => "text", "text" => "a"}, %{"type" => "text", "text" => "b"}]

    assert %{"result" => %{"content" => ^blocks}} =
             call(server(fn _ -> {:ok, blocks} end), 3, "tools/call", params)

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "nope"}]}} =
             call(server(fn _ -> {:error, "nope"} end), 4, "tools/call", params)

    assert %{"result" => %{"isError" => true, "content" => [%{"text" => "boom"}]}} =
             call(server(fn _ -> raise "boom" end), 5, "tools/call", params)
  end

  test "an unknown tool and an unknown method are JSON-RPC errors" do
    s = server(&{:ok, &1})

    assert %{"id" => 6, "error" => %{"code" => -32_602}} =
             call(s, 6, "tools/call", %{"name" => "missing"})

    assert %{"id" => 7, "error" => %{"code" => -32_601}} = call(s, 7, "resources/list")
  end

  test "ping answers and notifications return nil" do
    s = server(&{:ok, &1})
    assert %{"id" => 8, "result" => %{}} = call(s, 8, "ping")
    assert s.(%{"jsonrpc" => "2.0", "method" => "notifications/initialized"}) == nil
  end
end
