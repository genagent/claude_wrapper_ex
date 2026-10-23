defmodule ClaudeWrapper.ExecutionEvidence do
  @moduledoc """
  The terminal evidence record of one evidenced one-shot execution.

  `ClaudeWrapper.Query.execute/3` with `execution_observer: {pid, reference}`
  sends exactly one `{reference, %ClaudeWrapper.ExecutionEvidence{}}` to
  `pid`, on success or failure, before the call returns. A
  `%ClaudeWrapper.SessionObservation{}` for the same execution, when there is
  one, is sent earlier, as soon as the native session ID is seen. Runner
  raises, throws and catchable exits become typed `:io` outcomes with
  `{:runner_failed, kind, reason}` and still send one record. On this fallback,
  stdout retains up to 1 MiB of observed lines with reconstructed newlines;
  native status, cleanup and transport close remain unknown. Collector helper
  failures retain bounded received stdout/stderr; observer failures drain the
  native run and preserve its terminal report. Uncatchable caller death
  cannot deliver a terminal record.

  Each field is a separate fact. None of them is implied by another:

    * `:runner` -- the runner module that was selected
    * `:execution` -- `:started`, `:not_started` (rejected before any spawn),
      or `:unknown`
    * `:child_status` / `:child_signal` -- the raw direct-child exit status or
      signal reported by the native layer, `nil` when not reported. Never
      fabricated for runs that did not start or whose report was missing or
      malformed.
    * `:termination` -- how the native layer ended (for Forcola: `:exit`,
      `:malformed_exit`, `:backstop`, `{:transport, status}`,
      `{:spawn, reason}`), `:not_started`, or `:unknown`
    * `:reason` -- `nil` or the bound that cancelled the run: `:timeout`,
      `:idle_timeout`, `:max_output_bytes`, `:observer_overflow` (`:unknown`
      when the runner reported something else)
    * `:output_truncated` -- `true`, `false`, or `:unknown`
    * `:cleanup` -- `:confirmed` only when the native layer explicitly
      confirmed it; otherwise `:unconfirmed`, `:unknown`, or `:not_applicable`
    * `:scope` -- what a cleanup confirmation covers: `:process_group`,
      `:active_cgroup`, `:unknown`, or `:not_applicable`. A process-group
      confirmation does not cover descendants that left the group, so it is
      never evidence that the whole process tree is gone.
    * `:guard_close` -- the transport-close result, separate from cleanup:
      `:ok`, `{:error, reason}`, `:unknown`, or `:not_applicable`
    * `:stdout` / `:stderr` -- the bytes the runner retained, including after
      a failure. Bounded when the runner bounds output (for
      `ClaudeWrapper.Runner.Forcola`, by `:max_output_bytes`).
    * `:lines_dropped` -- stdout lines over the per-line bound that were not
      passed to the session/rate-limit observers
    * `:session_id` -- the first valid native session ID seen on stdout during
      this execution, or `nil`
    * `:result` -- the last terminal `result` event found in the retained
      stdout, or `nil`. It is kept even when the execution later failed
      (timeout, nonzero exit, unconfirmed cleanup); its presence is not
      evidence of clean completion.
    * `:outcome` -- the exact `{:ok, result}` / `{:error, error}` the call
      returns

  Values a runner reports outside these vocabularies are recorded as
  `:unknown` (or `nil` for the raw status fields).
  """

  alias ClaudeWrapper.{Error, Result}

  @type t :: %__MODULE__{
          runner: module() | nil,
          execution: :started | :not_started | :unknown,
          child_status: non_neg_integer() | nil,
          child_signal: pos_integer() | nil,
          termination: term(),
          reason:
            nil | :timeout | :idle_timeout | :max_output_bytes | :observer_overflow | :unknown,
          output_truncated: boolean() | :unknown,
          cleanup: :confirmed | :unconfirmed | :unknown | :not_applicable,
          scope: :process_group | :active_cgroup | :unknown | :not_applicable,
          guard_close: :ok | {:error, term()} | :unknown | :not_applicable,
          stdout: binary(),
          stderr: binary(),
          lines_dropped: non_neg_integer(),
          session_id: String.t() | nil,
          result: Result.t() | nil,
          outcome: {:ok, Result.t()} | {:error, Error.t()} | nil
        }

  defstruct runner: nil,
            execution: :unknown,
            child_status: nil,
            child_signal: nil,
            termination: :unknown,
            reason: nil,
            output_truncated: :unknown,
            cleanup: :unknown,
            scope: :unknown,
            guard_close: :unknown,
            stdout: "",
            stderr: "",
            lines_dropped: 0,
            session_id: nil,
            result: nil,
            outcome: nil

  @reasons [nil, :timeout, :idle_timeout, :max_output_bytes, :observer_overflow]

  @doc """
  Build a record from a runner's native evidence map, normalizing every value
  outside the documented vocabularies to `:unknown` (or `nil`).
  """
  @spec from_native(map(), keyword()) :: t()
  def from_native(native, fields \\ []) when is_map(native) do
    %__MODULE__{
      runner: fields[:runner],
      execution: member(native[:execution], [:started, :not_started]),
      child_status: non_neg(native[:child_status]),
      child_signal: positive(native[:child_signal]),
      termination: Map.get(native, :termination, :unknown),
      reason: if(native[:reason] in @reasons, do: native[:reason], else: :unknown),
      output_truncated: member(native[:output_truncated], [true, false]),
      cleanup: member(native[:cleanup], [:confirmed, :unconfirmed, :not_applicable]),
      scope: member(native[:scope], [:process_group, :active_cgroup, :not_applicable]),
      guard_close: guard_close(native[:guard_close]),
      stdout: binary(native[:stdout]),
      stderr: binary(native[:stderr]),
      lines_dropped: non_neg(native[:lines_dropped]) || 0,
      session_id: fields[:session_id],
      result: fields[:result],
      outcome: fields[:outcome]
    }
  end

  defp member(value, allowed), do: if(value in allowed, do: value, else: :unknown)

  defp non_neg(value) when is_integer(value) and value >= 0, do: value
  defp non_neg(_value), do: nil

  defp positive(value) when is_integer(value) and value > 0, do: value
  defp positive(_value), do: nil

  defp guard_close(value) when value in [:ok, :not_applicable], do: value
  defp guard_close({:error, _reason} = value), do: value
  defp guard_close(_value), do: :unknown

  defp binary(value) when is_binary(value), do: value
  defp binary(_value), do: ""
end
