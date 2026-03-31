defmodule ClaudeWrapper.Commands.Mcp do
  @moduledoc """
  MCP (Model Context Protocol) server management commands.

  Wraps `claude mcp add|remove|list|get|serve|reset-project-choices`.
  """

  alias ClaudeWrapper.Config

  @type scope :: :local | :user | :project

  @doc """
  List configured MCP servers.
  """
  @spec list(Config.t(), keyword()) :: {:ok, list(map())} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "list"]
    args = args ++ scope_args(opts[:scope])
    args = args ++ ["--output-format", "json"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Get details for a specific MCP server.
  """
  @spec get(Config.t(), String.t(), keyword()) :: {:ok, map()} | {:error, term()}
  def get(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "get", name]
    args = args ++ scope_args(opts[:scope])
    args = args ++ ["--output-format", "json"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} ->
        case Jason.decode(output) do
          {:ok, data} -> {:ok, data}
          {:error, reason} -> {:error, {:json_decode, reason}}
        end

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end

  @doc """
  Add a stdio MCP server.
  """
  @spec add(Config.t(), String.t(), String.t(), [String.t()], keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add(%Config{} = config, name, command, command_args \\ [], opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "add", name, command] ++ command_args
    args = args ++ scope_args(opts[:scope])
    args = if opts[:env], do: args ++ Enum.flat_map(opts[:env], fn {k, v} -> ["-e", "#{k}=#{v}"] end), else: args

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Add an MCP server from a JSON configuration.
  """
  @spec add_json(Config.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, term()}
  def add_json(%Config{} = config, name, json, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "add-json", name, json]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Remove an MCP server.
  """
  @spec remove(Config.t(), String.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def remove(%Config{} = config, name, opts \\ []) do
    args = Config.base_args(config) ++ ["mcp", "remove", name]
    args = args ++ scope_args(opts[:scope])

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc """
  Reset project choices for MCP servers.
  """
  @spec reset_project_choices(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def reset_project_choices(%Config{} = config) do
    args = Config.base_args(config) ++ ["mcp", "reset-project-choices"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  defp scope_args(nil), do: []
  defp scope_args(:local), do: ["--scope", "local"]
  defp scope_args(:user), do: ["--scope", "user"]
  defp scope_args(:project), do: ["--scope", "project"]
end
