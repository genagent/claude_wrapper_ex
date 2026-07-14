defmodule ClaudeWrapper.Commands.Ultrareview do
  @moduledoc """
  `claude ultrareview` -- cloud-hosted multi-agent code review.

  Runs a cloud-hosted multi-agent code review and returns the findings.
  With no target, reviews the current branch; pass a PR number/URL or a
  base branch name to review that instead.

  The review runs in the cloud and can take many minutes. The CLI's own
  `--timeout` (default 30 minutes) bounds how long it waits for the review
  to finish; size any surrounding timeout to at least that value.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Review the current branch
      {:ok, findings} = ClaudeWrapper.Commands.Ultrareview.execute(config)

      # Review PR 123, raw JSON payload, wait up to 45 minutes
      {:ok, json} =
        ClaudeWrapper.Commands.Ultrareview.execute(config,
          target: "123",
          json: true,
          timeout: 45
        )
  """

  alias ClaudeWrapper.{Config, Error}

  @doc """
  Run `claude ultrareview` and return the output.

  ## Options

    * `:target` - Review a PR number/URL or a base branch name instead of
      the current branch (positional argument).
    * `:json` - Print the raw `bugs.json` payload instead of formatted
      findings (`--json`, boolean).
    * `:timeout` - Maximum minutes to wait for the review to finish
      (`--timeout`). The CLI default is 30.
  """
  @spec execute(Config.t(), keyword()) :: {:ok, String.t()} | {:error, term()}
  def execute(%Config{} = config, opts \\ []) do
    args = Config.base_args(config) ++ args(opts)

    case Config.exec(config, args) do
      {output, 0} -> {:ok, String.trim(output)}
      {output, code} -> {:error, Error.command_failed(code, output)}
    end
  end

  @doc false
  @spec args(keyword()) :: [String.t()]
  def args(opts) do
    flags =
      bool_flag(opts[:json], "--json") ++
        value_flag(opts[:timeout], "--timeout")

    positional = if opts[:target], do: [to_string(opts[:target])], else: []

    ["ultrareview"] ++ flags ++ positional
  end

  defp bool_flag(true, flag), do: [flag]
  defp bool_flag(_falsy, _flag), do: []

  defp value_flag(nil, _flag), do: []
  defp value_flag(value, flag), do: [flag, to_string(value)]
end
