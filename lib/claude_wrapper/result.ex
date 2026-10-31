defmodule ClaudeWrapper.Result do
  @moduledoc """
  Result from a completed query execution.

  Maps to the Rust `QueryResult` -- the parsed JSON output from
  `--output-format json`.

  ## Cost

  `cost_usd` is the CLI's running total for the session, not the cost of
  this turn alone: in a duplex session, and on a turn that resumes an
  existing session id, each result already includes the cost of earlier
  turns (a resumed session continues from the total its transcript
  saved). Read the latest result for a session's total rather than adding
  results up. `turn_cost/2`, `turn_costs/1` and `total_cost/1` derive
  per-turn and overall costs from a sequence of results.

  Token `usage/1` is per turn, so token counts can be added across turns.
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

  @doc """
  The cost of `result`'s turn alone, given the `previous` result of the
  same conversation (the last one that carried a cost), or `nil` for the
  first.

  When both results belong to the same session and the running total did
  not go down, this is the difference between the two totals. Otherwise
  (no previous result, a different session id, or a total that went
  down) it is `result.cost_usd` itself. Returns `nil` when `result`
  carries no cost.

      iex> alias ClaudeWrapper.Result
      iex> first = %Result{result: "", session_id: "s", cost_usd: 0.25}
      iex> second = %Result{result: "", session_id: "s", cost_usd: 0.75}
      iex> Result.turn_cost(second, first)
      0.5
      iex> Result.turn_cost(first, nil)
      0.25
  """
  @spec turn_cost(t(), t() | nil) :: float() | nil
  def turn_cost(%__MODULE__{cost_usd: nil}, _previous), do: nil

  def turn_cost(%__MODULE__{cost_usd: cost} = result, previous) do
    if continues?(result, previous), do: cost - previous.cost_usd, else: cost
  end

  @doc """
  The per-turn cost of each result in `results` (in order), as
  `turn_cost/2` computes it against the last earlier result that carried
  a cost. Results with no cost map to `nil`.

      iex> alias ClaudeWrapper.Result
      iex> results = for total <- [0.25, 0.5, 1.0], do: %Result{result: "", session_id: "s", cost_usd: total}
      iex> Result.turn_costs(results)
      [0.25, 0.25, 0.5]
  """
  @spec turn_costs([t()]) :: [float() | nil]
  def turn_costs(results) when is_list(results) do
    {costs, _last} =
      Enum.map_reduce(results, nil, fn result, previous ->
        {turn_cost(result, previous), if(result.cost_usd, do: result, else: previous)}
      end)

    costs
  end

  @doc """
  The total cost of the turns in `results`, in USD.

  For results from one session this is the latest running total. When the
  session id changes, or the total goes down, the previous session's last
  total is kept and the new one is added. Results with no cost are
  skipped; an empty list is `0.0`.

      iex> alias ClaudeWrapper.Result
      iex> results = for total <- [0.25, 0.5, 1.0], do: %Result{result: "", session_id: "s", cost_usd: total}
      iex> Result.total_cost(results)
      1.0
  """
  @spec total_cost([t()]) :: float()
  def total_cost(results) when is_list(results) do
    {sum, last} =
      Enum.reduce(results, {0.0, nil}, fn
        %__MODULE__{cost_usd: nil}, acc ->
          acc

        result, {sum, previous} ->
          if continues?(result, previous) or previous == nil,
            do: {sum, result},
            else: {sum + previous.cost_usd, result}
      end)

    sum + ((last && last.cost_usd) || 0.0) + 0.0
  end

  defp continues?(%__MODULE__{session_id: sid, cost_usd: cost}, %__MODULE__{
         session_id: sid,
         cost_usd: previous
       })
       when is_number(cost) and is_number(previous) and cost >= previous,
       do: true

  defp continues?(_result, _previous), do: false

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
