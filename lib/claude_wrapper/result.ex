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
end
