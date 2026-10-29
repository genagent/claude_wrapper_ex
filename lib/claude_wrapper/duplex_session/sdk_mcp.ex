defmodule ClaudeWrapper.DuplexSession.SdkMcp do
  @moduledoc """
  Build an in-process MCP tool server for `DuplexSession`'s
  `:sdk_mcp_servers` option.

  A server there is any `(json_rpc_message -> json_rpc_response | nil)`
  function. `tool_server/2` builds one that answers `initialize`,
  `tools/list` and `tools/call` for a list of tools, with no MCP library
  dependency. Write the handler by hand instead when you need more of the
  protocol (resources, prompts, progress).

      echo = %{
        name: "echo",
        description: "Echo the given text",
        input_schema: %{
          "type" => "object",
          "properties" => %{"text" => %{"type" => "string"}},
          "required" => ["text"]
        },
        call: fn %{"text" => text} -> {:ok, text} end
      }

      {:ok, pid} =
        ClaudeWrapper.DuplexSession.start_link(
          config: config,
          sdk_mcp_servers: %{"app" => SdkMcp.tool_server("app", [echo])}
        )

  The CLI names the tool `mcp__app__echo`; allow it like any MCP tool.

  A tool's `:call` function receives the decoded arguments map and returns
  `{:ok, text}`, `{:ok, content}` (a list of MCP content blocks), or
  `{:error, text}`, which is reported to the model as a tool error. It runs
  in its own process, so it may block; a raise is reported as a tool error.
  """

  @typedoc "A tool definition for `tool_server/2`."
  @type tool :: %{
          required(:name) => String.t(),
          required(:input_schema) => map(),
          required(:call) => (map() -> {:ok, String.t() | [map()]} | {:error, String.t()}),
          optional(:description) => String.t()
        }

  @doc """
  Return a `:sdk_mcp_servers` handler serving `tools` under `name`.

  Options: `:version` (default `"0.0.0"`) is reported as the server version.
  """
  @spec tool_server(String.t(), [tool()], keyword()) :: (map() -> map() | nil)
  def tool_server(name, tools, opts \\ []) when is_binary(name) and is_list(tools) do
    by_name = Map.new(tools, fn %{name: tool_name} = tool -> {tool_name, tool} end)
    info = %{"name" => name, "version" => Keyword.get(opts, :version, "0.0.0")}

    fn message -> handle(message, by_name, info) end
  end

  defp handle(%{"method" => "initialize", "id" => id} = msg, _tools, info) do
    version = get_in(msg, ["params", "protocolVersion"]) || "2025-06-18"

    result(id, %{
      "protocolVersion" => version,
      "capabilities" => %{"tools" => %{}},
      "serverInfo" => info
    })
  end

  defp handle(%{"method" => "tools/list", "id" => id}, tools, _info) do
    listed =
      Enum.map(tools, fn {name, tool} ->
        %{
          "name" => name,
          "description" => Map.get(tool, :description, ""),
          "inputSchema" => tool.input_schema
        }
      end)

    result(id, %{"tools" => listed})
  end

  defp handle(%{"method" => "tools/call", "id" => id, "params" => params}, tools, _info) do
    case Map.fetch(tools, params["name"]) do
      {:ok, tool} -> result(id, call_tool(tool, params["arguments"] || %{}))
      :error -> error(id, -32_602, "Unknown tool: #{params["name"]}")
    end
  end

  defp handle(%{"method" => "ping", "id" => id}, _tools, _info), do: result(id, %{})

  # Notifications (no id) need no response.
  defp handle(%{"method" => _} = msg, _tools, _info) when not is_map_key(msg, "id"), do: nil

  defp handle(%{"method" => method, "id" => id}, _tools, _info),
    do: error(id, -32_601, "Method not found: #{method}")

  defp call_tool(tool, arguments) do
    case tool.call.(arguments) do
      {:ok, text} when is_binary(text) -> %{"content" => [text_block(text)]}
      {:ok, content} when is_list(content) -> %{"content" => content}
      {:error, text} -> %{"content" => [text_block(to_string(text))], "isError" => true}
    end
  rescue
    e -> %{"content" => [text_block(Exception.message(e))], "isError" => true}
  end

  defp text_block(text), do: %{"type" => "text", "text" => text}

  defp result(id, result), do: %{"jsonrpc" => "2.0", "id" => id, "result" => result}

  defp error(id, code, message),
    do: %{"jsonrpc" => "2.0", "id" => id, "error" => %{"code" => code, "message" => message}}
end
