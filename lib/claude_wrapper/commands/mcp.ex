defmodule ClaudeWrapper.Commands.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server management commands.

  Wraps `claude mcp add|add-json|add-from-claude-desktop|remove|list|get|serve|login|logout|reset-project-choices`.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # List / inspect configured servers (raw text; the CLI has no JSON mode)
      {:ok, servers_text} = ClaudeWrapper.Commands.Mcp.list(config)
      {:ok, server_text} = ClaudeWrapper.Commands.Mcp.get(config, "sentry")

      # Add an HTTP server with an auth header
      {:ok, _} =
        ClaudeWrapper.Commands.Mcp.add(config, "sentry", "https://mcp.sentry.dev/mcp",
          [],
          transport: :http,
          header: ["Authorization: Bearer abc123"],
          scope: :user
        )

      # Add a stdio server with env vars and subprocess args
      {:ok, _} =
        ClaudeWrapper.Commands.Mcp.add(config, "my-server", "npx", [],
          env: %{"API_KEY" => "xxx"},
          server_args: ["my-mcp-server"]
        )

      # Add from a JSON blob, prompting for the OAuth client secret
      {:ok, _} =
        ClaudeWrapper.Commands.Mcp.add_json(config, "srv", ~s({"command":"npx"}),
          client_secret: true
        )

      # Import from Claude Desktop (Mac and WSL only)
      {:ok, _} = ClaudeWrapper.Commands.Mcp.add_from_desktop(config, nil, scope: :user)

      # Run Claude Code itself as an MCP server
      {:ok, _} = ClaudeWrapper.Commands.Mcp.serve(config, verbose: true)
  """

  alias ClaudeWrapper.{Config, Error}

  @type scope :: :local | :user | :project
  @type transport :: :stdio | :sse | :http

  @doc """
  List configured MCP servers.

  `claude mcp list` emits human-readable text (it has no JSON mode), so
  this returns the raw, trimmed output rather than structured data.

  ## Options

    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`).
  """
  @spec list(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "list"] ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Get details for a specific MCP server.

  `claude mcp get` emits human-readable text (it has no JSON mode), so
  this returns the raw, trimmed output rather than structured data.

  ## Options

    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`).
  """
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def get(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "get", name] ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Add an MCP server.

  `command_or_url` is the stdio command (e.g. `"npx"`) or the server URL for
  HTTP/SSE transports. Trailing `command_args` are passed through as positional
  arguments; prefer `:server_args` (which uses the CLI's `--` separator) for
  flags that would otherwise be parsed by `claude` itself.

  ## Options

    * `:transport` - Transport type (`:stdio`, `:sse`, or `:http`). Emits
      `--transport`. The CLI defaults to stdio when omitted.
    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`). Emits
      `--scope`.
    * `:env` - Environment variables as a map or keyword list. Each pair emits
      `-e KEY=value`.
    * `:header` - WebSocket/HTTP headers for HTTP/SSE transports. Accepts a list
      of `"Key: Value"` strings or a map (each pair rendered `"Key: Value"`).
      Each header emits its own `--header` flag.
    * `:server_args` - Extra arguments for the server command, emitted after a
      `--` separator so `claude` does not interpret them.
    * `:callback_port` - Fixed port for the OAuth callback (`--callback-port`).
    * `:client_id` - OAuth client ID for HTTP/SSE servers (`--client-id`).
    * `:client_secret` - Prompt for the OAuth client secret (`--client-secret`,
      boolean; or set the `MCP_CLIENT_SECRET` env var).
  """
  @spec add(Config.t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, name, command_or_url, command_args \\ [], opts \\ []) do
    args = Config.base_args(config) ++ add_args(name, command_or_url, command_args, opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec add_args(String.t(), String.t(), [String.t()], keyword()) :: [String.t()]
  def add_args(name, command_or_url, command_args, opts) do
    flags =
      transport_args(opts[:transport]) ++
        scope_args(opts[:scope]) ++
        env_args(opts[:env]) ++
        header_args(opts[:header]) ++
        value_flag(opts[:callback_port], "--callback-port") ++
        value_flag(opts[:client_id], "--client-id") ++
        bool_flag(opts[:client_secret], "--client-secret")

    server_args =
      case opts[:server_args] do
        nil -> []
        [] -> []
        list -> ["--" | Enum.map(list, &to_string/1)]
      end

    ["mcp", "add"] ++ flags ++ [name, command_or_url] ++ command_args ++ server_args
  end

  @doc """
  Add an MCP server from a JSON configuration.

  ## Options

    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`). Emits
      `--scope`.
    * `:client_secret` - Prompt for the OAuth client secret (`--client-secret`,
      boolean; or set the `MCP_CLIENT_SECRET` env var).
  """
  @spec add_json(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add_json(%Config{} = config, name, json, opts \\ []) do
    args = Config.base_args(config) ++ add_json_args(name, json, opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec add_json_args(String.t(), String.t(), keyword()) :: [String.t()]
  def add_json_args(name, json, opts) do
    flags =
      scope_args(opts[:scope]) ++
        bool_flag(opts[:client_secret], "--client-secret")

    ["mcp", "add-json"] ++ flags ++ [name, json]
  end

  @doc """
  Import MCP servers from Claude Desktop (Mac and WSL only).

  The installed CLI (`claude mcp add-from-claude-desktop`) takes no name
  argument; `name` is accepted for forward compatibility and appended as a
  positional only when non-nil.

  ## Options

    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`). Emits
      `--scope`.
  """
  @spec add_from_desktop(Config.t(), String.t() | nil, keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add_from_desktop(%Config{} = config, name \\ nil, opts \\ []) do
    args = Config.base_args(config) ++ add_from_desktop_args(name, opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec add_from_desktop_args(String.t() | nil, keyword()) :: [String.t()]
  def add_from_desktop_args(name, opts) do
    positional = if name, do: [name], else: []

    ["mcp", "add-from-claude-desktop"] ++ scope_args(opts[:scope]) ++ positional
  end

  @doc """
  Remove an MCP server.

  ## Options

    * `:scope` - Configuration scope (`:local`, `:user`, or `:project`). When
      omitted the CLI removes the server from whichever scope it exists in.
  """
  @spec remove(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def remove(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "remove", name]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Start the Claude Code MCP server.

  Wraps `claude mcp serve`, which exposes this Claude Code installation as an
  MCP server over stdio.

  ## Options

    * `:debug` - Enable debug mode (`--debug`, boolean).
    * `:verbose` - Override the verbose-mode setting from config (`--verbose`,
      boolean).
  """
  @spec serve(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def serve(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ serve_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec serve_args(keyword()) :: [String.t()]
  def serve_args(opts) do
    flags =
      bool_flag(opts[:debug], "--debug") ++
        bool_flag(opts[:verbose], "--verbose")

    ["mcp", "serve"] ++ flags
  end

  @doc """
  Authenticate with an MCP server (HTTP, SSE, or claude.ai connector).

  Wraps `claude mcp login <name>`.

  ## Options

    * `:no_browser` - Print the authorization URL instead of opening a browser
      (`--no-browser`, boolean), for SSH/headless sessions.
  """
  @spec login(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def login(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ login_args(name, opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec login_args(String.t(), keyword()) :: [String.t()]
  def login_args(name, opts) do
    ["mcp", "login"] ++ bool_flag(opts[:no_browser], "--no-browser") ++ [name]
  end

  @doc """
  Clear stored OAuth credentials for an MCP server.

  Wraps `claude mcp logout <name>`.
  """
  @spec logout(Config.t(), String.t()) :: {:ok, String.t()} | {:error, term()}
  def logout(%Config{} = config, name) do
    args = Config.base_args(config) ++ logout_args(name)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec logout_args(String.t()) :: [String.t()]
  def logout_args(name), do: ["mcp", "logout", name]

  @doc """
  Reset project choices for MCP servers.
  """
  @spec reset_project_choices(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def reset_project_choices(%Config{} = config) do
    args = Config.base_args(config) ++ ["mcp", "reset-project-choices"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  defp transport_args(nil), do: []
  defp transport_args(:stdio), do: ["--transport", "stdio"]
  defp transport_args(:sse), do: ["--transport", "sse"]
  defp transport_args(:http), do: ["--transport", "http"]

  defp env_args(nil), do: []

  defp env_args(env) do
    Enum.flat_map(env, fn {k, v} -> ["-e", "#{k}=#{v}"] end)
  end

  defp header_args(nil), do: []

  defp header_args(headers) when is_map(headers) do
    headers
    |> Enum.flat_map(fn {k, v} -> ["--header", "#{k}: #{v}"] end)
  end

  defp header_args(headers) when is_list(headers) do
    Enum.flat_map(headers, fn header -> ["--header", header] end)
  end

  defp bool_flag(true, flag), do: [flag]
  defp bool_flag(_falsy, _flag), do: []

  defp value_flag(nil, _flag), do: []
  defp value_flag(value, flag), do: [flag, to_string(value)]

  defp scope_args(nil), do: []
  defp scope_args(:local), do: ["--scope", "local"]
  defp scope_args(:user), do: ["--scope", "user"]
  defp scope_args(:project), do: ["--scope", "project"]
end
