defmodule ClaudeWrapper.Session do
  @moduledoc """
  Multi-turn session management.

  Wraps repeated `Query.execute/2` calls, automatically threading the
  `session_id` returned by the CLI so each turn continues the same
  conversation.

  ## Usage

      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")
      session = ClaudeWrapper.Session.new(config)

      {:ok, session, result} = ClaudeWrapper.Session.send(session, "What files are in this project?")
      {:ok, session, result} = ClaudeWrapper.Session.send(session, "Now add tests for lib/foo.ex")

      # Access history
      ClaudeWrapper.Session.turns(session)
      #=> [%Result{...}, %Result{...}]

      # Resume a previous session
      session = ClaudeWrapper.Session.resume(config, "session-id-abc")
  """

  alias ClaudeWrapper.{Config, Error, Prompt, Query, Result, Telemetry}

  @type t :: %__MODULE__{
          config: Config.t(),
          session_id: String.t() | nil,
          history: [Result.t()],
          query_opts: keyword()
        }

  defstruct [
    :config,
    :session_id,
    history: [],
    query_opts: []
  ]

  @doc """
  Create a new session with the given config.

  ## Options

  Any option accepted by `ClaudeWrapper.query/2` (query-level options only):

    * `:model` - Model name
    * `:system_prompt` - System prompt
    * `:max_turns` - Max turns per send
    * `:permission_mode` - Permission mode
    * `:max_budget_usd` - Budget limit
    * `:effort` - Effort level
  """
  @spec new(Config.t(), keyword()) :: t()
  def new(%Config{} = config, opts \\ []) do
    %__MODULE__{config: config, query_opts: opts}
  end

  @doc """
  Resume an existing session by ID.
  """
  @spec resume(Config.t(), String.t(), keyword()) :: t()
  def resume(%Config{} = config, session_id, opts \\ []) do
    %__MODULE__{config: config, session_id: session_id, query_opts: opts}
  end

  @doc """
  Send a message in the session. Returns the updated session and result.

  The first turn creates a new session. Subsequent turns use `--resume`
  with the session ID from the first result.

  `prompt` is either a plain string or a `t:ClaudeWrapper.Prompt.t/0`. A
  `Prompt` is rendered (which expands attached files and git diffs)
  before the turn runs; a render failure short-circuits to
  `{:error, %ClaudeWrapper.Error{}}` without launching the CLI.
  """
  @spec send(t(), String.t() | Prompt.t(), keyword()) ::
          {:ok, t(), Result.t()} | {:error, Error.t()}
  def send(%__MODULE__{} = session, prompt, opts \\ []) do
    with {:ok, text} <- resolve_prompt(prompt) do
      do_send(session, text, opts)
    end
  end

  defp do_send(session, text, opts) do
    query = build_query(session, text, opts)

    Telemetry.span_session_turn(session, query, fn ->
      case Query.execute(query, session.config) do
        {:ok, result} ->
          new_session_id = result.session_id || session.session_id

          updated = %{
            session
            | session_id: new_session_id,
              history: session.history ++ [result]
          }

          {:ok, updated, result}

        {:error, _} = error ->
          error
      end
    end)
  end

  @doc """
  Send a message and return a stream of events.

  Returns `{session, stream}`. The returned `session` is the **same
  session passed in** -- this function does *not* thread `session_id`
  across turns. If you need multi-turn continuity, use `send/3`
  instead, which runs the turn synchronously and updates
  `session_id` from the final result.

  Use `stream/3` when you want to observe events from a single turn
  (for example, to render intermediate output as the CLI produces
  it) and do not need to chain into a follow-up turn on the same
  session.
  """
  @spec stream(t(), String.t(), keyword()) :: {t(), Enumerable.t()}
  def stream(%__MODULE__{} = session, prompt, opts \\ []) do
    query = build_query(session, prompt, opts)
    raw_stream = Query.stream(query, session.config)
    {session, raw_stream}
  end

  @doc """
  Branch the conversation into a new, independent session.

  Resumes the session's current `session_id` with `--fork-session` and
  sends `prompt`. The CLI clones the prior context into a *new* session;
  the returned `Session` is bound to that new forked id, while the
  original struct passed in is left completely untouched -- you can keep
  using it to continue the original thread.

  `prompt` accepts a string or a `t:ClaudeWrapper.Prompt.t/0`, exactly
  like `send/3`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :no_session}}` if the
  session has no established `session_id` yet (nothing to fork from --
  send at least one turn first).

  ## Example

      {:ok, session, _} = ClaudeWrapper.Session.send(session, "Draft a plan")
      {:ok, branch, _} = ClaudeWrapper.Session.fork(session, "Now try a riskier variant")
      # `session` still points at the original thread; `branch` is the fork.
  """
  @spec fork(t(), String.t() | Prompt.t(), keyword()) ::
          {:ok, t(), Result.t()} | {:error, Error.t()}
  def fork(session, prompt, opts \\ [])

  def fork(%__MODULE__{session_id: nil}, _prompt, _opts) do
    {:error, Error.new(:no_session)}
  end

  def fork(%__MODULE__{session_id: sid} = session, prompt, opts) when is_binary(sid) do
    # Branch from a copy that resumes the current id, with --fork-session
    # set so the CLI mints a new session rather than appending to this one.
    # do_send binds the returned session to the new id from the result and
    # the original `session` struct is never mutated.
    forked = %{session | history: []}

    send(forked, prompt, Keyword.put(opts, :fork_session, true))
  end

  @doc """
  Get the session ID (if established).
  """
  @spec session_id(t()) :: String.t() | nil
  def session_id(%__MODULE__{session_id: sid}) when is_binary(sid), do: sid
  def session_id(%__MODULE__{}), do: nil

  @doc """
  Get the conversation history (list of results).
  """
  @spec turns(t()) :: [Result.t()]
  def turns(%__MODULE__{history: history}), do: history

  @doc """
  Get the number of completed turns.
  """
  @spec turn_count(t()) :: non_neg_integer()
  def turn_count(%__MODULE__{history: history}), do: length(history)

  @doc """
  Get the total cost across all turns.
  """
  @spec total_cost(t()) :: float()
  def total_cost(%__MODULE__{history: history}) do
    Enum.reduce(history, 0.0, fn result, acc ->
      acc + (result.cost_usd || 0.0)
    end)
  end

  @doc """
  Get the last result, if any.
  """
  @spec last_result(t()) :: Result.t() | nil
  def last_result(%__MODULE__{history: []}), do: nil
  def last_result(%__MODULE__{history: history}), do: List.last(history)

  # --- Private ---

  # Normalize a prompt argument to a string. A %Prompt{} is rendered
  # (expanding files / git diffs); a render failure becomes the caller's
  # {:error, %Error{}} so core stays tuple-returning rather than raising.
  defp resolve_prompt(prompt) when is_binary(prompt), do: {:ok, prompt}
  defp resolve_prompt(%Prompt{} = prompt), do: Prompt.render(prompt)

  defp build_query(session, prompt, per_call_opts) do
    merged_opts = Keyword.merge(session.query_opts, per_call_opts)

    query =
      prompt
      |> Query.new()
      |> Query.apply_opts(merged_opts)

    # Thread session continuity. We do this AFTER apply_opts so that
    # an explicit `:resume` in opts does not override an established
    # session_id from a prior turn -- the established id wins, which
    # matches the multi-turn intent of `Session`.
    case session.session_id do
      nil -> query
      sid when is_binary(sid) -> Query.resume(query, sid)
      _ref -> query
    end
  end
end
