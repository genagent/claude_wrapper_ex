defmodule ClaudeWrapper.DuplexSession.TransportTerminal do
  @moduledoc """
  Terminal transport evidence with a bounded, separate stderr tail.

  For the Forcola adapter, `evidence` is a `Forcola.Duplex.Terminal`.
  It keeps child status, cleanup confirmation, scope, and output completeness
  distinct. For `Adapter.Port`, `evidence` is `:closed` after an explicit
  close, `{:exit_status, code}` when the child exited, or `{:exit, reason}`
  when the port exited. `stderr` is diagnostic data, never parsed as provider NDJSON or
  interpolated into an exception message.
  """

  @enforce_keys [:evidence, :stderr]
  defstruct [:evidence, :stderr]

  @type t :: %__MODULE__{evidence: term(), stderr: binary()}
end
