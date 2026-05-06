defmodule ClaudeWrapper.SessionServer do
  @moduledoc """
  GenServer wrapper for long-running multi-turn sessions.

  Holds a `ClaudeWrapper.Session` in state and provides a process-based
  interface for OTP applications, supervision trees, and concurrent access.

  ## Usage

      config = ClaudeWrapper.Config.new(working_dir: "/path/to/project")

      {:ok, pid} = ClaudeWrapper.SessionServer.start_link(
        config: config,
        query_opts: [model: "sonnet", max_turns: 5]
      )

      {:ok, result} = ClaudeWrapper.SessionServer.send_message(pid, "What files are here?")
      {:ok, result} = ClaudeWrapper.SessionServer.send_message(pid, "Add tests for lib/foo.ex")

      ClaudeWrapper.SessionServer.total_cost(pid)
      #=> 0.12

  ## Supervision

      children = [
        {ClaudeWrapper.SessionServer,
         name: :my_agent,
         config: config,
         query_opts: [model: "sonnet"]}
      ]

      Supervisor.start_link(children, strategy: :one_for_one)

      # Then use the registered name
      ClaudeWrapper.SessionServer.send_message(:my_agent, "hello")
  """

  use GenServer

  alias ClaudeWrapper.{Config, Result, Session}

  @type server :: GenServer.server()

  @type option ::
          {:config, Config.t()}
          | {:query_opts, keyword()}
          | {:session_id, String.t()}
          | {:name, GenServer.name()}
          | GenServer.option()

  # --- Client API ---

  @doc """
  Start a session server.

  ## Options

    * `:config` - (required) `%Config{}` struct
    * `:query_opts` - Query options applied to every turn (e.g. `model`, `max_turns`)
    * `:session_id` - Resume an existing session by ID
    * `:name` - Register the process with a name

  Also accepts standard `GenServer.start_link/3` options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {config, opts} = Keyword.pop!(opts, :config)
    {query_opts, opts} = Keyword.pop(opts, :query_opts, [])
    {session_id, opts} = Keyword.pop(opts, :session_id)

    init_arg = %{config: config, query_opts: query_opts, session_id: session_id}
    GenServer.start_link(__MODULE__, init_arg, opts)
  end

  @doc """
  Send a message in the session. Blocks until the CLI responds.

  Returns `{:ok, %Result{}}` or `{:error, reason}`.
  """
  @spec send_message(server(), String.t(), keyword()) ::
          {:ok, Result.t()} | {:error, term()}
  def send_message(server, prompt, opts \\ []) do
    GenServer.call(server, {:send, prompt, opts}, :infinity)
  end

  @doc """
  Get the session ID (if established).
  """
  @spec session_id(server()) :: String.t() | nil
  def session_id(server) do
    GenServer.call(server, :session_id)
  end

  @doc """
  Get the number of completed turns.
  """
  @spec turn_count(server()) :: non_neg_integer()
  def turn_count(server) do
    GenServer.call(server, :turn_count)
  end

  @doc """
  Get the total cost across all turns.
  """
  @spec total_cost(server()) :: float()
  def total_cost(server) do
    GenServer.call(server, :total_cost)
  end

  @doc """
  Get the last result, if any.
  """
  @spec last_result(server()) :: Result.t() | nil
  def last_result(server) do
    GenServer.call(server, :last_result)
  end

  @doc """
  Get the full conversation history.
  """
  @spec history(server()) :: [Result.t()]
  def history(server) do
    GenServer.call(server, :history)
  end

  @doc """
  Get the underlying `%Session{}` struct (snapshot).
  """
  @spec get_session(server()) :: Session.t()
  def get_session(server) do
    GenServer.call(server, :get_session)
  end

  @doc """
  Replace the underlying `%Session{}` struct.

  Useful when you have streamed a session turn outside the GenServer
  process (e.g. by calling `Session.stream/3` directly) and need to
  push the post-turn session state back into the supervised server so
  the next `send/3` resumes correctly.
  """
  @spec put_session(server(), Session.t()) :: :ok
  def put_session(server, %Session{} = session) do
    GenServer.call(server, {:put_session, session})
  end

  # --- Server callbacks ---

  @impl true
  def init(%{config: config, query_opts: query_opts, session_id: nil}) do
    {:ok, Session.new(config, query_opts)}
  end

  def init(%{config: config, query_opts: query_opts, session_id: session_id}) do
    {:ok, Session.resume(config, session_id, query_opts)}
  end

  @impl true
  def handle_call({:send, prompt, opts}, _from, session) do
    case Session.send(session, prompt, opts) do
      {:ok, new_session, result} ->
        {:reply, {:ok, result}, new_session}

      {:error, _reason} = error ->
        {:reply, error, session}
    end
  end

  def handle_call(:session_id, _from, session) do
    {:reply, Session.session_id(session), session}
  end

  def handle_call(:turn_count, _from, session) do
    {:reply, Session.turn_count(session), session}
  end

  def handle_call(:total_cost, _from, session) do
    {:reply, Session.total_cost(session), session}
  end

  def handle_call(:last_result, _from, session) do
    {:reply, Session.last_result(session), session}
  end

  def handle_call(:history, _from, session) do
    {:reply, Session.turns(session), session}
  end

  def handle_call(:get_session, _from, session) do
    {:reply, session, session}
  end

  def handle_call({:put_session, new_session}, _from, _session) do
    {:reply, :ok, new_session}
  end
end
