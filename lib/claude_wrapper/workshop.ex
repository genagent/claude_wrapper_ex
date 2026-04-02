defmodule ClaudeWrapper.Workshop do
  @moduledoc """
  Multi-agent IEx API for coordinating Claude Code sessions.

  A naming and coordination layer over `ClaudeWrapper.SessionServer`.
  Each agent is a supervised GenServer addressed by name. All functions
  are designed to be called interactively after `import ClaudeWrapper.Workshop`.

  ## Quick start

      # 1. Set shared config (do this first -- affects all new agents)
      configure(working_dir: "~/projects/myapp", model: "sonnet",
        context: "Elixir project. Run mix test before committing.")

      # 2. Create agents with roles
      agent(:impl, "You write clean, tested code.", max_turns: 15)
      agent(:reviewer, "You review code. Do not modify files.",
        model: "opus", allowed_tools: ["Read", "Bash"])

      # 3. Talk to them
      ask(:impl, "Implement caching for the user lookup")
      pipe(:impl, :reviewer, "Review for correctness")

      # 4. Check on things
      status()       # dashboard table
      total_cost()   # how much you've spent

  ## Sync vs async

  Two ways to send messages:

    * `ask/2` -- blocks until the agent responds, prints the result
    * `cast/2` -- returns immediately, agent works in the background

  Use `await/1` or `await_all/0` to collect async results. Use `status/0`
  to see who's busy.

  ## Coordination

    * `pipe/3` -- wait for one agent, forward its result to another
    * `fan/2` -- send the same message to multiple agents in parallel

  `ask/2` and `pipe/3` return the agent name on success, so they
  compose with Elixir's pipe operator:

      ask(:impl, "implement caching")
      |> pipe(:reviewer, "review for edge cases")
      |> pipe(:tests, "write tests for this")

  ## Inspecting agents

    * `status/0` -- dashboard of all agents
    * `info/1` -- detailed map for one agent (model, session_id, cost, ...)
    * `result/1` -- last response text (or pass `:full` for the `%Result{}` struct)
    * `history/1` -- print the full conversation
    * `inspect_agent/1` -- show the CLI command the agent runs (copy-pasteable)
    * `cost/0` -- itemized costs; `cost/1` -- single agent; `total_cost/0` -- sum

  ## Lifecycle

    * `load/0` -- load `.workshop.exs` (auto-loaded on startup if present)
    * `load/1` -- load a specific setup file
    * `reset/1` -- clear an agent's conversation (keeps role and config)
    * `dismiss/1` -- remove an agent entirely
    * `reset_all/0` -- stop everything, clear config

  ## Architecture

      Workshop (IEx helpers, global state in named Agent)
        |-- DynamicSupervisor
        |     |-- SessionServer (:impl)
        |     |-- SessionServer (:reviewer)
        |     `-- SessionServer (:tests)
        `-- Task.Supervisor (async tasks for cast/2)
  """

  alias ClaudeWrapper.{Config, Query, Result, Session, SessionServer}

  @table :claude_workshop_agents
  @state :claude_workshop_state
  @sessions_sup ClaudeWrapper.Workshop.SessionsSupervisor
  @tasks_sup ClaudeWrapper.Workshop.TasksSupervisor
  @supervisor ClaudeWrapper.Workshop.Supervisor

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose, :debug]
  @valid_permission_modes [:default, :accept_edits, :bypass_permissions, :dont_ask, :plan, :auto]

  # ── Boot ──────────────────────────────────────────────────────

  defp ensure_started do
    if Process.whereis(@supervisor) && :ets.info(@table) != :undefined do
      :ok
    else
      do_start()
    end
  end

  defp do_start do
    # Stop stale supervisor if ETS table was lost (e.g., owning process died)
    case Process.whereis(@supervisor) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end

        # Wait for name to be unregistered
        Process.sleep(10)
    end

    # Agent init creates the ETS table so it's owned by a supervised process
    agent_init = fn ->
      if :ets.info(@table) == :undefined do
        :ets.new(@table, [:named_table, :public, :set])
      end

      default_state()
    end

    children = [
      %{id: @state, start: {Agent, :start_link, [agent_init, [name: @state]]}},
      {DynamicSupervisor, name: @sessions_sup, strategy: :one_for_one},
      {Task.Supervisor, name: @tasks_sup}
    ]

    case Supervisor.start_link(children, strategy: :one_for_one, name: @supervisor) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
      error -> error
    end
  end

  @doc """
  Stop the entire Workshop supervision tree. Used for clean teardown in tests.
  """
  @spec stop() :: :ok
  def stop do
    case Process.whereis(@supervisor) do
      nil ->
        :ok

      pid ->
        try do
          Supervisor.stop(pid, :normal)
        catch
          :exit, _ -> :ok
        end
    end

    if :ets.info(@table) != :undefined do
      :ets.delete(@table)
    end

    :ok
  end

  defp default_state do
    %{config_opts: [], query_opts: [permission_mode: :auto], context: nil}
  end

  # ── Configuration ─────────────────────────────────────────────

  @doc """
  Set global defaults inherited by all agents. Call this first.

  Changes affect new agents only; existing agents keep their config.

  ## Examples

      # Minimal
      configure(working_dir: ".")

      # Full setup
      configure(
        working_dir: "~/projects/myapp",
        model: "sonnet",
        max_turns: 10,
        context: \"""
        Elixir project using Phoenix 1.7.
        Run mix test before considering any task complete.
        Use conventional commits.
        \"""
      )

  ## Permissions

  Workshop defaults to `permission_mode: :auto` so agents can work
  non-interactively (the CLI default of `:default` would hang waiting
  for approval that never comes). Override here to change for all agents:

      configure(permission_mode: :bypass_permissions)

  ## Options

  Config options: `:binary`, `:working_dir`, `:env`, `:timeout`, `:verbose`, `:debug`

  Query options: `:model`, `:max_turns`, `:permission_mode`, `:max_budget_usd`, `:effort`

  Special: `:context` -- global system prompt prepended to every agent's role.
  The effective system prompt for each agent is `context <> "\\n\\n" <> role`.
  """
  @spec configure(keyword()) :: :ok
  def configure(opts \\ []) do
    ensure_started()

    {context, opts} = Keyword.pop(opts, :context)
    {config_opts, query_opts} = split_opts(opts)
    validate_opts!(query_opts)

    Agent.update(@state, fn state ->
      %{
        state
        | config_opts: config_opts,
          query_opts: Keyword.merge(state.query_opts, query_opts),
          context: context
      }
    end)

    :ok
  end

  # ── Agent Management ──────────────────────────────────────────

  @doc """
  Start a named agent.

  The role string is agent-specific context that composes with the global
  context from `configure/1`. If both are set, the effective system prompt
  is `context <> "\\n\\n" <> role`. Agent-specific options override globals.

  Calling `agent/3` with an existing name replaces that agent.

  ## Examples

      # Full agent with role and options
      agent(:impl, "You write clean, well-tested code.", max_turns: 15)

      # Read-only reviewer using opus
      agent(:reviewer, "You review code. Do not modify files.",
        model: "opus", allowed_tools: ["Read", "Bash"])

      # Minimal -- inherits everything from configure()
      agent(:scratch)

      # Options without a role
      agent(:fast, model: "haiku", max_turns: 3)

  ## Permissions

  Workshop defaults to `permission_mode: :auto` so agents can work
  non-interactively. Override per-agent or globally via `configure/1`:

      # Global: all agents use bypass
      configure(permission_mode: :bypass_permissions)

      # Per-agent: restrict the reviewer to default
      agent(:reviewer, "Review only.", permission_mode: :default)

  Valid modes: `:default`, `:accept_edits`, `:bypass_permissions`,
  `:dont_ask`, `:plan`, `:auto`.

  ## Options

  Accepts any query option supported by `ClaudeWrapper.Session`: `:model`,
  `:max_turns`, `:permission_mode`, `:max_budget_usd`, `:effort`,
  `:allowed_tools`, `:disallowed_tools`, `:dangerously_skip_permissions`.
  """
  @spec agent(atom(), String.t() | nil, keyword()) :: :ok
  def agent(name, role_or_opts \\ nil, opts \\ [])

  def agent(name, role, opts) when is_atom(name) and (is_binary(role) or is_nil(role)) do
    ensure_started()

    # Dismiss existing agent with same name
    if get_agent(name), do: dismiss(name)

    global = get_global_state()
    config = Config.new(global.config_opts)

    # Compose system prompt: global context + agent role
    system_prompt = compose_system_prompt(global.context, role)

    # Merge global query opts with agent-specific opts (agent wins)
    {_agent_config_opts, agent_query_opts} = split_opts(opts)
    validate_opts!(agent_query_opts)
    query_opts = Keyword.merge(global.query_opts, agent_query_opts)

    query_opts =
      if system_prompt do
        Keyword.put(query_opts, :system_prompt, system_prompt)
      else
        query_opts
      end

    child_spec = %{
      id: :"workshop_agent_#{name}",
      start: {SessionServer, :start_link, [[config: config, query_opts: query_opts]]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(@sessions_sup, child_spec)

    entry = %{
      pid: pid,
      role: role,
      agent_opts: opts,
      query_opts: query_opts,
      status: :idle,
      task: nil,
      task_text: nil,
      cumulative_cost: 0.0,
      turn_count: 0,
      last_result: nil
    }

    :ets.insert(@table, {name, entry})
    :ok
  end

  def agent(name, opts, []) when is_atom(name) and is_list(opts) do
    agent(name, nil, opts)
  end

  @doc """
  List all agent names, sorted alphabetically.

  ## Example

      agents()    # => [:impl, :reviewer, :tests]
  """
  @spec agents() :: [atom()]
  def agents do
    ensure_started()
    :ets.tab2list(@table) |> Enum.map(&elem(&1, 0)) |> Enum.sort()
  end

  @doc """
  Remove an agent entirely. Stops its process and discards all state.

  No-op if the agent doesn't exist. Use `reset/1` instead if you want
  to keep the agent but clear its conversation.
  """
  @spec dismiss(atom()) :: :ok
  def dismiss(name) do
    ensure_started()

    case get_agent(name) do
      nil ->
        :ok

      entry ->
        try do
          if entry.task, do: Task.Supervisor.terminate_child(@tasks_sup, entry.task.pid)
          DynamicSupervisor.terminate_child(@sessions_sup, entry.pid)
        catch
          :exit, _ -> :ok
        end

        :ets.delete(@table, name)
        :ok
    end
  end

  @doc """
  Reset an agent's conversation. Keeps the role, model, and all config.

  The agent gets a fresh session -- like calling `agent/3` again with
  the same arguments. Cost tracking is also reset to zero.

  ## Example

      ask(:impl, "Write some code")
      # ... not happy with the direction ...
      reset(:impl)
      ask(:impl, "Try a different approach")   # fresh conversation
  """
  @spec reset(atom()) :: :ok
  def reset(name) do
    ensure_started()
    entry = get_agent!(name)

    if entry.task do
      Task.Supervisor.terminate_child(@tasks_sup, entry.task.pid)
    end

    global = get_global_state()
    config = Config.new(global.config_opts)
    system_prompt = compose_system_prompt(global.context, entry.role)

    {_config_opts, agent_query_opts} = split_opts(entry.agent_opts)
    query_opts = Keyword.merge(global.query_opts, agent_query_opts)

    query_opts =
      if system_prompt do
        Keyword.put(query_opts, :system_prompt, system_prompt)
      else
        query_opts
      end

    DynamicSupervisor.terminate_child(@sessions_sup, entry.pid)

    child_spec = %{
      id: :"workshop_agent_#{name}",
      start: {SessionServer, :start_link, [[config: config, query_opts: query_opts]]},
      restart: :temporary
    }

    {:ok, pid} = DynamicSupervisor.start_child(@sessions_sup, child_spec)

    updated = %{
      entry
      | pid: pid,
        status: :idle,
        task: nil,
        task_text: nil,
        cumulative_cost: 0.0,
        turn_count: 0,
        last_result: nil
    }

    :ets.insert(@table, {name, updated})
    :ok
  end

  @doc """
  Stop all agents and clear global config. The nuclear option.

  After this, you'll need to call `configure/1` and `agent/3` again.
  """
  @spec reset_all() :: :ok
  def reset_all do
    ensure_started()
    agents() |> Enum.each(&dismiss/1)
    Agent.update(@state, fn _ -> default_state() end)
    :ok
  end

  @doc """
  Load a Workshop setup file (`.exs`).

  The file is evaluated with `import ClaudeWrapper.Workshop` in scope,
  so it can call `configure/1`, `agent/3`, etc. directly.

  With no argument, looks for `.workshop.exs` in the current directory.

  ## Example file (.workshop.exs)

      configure(working_dir: ".", model: "sonnet",
        context: "Elixir project. Run mix test before committing.")

      agent(:impl, "You write clean code.", max_turns: 15)
      agent(:reviewer, "Review only.", model: "opus",
        allowed_tools: ["Read", "Bash"])

  ## Examples

      load()                        # loads .workshop.exs
      load("setups/review.exs")     # loads a specific file
  """
  @spec load(String.t()) :: :ok | {:error, :not_found}
  def load(path \\ ".workshop.exs") do
    path = Path.expand(path)

    if File.exists?(path) do
      code = "import ClaudeWrapper.Workshop\n" <> File.read!(path)
      Code.eval_string(code, [], file: path)
      print_info("Loaded #{path}")
      :ok
    else
      print_error("File not found: #{path}")
      {:error, :not_found}
    end
  end

  # ── Interaction ───────────────────────────────────────────────

  @doc """
  Send a message and wait for the response. Prints the result when done.

  This is the primary way to talk to an agent. Each call continues the
  agent's conversation (the session ID is threaded automatically).

  If the agent has a pending async task from `cast/2`, waits for it first.

  Returns the agent name on success, enabling `|>` chaining with `pipe/3`:

      ask(:impl, "implement caching")
      |> pipe(:reviewer, "review for edge cases")

  ## Examples

      ask(:impl, "What modules are in this project?")
      ask(:impl, "Now add tests for the retry module")   # continues conversation
      ask(:impl, "What files did you change?")            # still the same session
  """
  @spec ask(atom(), String.t()) :: atom() | {:error, term()}
  def ask(name, prompt) do
    ensure_started()
    consume_pending_task(name)
    do_send_sync(name, prompt)
  end

  @doc """
  Send a message asynchronously. Returns `:ok` immediately.

  The agent works in the background while you do other things.
  Use `status/0` to check progress, `await/1` to collect the result.

  Returns `{:error, :busy}` if the agent is already working on a
  previous `cast`. Call `await/1` first to clear it.

  ## Examples

      cast(:impl, "Implement the caching layer from issue #12")
      cast(:tests, "Add property-based tests for lib/myapp/encoder.ex")

      # Go think about something else...
      status()        # see who's done
      await(:impl)    # block until :impl finishes, prints result
      await_all()     # wait for everyone
  """
  @spec cast(atom(), String.t()) :: :ok | {:error, :busy}
  def cast(name, prompt) do
    ensure_started()
    entry = get_agent!(name)

    if entry.status == :working do
      print_error("#{inspect(name)} is busy. Use await(#{inspect(name)}) first.")
      {:error, :busy}
    else
      # Clean up any completed task before starting new one
      consume_pending_task(name)
      do_send_async(name, prompt)
    end
  end

  @doc """
  Wait for an async agent to finish. Prints the result when done.

  If the agent is already idle, prints a note and returns `:ok`.
  Pass a timeout in milliseconds to avoid blocking forever.

  ## Examples

      cast(:impl, "Work on this")
      # ... later ...
      await(:impl)              # block until done
      await(:impl, 30_000)      # give up after 30 seconds
  """
  @spec await(atom(), timeout()) :: :ok | {:error, term()}
  def await(name, timeout \\ :infinity) do
    ensure_started()
    entry = get_agent!(name)

    case entry.task do
      nil ->
        if entry.status != :working do
          print_info("#{inspect(name)} is idle.")
        end

        :ok

      task ->
        do_await(name, task, timeout)
    end
  end

  @doc """
  Wait for all busy agents to finish. Prints each result as it arrives.

  ## Example

      cast(:impl, "Implement feature")
      cast(:tests, "Write tests")
      await_all()    # blocks until both are done
  """
  @spec await_all(timeout()) :: :ok
  def await_all(timeout \\ :infinity) do
    ensure_started()

    busy =
      :ets.tab2list(@table)
      |> Enum.filter(fn {_name, entry} -> entry.task != nil end)
      |> Enum.map(&elem(&1, 0))

    if busy == [] do
      print_info("All agents idle.")
    else
      Enum.each(busy, fn name -> await(name, timeout) end)
    end

    :ok
  end

  # ── Observability ─────────────────────────────────────────────

  @doc """
  Print a status dashboard showing all agents.

  ## Example output

       agent     | status  | task                                 | cost  | turns
      -----------+---------+--------------------------------------+-------+------
       :impl     | working | Implement the caching layer from ... | $0.08 | 3
       :reviewer | idle    |                                      | $0.00 | 0
       :tests    | idle    |                                      | $0.04 | 2
  """
  @spec status() :: :ok
  def status do
    ensure_started()
    entries = :ets.tab2list(@table) |> Enum.sort_by(&elem(&1, 0))

    if entries == [] do
      print_info("No agents. Use agent(:name, \"role\") to create one.")
    else
      header = {" agent", "status", "task", "cost", "turns"}

      rows =
        Enum.map(entries, fn {name, e} ->
          {
            " #{inspect(name)}",
            to_string(e.status),
            truncate(e.task_text || "", 36),
            format_cost(e.cumulative_cost),
            to_string(e.turn_count)
          }
        end)

      print_table(header, rows)
    end

    :ok
  end

  @doc """
  Get the last response from an agent.

  Returns the response text by default. Pass `:full` to get the
  complete `%Result{}` struct (includes cost, session_id, duration, etc.).

  ## Examples

      result(:impl)          # => "Here is the implementation..."
      result(:impl, :full)   # => %Result{result: "...", cost_usd: 0.04, ...}
  """
  @spec result(atom(), :text | :full) :: String.t() | Result.t() | nil
  def result(name, mode \\ :text)

  def result(name, :full) do
    ensure_started()
    get_agent!(name).last_result
  end

  def result(name, :text) do
    ensure_started()

    case get_agent!(name).last_result do
      nil -> nil
      r -> r.result
    end
  end

  @doc """
  Print the conversation history for an agent.

  Shows each turn with its cost and result text. Use `:last` to
  limit output for long conversations.

  ## Examples

      history(:impl)           # full conversation
      history(:impl, last: 3)  # only the last 3 turns
  """
  @spec history(atom(), keyword()) :: :ok
  def history(name, opts \\ []) do
    ensure_started()
    entry = get_agent!(name)
    turns = SessionServer.history(entry.pid)

    limit = Keyword.get(opts, :last)
    turns = if limit, do: Enum.take(turns, -limit), else: turns

    if turns == [] do
      print_info("#{inspect(name)} has no history.")
    else
      turns
      |> Enum.with_index(1)
      |> Enum.each(&print_turn/1)
    end

    :ok
  end

  @doc """
  Show cost for a single agent. Returns the cost as a float.

  ## Example

      cost(:impl)    # => :impl: $0.12 across 3 turns
  """
  @spec cost(atom()) :: float()
  def cost(name) when is_atom(name) do
    ensure_started()
    entry = get_agent!(name)

    print_info(
      "#{inspect(name)}: #{format_cost(entry.cumulative_cost)} across #{entry.turn_count} turn#{plural(entry.turn_count)}"
    )

    entry.cumulative_cost
  end

  @doc """
  Show itemized costs for all agents, then print the total.

  ## Example

      cost()
      # :impl: $0.12 (3 turns)
      # :reviewer: $0.24 (1 turn)
      # Total: $0.36
  """
  @spec cost() :: float()
  def cost do
    ensure_started()

    :ets.tab2list(@table)
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.each(fn {name, e} ->
      print_info(
        "#{inspect(name)}: #{format_cost(e.cumulative_cost)} (#{e.turn_count} turn#{plural(e.turn_count)})"
      )
    end)

    total_cost()
  end

  @doc """
  Get the total cost across all agents as a single number.
  """
  @spec total_cost() :: float()
  def total_cost do
    ensure_started()

    total =
      :ets.tab2list(@table)
      |> Enum.map(fn {_name, e} -> e.cumulative_cost end)
      |> Enum.sum()

    print_info("Total: #{format_cost(total)}")
    total
  end

  @doc """
  Get detailed info about an agent as a map.

  Returns model, session_id, role, status, cost, turns, and config.

  ## Example

      info(:impl)
      # => %{name: :impl, status: :idle, model: "sonnet", session_id: "abc-123",
      #       cost: 0.04, turns: 1, role: "You write clean code."}
  """
  @spec info(atom()) :: map()
  def info(name) do
    ensure_started()
    entry = get_agent!(name)
    session_id = SessionServer.session_id(entry.pid)

    %{
      name: name,
      status: entry.status,
      model: Keyword.get(entry.query_opts, :model),
      session_id: session_id,
      role: entry.role,
      cost: entry.cumulative_cost,
      turns: entry.turn_count,
      permission_mode: Keyword.get(entry.query_opts, :permission_mode),
      max_turns: Keyword.get(entry.query_opts, :max_turns),
      allowed_tools: Keyword.get(entry.query_opts, :allowed_tools),
      system_prompt: Keyword.get(entry.query_opts, :system_prompt)
    }
  end

  @doc """
  Show the CLI command an agent would run for a given prompt.

  Useful for debugging or copy-pasting to run manually.

  ## Example

      inspect_agent(:impl, "fix the bug")
      # => claude -p "fix the bug" --model sonnet --system-prompt "..." --output-format json
  """
  @spec inspect_agent(atom(), String.t()) :: String.t()
  def inspect_agent(name, prompt \\ "PROMPT") do
    ensure_started()
    entry = get_agent!(name)
    session = SessionServer.get_session(entry.pid)

    query =
      Enum.reduce(entry.query_opts, Query.new(prompt), fn
        {:model, v}, q ->
          Query.model(q, v)

        {:system_prompt, v}, q ->
          Query.system_prompt(q, v)

        {:max_turns, v}, q ->
          Query.max_turns(q, v)

        {:permission_mode, v}, q ->
          Query.permission_mode(q, v)

        {:max_budget_usd, v}, q ->
          Query.max_budget_usd(q, v)

        {:effort, v}, q ->
          Query.effort(q, v)

        {:allowed_tools, tools}, q ->
          Enum.reduce(tools, q, fn t, acc -> Query.allowed_tool(acc, t) end)

        {:disallowed_tools, tools}, q ->
          Enum.reduce(tools, q, fn t, acc -> Query.disallowed_tool(acc, t) end)

        {:dangerously_skip_permissions, true}, q ->
          Query.dangerously_skip_permissions(q)

        {:no_session_persistence, true}, q ->
          Query.no_session_persistence(q)

        _other, q ->
          q
      end)

    # Add --resume if session has an active session_id
    query =
      case Session.session_id(session) do
        nil -> query
        sid -> Query.resume(query, sid)
      end

    # Add --output-format json (what execute actually uses)
    query = Query.output_format(query, :json)

    cmd = Query.to_command_string(query, session.config)
    IO.puts(IO.ANSI.cyan() <> cmd <> IO.ANSI.reset())
    cmd
  end

  # ── Coordination ──────────────────────────────────────────────

  @doc """
  Wait for `from` to finish, then send its last result to `to`.

  The `message` argument frames what `to` should do with the result.
  The forwarded text is appended after your message. Without a message,
  a default framing is used.

  This is synchronous -- it blocks until both agents are done.

  Returns the target agent name on success, so pipes chain:

      ask(:impl, "implement caching")
      |> pipe(:reviewer, "review for edge cases")
      |> pipe(:tests, "write tests for this")

  ## Examples

      # Implement, then review
      ask(:impl, "Implement caching for user lookup")
      pipe(:impl, :reviewer, "Review for cache invalidation edge cases")

      # Or after an async cast
      cast(:impl, "Implement the retry logic")
      # ... do other stuff ...
      pipe(:impl, :tests)   # awaits :impl, sends result to :tests
  """
  @spec pipe(atom() | {:error, term()}, atom(), String.t() | nil) :: atom() | {:error, term()}
  def pipe(from, to, message \\ nil)

  def pipe({:error, _} = err, _to, _message), do: err

  def pipe(from, to, message) when is_atom(from) do
    await(from)
    from_text = result(from)

    if is_nil(from_text) do
      print_error("#{inspect(from)} has no result to pipe.")
      {:error, :no_result}
    else
      text =
        if message do
          "#{message}\n\n#{from_text}"
        else
          "Here is the output from the previous step:\n\n#{from_text}"
        end

      ask(to, text)
    end
  end

  @doc """
  Send the same message to multiple agents in parallel (all via `cast/2`).

  Good for getting multiple perspectives on the same question.

  ## Example

      fan("What issues do you see in lib/myapp/retry.ex?", [:impl, :reviewer])
      # both agents work concurrently
      await_all()
      result(:impl)       # impl's take
      result(:reviewer)   # reviewer's take
  """
  @spec fan(String.t(), [atom()]) :: :ok
  def fan(message, agent_names) when is_list(agent_names) do
    Enum.each(agent_names, fn name -> cast(name, message) end)
    :ok
  end

  # ── Internal: Send ────────────────────────────────────────────

  defp do_send_sync(name, prompt) do
    entry = get_agent!(name)
    update_agent(name, %{entry | status: :working, task_text: truncate(prompt, 36)})

    IO.puts(IO.ANSI.yellow() <> "#{inspect(name)} working..." <> IO.ANSI.reset())

    case SessionServer.send_message(entry.pid, prompt) do
      {:ok, result} ->
        cost = result.cost_usd || 0.0
        current = get_agent!(name)

        update_agent(name, %{
          current
          | status: :idle,
            task_text: nil,
            cumulative_cost: current.cumulative_cost + cost,
            turn_count: current.turn_count + 1,
            last_result: result
        })

        print_result(name, result)
        name

      {:error, reason} = err ->
        current = get_agent!(name)
        update_agent(name, %{current | status: :idle, task_text: nil})
        print_error("#{inspect(name)}: #{inspect(reason)}")
        err
    end
  end

  defp do_send_async(name, prompt) do
    entry = get_agent!(name)
    pid = entry.pid
    agent_name = name

    task =
      Task.Supervisor.async_nolink(@tasks_sup, fn ->
        result =
          try do
            SessionServer.send_message(pid, prompt)
          rescue
            e -> {:error, {:crash, Exception.message(e)}}
          end

        record_async_result(agent_name, result)
        result
      end)

    update_agent(name, %{entry | status: :working, task: task, task_text: truncate(prompt, 36)})
    :ok
  end

  # Update ETS with async task result (called from within the task process)
  defp record_async_result(agent_name, {:ok, result}) do
    case get_agent(agent_name) do
      nil ->
        :ok

      current ->
        update_agent(agent_name, %{
          current
          | status: :idle,
            cumulative_cost: current.cumulative_cost + (result.cost_usd || 0.0),
            turn_count: current.turn_count + 1,
            last_result: result
        })
    end
  end

  defp record_async_result(agent_name, {:error, _}) do
    case get_agent(agent_name) do
      nil -> :ok
      current -> update_agent(agent_name, %{current | status: :idle})
    end
  end

  defp do_await(name, task, timeout) do
    case Task.yield(task, timeout) || Task.shutdown(task) do
      {:ok, {:ok, result}} ->
        current = get_agent!(name)
        update_agent(name, %{current | task: nil, task_text: nil})
        print_result(name, result)
        :ok

      {:ok, {:error, reason}} ->
        current = get_agent!(name)
        update_agent(name, %{current | task: nil, task_text: nil, status: :idle})
        print_error("#{inspect(name)}: #{inspect(reason)}")
        {:error, reason}

      nil ->
        current = get_agent!(name)
        update_agent(name, %{current | task: nil, task_text: nil, status: :idle})
        print_error("#{inspect(name)}: timed out")
        {:error, :timeout}

      {:exit, reason} ->
        current = get_agent!(name)
        update_agent(name, %{current | task: nil, task_text: nil, status: :idle})
        print_error("#{inspect(name)}: #{inspect(reason)}")
        {:error, {:exit, reason}}
    end
  end

  # Consume any pending async task (finished or still running).
  # Used before synchronous sends to avoid stale task state.
  defp consume_pending_task(name) do
    entry = get_agent!(name)

    case entry.task do
      nil ->
        :ok

      task ->
        Task.yield(task, :infinity) || Task.shutdown(task)
        current = get_agent!(name)
        update_agent(name, %{current | task: nil, task_text: nil, status: :idle})
    end
  end

  # ── Internal: Registry ────────────────────────────────────────

  defp get_global_state do
    Agent.get(@state, & &1)
  end

  defp get_agent(name) do
    case :ets.lookup(@table, name) do
      [{^name, entry}] -> entry
      [] -> nil
    end
  end

  defp get_agent!(name) do
    case get_agent(name) do
      nil ->
        raise ArgumentError,
              "unknown agent #{inspect(name)}. Use agent(#{inspect(name)}) to create one."

      entry ->
        entry
    end
  end

  defp update_agent(name, entry) do
    :ets.insert(@table, {name, entry})
  end

  # ── Internal: Helpers ─────────────────────────────────────────

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp validate_opts!(opts) do
    case Keyword.fetch(opts, :permission_mode) do
      {:ok, mode} when mode not in @valid_permission_modes ->
        raise ArgumentError,
              "invalid permission_mode #{inspect(mode)}. " <>
                "Valid modes: #{inspect(@valid_permission_modes)}"

      _ ->
        :ok
    end
  end

  defp compose_system_prompt(context, role) do
    [context, role]
    |> Enum.reject(fn s -> is_nil(s) or String.trim(s) == "" end)
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  # ── Internal: Display ─────────────────────────────────────────

  defp print_result(name, result) do
    IO.puts("")
    IO.puts(result.result)
    IO.puts("")

    cost_str = if result.cost_usd, do: format_cost(result.cost_usd), else: "n/a"

    IO.puts(
      IO.ANSI.yellow() <>
        "(#{inspect(name)}: #{cost_str} this turn)" <>
        IO.ANSI.reset()
    )
  end

  defp print_error(msg) do
    IO.puts(IO.ANSI.red() <> msg <> IO.ANSI.reset())
  end

  defp print_info(msg) do
    IO.puts(IO.ANSI.yellow() <> msg <> IO.ANSI.reset())
  end

  defp format_cost(amount) when is_number(amount) do
    "$#{:erlang.float_to_binary(amount / 1, decimals: 2)}"
  end

  defp format_cost(_), do: "$0.00"

  defp truncate(str, max) do
    if String.length(str) > max do
      String.slice(str, 0, max - 3) <> "..."
    else
      str
    end
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"

  defp print_turn({turn, i}) do
    cost_str = if turn.cost_usd, do: " (#{format_cost(turn.cost_usd)})", else: ""
    error_str = if turn.is_error, do: " [error]", else: ""

    IO.puts(IO.ANSI.cyan() <> "--- Turn #{i}#{cost_str}#{error_str} ---" <> IO.ANSI.reset())
    IO.puts(turn.result)
    IO.puts("")
  end

  defp print_table(header, rows) do
    all = [header | rows]

    widths =
      0..(tuple_size(header) - 1)
      |> Enum.map(fn i ->
        all |> Enum.map(fn row -> String.length(elem(row, i)) end) |> Enum.max()
      end)

    fmt_row = fn row ->
      0..(tuple_size(row) - 1)
      |> Enum.map_join(" | ", fn i -> String.pad_trailing(elem(row, i), Enum.at(widths, i)) end)
    end

    separator = Enum.map_join(widths, "-+-", &String.duplicate("-", &1))

    IO.puts(fmt_row.(header))
    IO.puts(separator)
    Enum.each(rows, fn row -> IO.puts(fmt_row.(row)) end)
  end
end
