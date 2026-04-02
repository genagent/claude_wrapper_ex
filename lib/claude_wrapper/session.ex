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

  alias ClaudeWrapper.{Config, Query, Result}

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
  """
  @spec send(t(), String.t(), keyword()) :: {:ok, t(), Result.t()} | {:error, term()}
  def send(%__MODULE__{} = session, prompt, opts \\ []) do
    query = build_query(session, prompt, opts)

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
  end

  @doc """
  Send a message and return a stream of events.

  Updates the session with the session_id from the first result event seen.
  Returns `{updated_session, stream}`. The session_id is captured from
  the stream, so consume the stream before sending the next message.
  """
  @spec stream(t(), String.t(), keyword()) :: {t(), Enumerable.t()}
  def stream(%__MODULE__{} = session, prompt, opts \\ []) do
    query = build_query(session, prompt, opts)
    raw_stream = Query.stream(query, session.config)

    session_ref = make_ref()
    parent = self()

    wrapped_stream =
      Stream.each(raw_stream, &maybe_capture_session_id(&1, session_ref, parent))

    {%{session | session_id: session_ref}, wrapped_stream}
  end

  defp maybe_capture_session_id(event, ref, parent) do
    if ClaudeWrapper.StreamEvent.result?(event) do
      case ClaudeWrapper.StreamEvent.session_id(event) do
        nil -> :ok
        sid -> Kernel.send(parent, {ref, :session_id, sid})
      end
    end
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

  defp build_query(session, prompt, per_call_opts) do
    merged_opts = Keyword.merge(session.query_opts, per_call_opts)
    query = Query.new(prompt)

    query =
      Enum.reduce(merged_opts, query, fn
        {:model, v}, q -> Query.model(q, v)
        {:system_prompt, v}, q -> Query.system_prompt(q, v)
        {:max_turns, v}, q -> Query.max_turns(q, v)
        {:permission_mode, v}, q -> Query.permission_mode(q, v)
        {:max_budget_usd, v}, q -> Query.max_budget_usd(q, v)
        {:effort, v}, q -> Query.effort(q, v)
        {:allowed_tools, tools}, q when is_list(tools) ->
          Enum.reduce(tools, q, fn tool, acc -> Query.allowed_tool(acc, tool) end)

        {:disallowed_tools, tools}, q when is_list(tools) ->
          Enum.reduce(tools, q, fn tool, acc -> Query.disallowed_tool(acc, tool) end)

        {:dangerously_skip_permissions, true}, q -> Query.dangerously_skip_permissions(q)
        {:no_session_persistence, true}, q -> Query.no_session_persistence(q)
        _other, q -> q
      end)

    # Thread session continuity
    case session.session_id do
      nil -> query
      sid when is_binary(sid) -> Query.resume(query, sid)
      _ref -> query
    end
  end
end
