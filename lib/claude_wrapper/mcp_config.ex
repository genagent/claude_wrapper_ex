defmodule ClaudeWrapper.McpConfig do
  @moduledoc """
  Programmatic builder for `.mcp.json` configuration files.

  Builds the JSON structure that the Claude CLI expects for MCP server
  configuration, then writes it to disk or returns it as a string.

  ## Usage

      ClaudeWrapper.McpConfig.new()
      |> ClaudeWrapper.McpConfig.add_stdio("my-server", "npx", ["-y", "my-mcp-server"],
        env: %{"API_KEY" => "sk-..."}
      )
      |> ClaudeWrapper.McpConfig.add_sse("remote", "https://example.com/mcp")
      |> ClaudeWrapper.McpConfig.write!("/path/to/project/.mcp.json")

  ## Format

  The generated JSON follows the Claude CLI's expected format:

      {
        "mcpServers": {
          "server-name": {
            "type": "stdio",
            "command": "npx",
            "args": ["-y", "server-pkg"],
            "env": {"KEY": "value"}
          }
        }
      }
  """

  @type server :: %{
          type: String.t(),
          command: String.t() | nil,
          args: [String.t()],
          env: %{String.t() => String.t()},
          url: String.t() | nil
        }

  @type t :: %__MODULE__{
          servers: %{String.t() => server()}
        }

  defstruct servers: %{}

  @doc """
  Create a new empty MCP config.
  """
  @spec new() :: t()
  def new, do: %__MODULE__{}

  @doc """
  Add a stdio-based MCP server.

  ## Options

    * `:env` - Map of environment variables
  """
  @spec add_stdio(t(), String.t(), String.t(), [String.t()], keyword()) :: t()
  def add_stdio(%__MODULE__{} = config, name, command, args \\ [], opts \\ []) do
    server = %{
      type: "stdio",
      command: command,
      args: args,
      env: opts[:env] || %{}
    }

    %{config | servers: Map.put(config.servers, name, server)}
  end

  @doc """
  Add an SSE-based MCP server.

  ## Options

    * `:env` - Map of environment variables
  """
  @spec add_sse(t(), String.t(), String.t(), keyword()) :: t()
  def add_sse(%__MODULE__{} = config, name, url, opts \\ []) do
    server = %{
      type: "sse",
      url: url,
      env: opts[:env] || %{}
    }

    %{config | servers: Map.put(config.servers, name, server)}
  end

  @doc """
  Remove a server by name.
  """
  @spec remove(t(), String.t()) :: t()
  def remove(%__MODULE__{} = config, name) do
    %{config | servers: Map.delete(config.servers, name)}
  end

  @doc """
  List server names.
  """
  @spec server_names(t()) :: [String.t()]
  def server_names(%__MODULE__{servers: servers}), do: Map.keys(servers)

  @doc """
  Get a server definition by name.
  """
  @spec get_server(t(), String.t()) :: server() | nil
  def get_server(%__MODULE__{servers: servers}, name), do: Map.get(servers, name)

  @doc """
  Encode to the JSON string the CLI expects.
  """
  @spec to_json(t()) :: String.t()
  def to_json(%__MODULE__{} = config) do
    payload = %{"mcpServers" => encode_servers(config.servers)}
    Jason.encode!(payload, pretty: true)
  end

  @doc """
  Write the config to a file.
  """
  @spec write!(t(), String.t()) :: :ok
  def write!(%__MODULE__{} = config, path) do
    File.write!(path, to_json(config))
  end

  @doc """
  Read and parse an existing `.mcp.json` file.

  Returns `{:error, %ClaudeWrapper.Error{kind: :io}}` when the file
  cannot be read and `{:error, %ClaudeWrapper.Error{kind: :json}}` when
  its contents are not valid JSON.
  """
  @spec read(String.t()) :: {:ok, t()} | {:error, ClaudeWrapper.Error.t()}
  def read(path) do
    with {:ok, content} <- read_file(path),
         {:ok, data} <- decode_json(content) do
      {:ok, from_map(data)}
    end
  end

  defp read_file(path) do
    case File.read(path) do
      {:ok, content} -> {:ok, content}
      {:error, reason} -> {:error, ClaudeWrapper.Error.io(reason)}
    end
  end

  defp decode_json(content) do
    case Jason.decode(content) do
      {:ok, data} -> {:ok, data}
      {:error, reason} -> {:error, ClaudeWrapper.Error.json(reason)}
    end
  end

  @doc """
  Parse from a decoded JSON map.
  """
  @spec from_map(map()) :: t()
  def from_map(data) when is_map(data) do
    raw_servers = data["mcpServers"] || %{}

    servers =
      Map.new(raw_servers, fn {name, def_map} ->
        server = %{
          type: def_map["type"] || "stdio",
          command: def_map["command"],
          args: def_map["args"] || [],
          env: def_map["env"] || %{},
          url: def_map["url"]
        }

        {name, server}
      end)

    %__MODULE__{servers: servers}
  end

  # --- Private ---

  defp encode_servers(servers) do
    Map.new(servers, fn {name, server} -> {name, encode_server(server)} end)
  end

  defp encode_server(%{type: "stdio"} = server) do
    %{"type" => "stdio", "command" => server.command, "args" => server.args}
    |> maybe_add_env(server.env)
  end

  defp encode_server(%{type: "sse"} = server) do
    %{"type" => "sse", "url" => server.url}
    |> maybe_add_env(server.env)
  end

  defp encode_server(%{type: type}), do: %{"type" => type}

  defp maybe_add_env(map, env) when env == %{}, do: map
  defp maybe_add_env(map, env), do: Map.put(map, "env", env)
end
