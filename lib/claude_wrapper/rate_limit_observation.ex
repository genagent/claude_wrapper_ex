defmodule ClaudeWrapper.RateLimitObservation do
  @moduledoc """
  Rate-limit evidence from a `rate_limit_event`.

  `ClaudeWrapper.Query.execute/3` sends `{reference, observation}` to the
  configured local observer as the CLI writes the event to stdout, and a
  `ClaudeWrapper.DuplexSession` broadcasts `{:rate_limit, observation}` to
  its subscribers. This is
  provider-reported state at that point in the run, not proof of completion or
  a durable usage snapshot. Callers must correlate the reference with their
  current invocation and decide how long the observation remains fresh.
  """

  @type t :: %__MODULE__{
          status: String.t(),
          rate_limit_type: String.t() | nil,
          unified_windows: map(),
          source: :rate_limit_event
        }

  @enforce_keys [:status]
  defstruct [:status, :rate_limit_type, unified_windows: %{}, source: :rate_limit_event]

  @doc """
  Build an observation from a decoded `rate_limit_event` frame, or `:error`
  when the frame has no non-empty `rate_limit_info.status`.
  """
  @spec from_event(map()) :: {:ok, t()} | :error
  def from_event(%{"rate_limit_info" => %{"status" => status} = info})
      when is_binary(status) and byte_size(status) > 0 do
    {:ok,
     %__MODULE__{
       status: status,
       rate_limit_type: string_or_nil(info["rateLimitType"]),
       unified_windows: map_or_empty(info["unifiedWindows"])
     }}
  end

  def from_event(_event), do: :error

  defp string_or_nil(value) when is_binary(value), do: value
  defp string_or_nil(_value), do: nil

  defp map_or_empty(value) when is_map(value), do: value
  defp map_or_empty(_value), do: %{}
end
