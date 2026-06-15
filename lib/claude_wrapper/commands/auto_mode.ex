defmodule ClaudeWrapper.Commands.AutoMode do
  @moduledoc """
  Auto-mode classifier inspection commands.

  Wraps `claude auto-mode config|defaults|critique`, which expose the
  auto-mode classifier configuration the CLI uses to decide which actions
  it can take without prompting.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Print the effective config (your settings merged over defaults), as JSON
      {:ok, json} = ClaudeWrapper.Commands.AutoMode.config(config)

      # Print the default environment/allow/soft_deny/hard_deny rules, as JSON
      {:ok, json} = ClaudeWrapper.Commands.AutoMode.defaults(config)

      # Get AI feedback on your custom auto-mode rules (free-form text)
      {:ok, feedback} = ClaudeWrapper.Commands.AutoMode.critique(config)

      # Override the model used for the critique
      {:ok, feedback} = ClaudeWrapper.Commands.AutoMode.critique(config, model: "opus")
  """

  alias ClaudeWrapper.Config

  @doc """
  Print the effective auto-mode config as JSON.

  Emits your settings where set and defaults otherwise, merged. The string
  is returned verbatim (trimmed); decode it with `Jason.decode/1` if you
  need the structured form.
  """
  @spec config(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def config(%Config{} = config) do
    args = Config.base_args(config) ++ config_args()

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc false
  @spec config_args() :: [String.t()]
  def config_args, do: ["auto-mode", "config"]

  @doc """
  Print the default auto-mode environment, allow, soft_deny, and hard_deny
  rules as JSON.

  Useful as a reference when writing custom rules. The soft/hard deny split
  distinguishes "warn but allow when explicitly overridden" from "always
  block."
  """
  @spec defaults(Config.t()) :: {:ok, String.t()} | {:error, term()}
  def defaults(%Config{} = config) do
    args = Config.base_args(config) ++ defaults_args()

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc false
  @spec defaults_args() :: [String.t()]
  def defaults_args, do: ["auto-mode", "defaults"]

  @doc """
  Get AI feedback on your custom auto-mode rules.

  Output is free-form text.

  ## Options

    * `:model` - Override which model is used for the critique (`--model`).
      Without one the CLI picks its default.
  """
  @spec critique(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def critique(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ critique_args(opts)

    case System.cmd(config.binary, args, Config.cmd_opts(config)) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, {:exit, code, output}}
    end
  end

  @doc false
  @spec critique_args(keyword()) :: [String.t()]
  def critique_args(opts) do
    ["auto-mode", "critique"] ++ value_flag(opts[:model], "--model")
  end

  defp value_flag(nil, _flag), do: []
  defp value_flag(value, flag), do: [flag, to_string(value)]
end
