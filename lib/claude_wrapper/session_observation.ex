defmodule ClaudeWrapper.SessionObservation do
  @moduledoc """
  A native session identity announced during observed one-shot execution.

  `ClaudeWrapper.Query.execute/3` sends `{reference, observation}` to the
  configured local observer after the first valid stdout `system/init` event.
  This is evidence of a session identity, not successful completion. Callers
  own persistence and must correlate the reference with the invocation that
  is still allowed to update their state.
  """

  @type t :: %__MODULE__{session_id: String.t(), source: :system_init}

  @enforce_keys [:session_id]
  defstruct [:session_id, source: :system_init]
end
