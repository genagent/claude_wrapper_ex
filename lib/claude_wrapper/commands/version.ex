defmodule ClaudeWrapper.Commands.Version do
  @moduledoc """
  `claude --version` command.
  """

  alias ClaudeWrapper.Config

  @type version_info :: %{
          version: String.t(),
          raw: String.t()
        }

  @doc """
  Get the CLI version.
  """
  @spec execute(Config.t()) :: {:ok, version_info()} | {:error, term()}
  def execute(%Config{} = config) do
    case System.cmd(config.binary, ["--version"], Config.cmd_opts(config)) do
      {output, 0} ->
        raw = String.trim(output)
        {:ok, %{version: raw, raw: raw}}

      {output, code} ->
        {:error, {:exit, code, output}}
    end
  end
end
