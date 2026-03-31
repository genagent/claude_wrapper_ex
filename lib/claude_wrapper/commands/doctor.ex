defmodule ClaudeWrapper.Commands.Doctor do
  @moduledoc """
  `claude doctor` command — checks CLI health.
  """

  alias ClaudeWrapper.Config

  @doc """
  Run `claude doctor` and return the output.
  """
  @spec execute(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def execute(%Config{} = config) do
    args = Config.base_args(config) ++ ["doctor"]

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end
end
