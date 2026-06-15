defmodule ClaudeWrapper.Conversation do
  @moduledoc """
  Host-side bookkeeping wrapper over a `ClaudeWrapper.DuplexSession`.

  `Conversation` keeps a rolling history of `ClaudeWrapper.Result`
  structs, cumulative cost, and a turn count on top of an underlying
  long-lived `DuplexSession`. The duplex session remains the transport;
  this wrapper only adds the accounting that `DuplexSession.send/3` does
  not provide on its own.

  It is the duplex-flavoured peer of `ClaudeWrapper.Session`, which is
  the equivalent bookkeeping shape over transient per-call subprocess
  turns. `Conversation` follows the same functional-struct style: a
  `%Conversation{}` value threads through `send/2,3`, which returns the
  updated struct alongside the turn's `Result`.

  Mirrors the Rust crate's `conversation::Conversation`.

  ## When to use

  Reach for `Conversation` when you already want a `DuplexSession`
  (long-running host, mid-turn interrupts, broadcast subscribers) and
  also want to answer:

    * How much have I spent on this conversation so far? (`total_cost/1`)
    * What is the full history of turns? (`history/1`)
    * How many turns have completed? (`turn_count/1`)

  If you do not need bookkeeping, drive the `DuplexSession` directly. If
  you want accounting over short-lived per-turn subprocess calls, use
  `ClaudeWrapper.Session` instead.

  ## Usage

      config = ClaudeWrapper.Config.new()
      {:ok, session} = ClaudeWrapper.DuplexSession.start_link(config: config)

      conv = ClaudeWrapper.Conversation.new(session)

      {:ok, conv, _result} = ClaudeWrapper.Conversation.send(conv, "hello")
      {:ok, conv, _result} = ClaudeWrapper.Conversation.send(conv, "and again")

      ClaudeWrapper.Conversation.turn_count(conv)
      #=> 2

      ClaudeWrapper.Conversation.total_cost(conv)
      #=> 0.0123

      ClaudeWrapper.Conversation.close(conv)

  ## Beyond bookkeeping

  `send/2,3` is the only entry point that records history. For
  `DuplexSession.subscribe/1`, `DuplexSession.interrupt/2`, and
  `DuplexSession.respond_to_permission/3`, reach the inner handle via
  `session/1`. Those calls bypass the wrapper's accounting on purpose:
  an interrupt still produces a `Result` that the in-flight `send/2,3`
  records cleanly when the truncated turn lands.
  """

  alias ClaudeWrapper.{DuplexSession, Result}

  @typedoc """
  The underlying session reference: the pid or registered name of a
  running `ClaudeWrapper.DuplexSession`.
  """
  @type session :: GenServer.server()

  @type t :: %__MODULE__{
          session: session(),
          history: [Result.t()]
        }

  @enforce_keys [:session]
  defstruct session: nil, history: []

  @doc """
  Wrap a running `DuplexSession` in a fresh conversation.

  The conversation starts with an empty history; the underlying session
  is not touched until the first `send/2,3`. `session` is the pid (or
  registered name) returned by `DuplexSession.start_link/1`.
  """
  @spec new(session()) :: t()
  def new(session) do
    %__MODULE__{session: session, history: []}
  end

  @doc """
  Send a user prompt over the underlying `DuplexSession` and record the
  resulting `ClaudeWrapper.Result`.

  Returns `{:ok, conversation, result}` with the history-updated
  conversation on success, matching `ClaudeWrapper.Session.send/3`'s
  return convention. Errors from `DuplexSession.send/3` (e.g.
  `{:error, %ClaudeWrapper.Error{kind: :turn_in_flight}}`,
  `{:error, %ClaudeWrapper.Error{kind: :duplex_closed}}`) propagate
  unchanged and do not update the history.

  The `timeout` defaults to the same 120 seconds as
  `DuplexSession.send/3`, since the entire turn (cold start + model
  latency + tool calls) must complete within it.
  """
  @spec send(t(), String.t(), timeout()) ::
          {:ok, t(), Result.t()} | {:error, term()}
  def send(%__MODULE__{} = conversation, prompt, timeout \\ 120_000)
      when is_binary(prompt) do
    case DuplexSession.send(conversation.session, prompt, timeout) do
      {:ok, %Result{} = result} ->
        updated = %{conversation | history: conversation.history ++ [result]}
        {:ok, updated, result}

      {:error, _reason} = error ->
        error
    end
  end

  @doc """
  The per-turn `Result` history, in arrival order.
  """
  @spec history(t()) :: [Result.t()]
  def history(%__MODULE__{history: history}), do: history

  @doc """
  The most recent turn's `Result`, or `nil` if no turn has completed.
  """
  @spec last_result(t()) :: Result.t() | nil
  def last_result(%__MODULE__{history: []}), do: nil
  def last_result(%__MODULE__{history: history}), do: List.last(history)

  @doc """
  Cumulative cost in USD across every recorded turn.

  Turns whose `Result` carries no `cost_usd` contribute `0.0`.
  """
  @spec total_cost(t()) :: float()
  def total_cost(%__MODULE__{history: history}) do
    Enum.reduce(history, 0.0, fn %Result{} = result, acc ->
      acc + (result.cost_usd || 0.0)
    end)
  end

  @doc """
  Number of turns recorded through `send/2,3`.
  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{history: history}), do: length(history)

  @doc """
  The session id assigned by the CLI, or `nil` until the first turn (or
  `system/init`) has been observed.

  Prefers the most recent turn's `Result.session_id`; falls back to
  querying the underlying `DuplexSession` when no turn has recorded one
  yet (for example, `system/init` arrived but no turn has completed).
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{history: history, session: session}) do
    case last_recorded_session_id(history) do
      nil -> DuplexSession.session_id(session)
      sid -> sid
    end
  end

  @doc """
  Borrow the underlying `DuplexSession` reference.

  Use this for `DuplexSession.subscribe/1`, `DuplexSession.interrupt/2`,
  and `DuplexSession.respond_to_permission/3`, which bypass this
  wrapper's bookkeeping on purpose.
  """
  @spec session(t()) :: session()
  def session(%__MODULE__{session: session}), do: session

  @doc """
  Stop the underlying `DuplexSession`.

  Delegates to `DuplexSession.close/1` (graceful stop). Returns `:ok`.
  The `%Conversation{}` struct is left as-is; its accumulated history
  remains readable after the session is gone.
  """
  @spec close(t()) :: :ok
  def close(%__MODULE__{session: session}), do: DuplexSession.close(session)

  # --- Internals ------------------------------------------------------

  defp last_recorded_session_id([]), do: nil

  defp last_recorded_session_id(history) do
    history
    |> List.last()
    |> Map.get(:session_id)
  end
end
