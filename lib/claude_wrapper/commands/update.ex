defmodule ClaudeWrapper.Commands.Update do
  @moduledoc """
  Check for CLI updates and install if available.

  Wraps `claude update` (CLI alias `upgrade`). Takes no options.

  > #### Mutating command {: .warning}
  >
  > `update/1` runs `claude update`, which installs a newer build when one is
  > available, mutating the local installation. Call it deliberately.

  ## Usage

      config = ClaudeWrapper.Config.new()
      {:ok, output} = ClaudeWrapper.Commands.Update.update(config)
  """

  alias ClaudeWrapper.Config

  @doc """
  Check for updates and install if available.

  Returns the CLI's output on success.
  """
  @spec update(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def update(%Config{} = config) do
    args = Config.base_args(config) ++ update_args()

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc false
  @spec update_args() :: [String.t()]
  def update_args, do: ["update"]
end
