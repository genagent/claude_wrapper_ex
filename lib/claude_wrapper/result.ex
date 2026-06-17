defmodule ClaudeWrapper.Result do
  @moduledoc """
  Result from a completed query execution.

  Maps to the Rust `QueryResult` -- the parsed JSON output from
  `--output-format json`.
  """

  @type t :: %__MODULE__{
          result: String.t(),
          session_id: String.t() | nil,
          cost_usd: float() | nil,
          duration_ms: non_neg_integer() | nil,
          num_turns: non_neg_integer() | nil,
          is_error: boolean(),
          extra: map()
        }

  @typedoc """
  Normalized token usage from `usage/1`. `total` is throughput
  (`input + output + cache_creation`) and excludes cache reads.
  """
  @type usage :: %{
          input: non_neg_integer(),
          output: non_neg_integer(),
          cache_creation: non_neg_integer(),
          cache_read: non_neg_integer(),
          total: non_neg_integer()
        }

  defstruct [
    :result,
    :session_id,
    :cost_usd,
    :duration_ms,
    :num_turns,
    is_error: false,
    extra: %{}
  ]

  @doc """
  Parse a result from the JSON output of a query command.
  """
  @spec from_json(map()) :: t()
  def from_json(data) when is_map(data) do
    %__MODULE__{
      result: data["result"] || "",
      session_id: data["session_id"],
      cost_usd: data["total_cost_usd"] || data["cost_usd"],
      duration_ms: data["duration_ms"],
      num_turns: data["num_turns"],
      is_error: data["is_error"] || false,
      extra:
        Map.drop(data, [
          "result",
          "session_id",
          "cost_usd",
          "total_cost_usd",
          "duration_ms",
          "num_turns",
          "is_error"
        ])
    }
  end

  @doc """
  Token usage for the turn, read from `extra["usage"]`.

  Returns `nil` when the result carries no usage (e.g. some error
  results). `total` is `input + output + cache_creation` -- it **excludes**
  cache reads, which re-count context already tallied when it was first
  cached (consistent with `ClaudeWrapper.History.SessionSummary`'s
  `total_tokens`).

      iex> ClaudeWrapper.Result.usage(%ClaudeWrapper.Result{result: "", extra: %{}})
      nil
  """
  @spec usage(t()) :: usage() | nil
  def usage(%__MODULE__{extra: extra}) do
    case extra["usage"] do
      %{} = u -> build_usage(u)
      _ -> nil
    end
  end

  @doc """
  The turn's stop reason (e.g. `"end_turn"`, `"max_tokens"`), read from
  `extra["stop_reason"]`. Returns `nil` when absent.
  """
  @spec stop_reason(t()) :: String.t() | nil
  def stop_reason(%__MODULE__{extra: extra}) do
    case extra["stop_reason"] do
      reason when is_binary(reason) -> reason
      _ -> nil
    end
  end

  @doc """
  The schema-validated structured output, read from
  `extra["structured_output"]`.

  Present (a JSON object or array) when the turn ran with a JSON schema
  (claude's `--json-schema`); `nil` otherwise.
  """
  @spec structured_output(t()) :: map() | list() | nil
  def structured_output(%__MODULE__{extra: extra}) do
    case extra["structured_output"] do
      %{} = output -> output
      output when is_list(output) -> output
      _ -> nil
    end
  end

  # Sum a usage map into the normalized shape. Missing / non-integer fields
  # count as 0; `total` excludes cache reads (see usage/1).
  defp build_usage(u) do
    input = int(u["input_tokens"])
    output = int(u["output_tokens"])
    cache_creation = int(u["cache_creation_input_tokens"])
    cache_read = int(u["cache_read_input_tokens"])

    %{
      input: input,
      output: output,
      cache_creation: cache_creation,
      cache_read: cache_read,
      total: input + output + cache_creation
    }
  end

  defp int(n) when is_integer(n), do: n
  defp int(_), do: 0
end
