defmodule ClaudeWrapper.Commands.Agents do
  @moduledoc """
  `claude agents` command -- lists configured agents.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Parsed list of agent names and models
      {:ok, agents} = ClaudeWrapper.Commands.Agents.list(config)

      # Raw CLI output
      {:ok, output} = ClaudeWrapper.Commands.Agents.execute(config)

      # Restrict which setting sources are loaded
      {:ok, agents} = ClaudeWrapper.Commands.Agents.list(config, setting_sources: "user,project")
  """

  alias ClaudeWrapper.{Config, Error}

  @type agent :: %{
          name: String.t(),
          model: String.t()
        }

  @doc """
  Run `claude agents` and return the parsed agent list.

  ## Options

    * `:setting_sources` - comma-separated setting sources to load
      (e.g. `"user,project"`)

  ## Examples

      {:ok, agents} = ClaudeWrapper.Commands.Agents.list(config)
      # => {:ok, [%{name: "Explore", model: "haiku"}, ...]}

  """
  @spec list(Config.t(), keyword()) :: {:ok, [agent()]} | {:error, term()}
  def list(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ list_args(opts)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, parse_agents(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc """
  Run `claude agents` and return the raw output string.
  """
  @spec execute(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ list_args(opts)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec list_args(keyword()) :: [String.t()]
  def list_args(opts) do
    case Keyword.get(opts, :setting_sources) do
      nil -> ["agents"]
      sources -> ["agents", "--setting-sources", sources]
    end
  end

  defp parse_agents(output) do
    output
    |> String.split("\n")
    |> Enum.reduce([], fn line, acc ->
      line = String.trim(line)

      case Regex.run(~r/^(.+?)\s+·\s+(.+)$/, line) do
        [_, name, model] -> [%{name: String.trim(name), model: String.trim(model)} | acc]
        _ -> acc
      end
    end)
    |> Enum.reverse()
  end
end
