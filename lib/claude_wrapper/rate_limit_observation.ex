defmodule ClaudeWrapper.RateLimitObservation do
  @moduledoc """
  Rate-limit evidence from a `rate_limit_event` during observed one-shot execution.

  `ClaudeWrapper.Query.execute/3` sends `{reference, observation}` to the
  configured local observer as the CLI writes the event to stdout. This is
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
end
