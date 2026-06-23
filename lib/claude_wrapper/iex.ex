defmodule ClaudeWrapper.IEx do
  @moduledoc """
  Interactive helpers for conversational use in IEx.

  Provides a minimal, REPL-friendly interface that manages session state
  implicitly so you can just talk to Claude.

  ## Usage

      iex> import ClaudeWrapper.IEx

      iex> chat("explain this codebase", working_dir: ".")
      # => prints response, shows cost, returns the %Result{}

      iex> say("now add tests for the retry module")
      # => continues the conversation

      iex> say("looks good, ship it")
      # => keeps going

      iex> cost()
      # => $0.21 across 3 turns

      iex> history()
      # => prints conversation

      iex> reset()
      # => starts fresh

  ## Configuration

  `configure/1` is the single source of sticky defaults: whatever you set
  there applies to every later `chat/2` and `say/2`. Options passed
  directly to `chat/2` or `say/2` apply to **that call only** and are
  never written back to ambient -- a one-off `attach:` or `model:` won't
  silently ride along on the next turn. Per-call options win over ambient
  for the call they're on.

  Ambient and per-call options both cover config (`:working_dir`,
  `:binary`, `:env`, `:timeout`, `:verbose`, `:debug`), query options
  (`:model`, `:max_turns`, `:permission_mode`, ...), and prompt-composition
  keys (see below).

      configure(model: "sonnet", working_dir: "/my/project")
      chat("hello")                            # uses the ambient sonnet + cwd
      say("do something big", max_turns: 20)   # max_turns: this turn only

  ## Prompt composition

  `chat/2` and `say/2` accept composition keys that build a
  `t:ClaudeWrapper.Prompt.t/0` around the prompt argument before sending:

    * `:attach` -- a path/glob (or list of them) to attach as fenced,
      path-headed code blocks
    * `:git_diff` -- a ref to diff against, or `true`/`nil` for the
      working tree
    * `:prepend` -- text (or list) to place before the prompt
    * `:append` -- text (or list) to place after the context

  When any composition key is present the helper prints a one-line
  `(attached N files, ~K bytes)` notice before the response.

  ## Return values

  `chat/2` and `say/2` return the `t:ClaudeWrapper.Result.t/0` on success
  (after printing it). A CLI failure prints the error and **raises**
  `ClaudeWrapper.Error`. The one non-raising case is calling `say/2` with
  no active session, which prints a hint and returns `:no_session`.
  """

  alias ClaudeWrapper.{Config, Error, History, Prompt, Result, Session}

  @session_key :claude_wrapper_iex_session
  @config_key :claude_wrapper_iex_config
  @history_key :claude_wrapper_iex_history

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose, :debug]
  @composition_keys [:attach, :git_diff, :git_log, :git_status, :prepend, :append, :vars]

  @typedoc "A session row as returned by `sessions/0`."
  @type session_summary :: %{
          id: String.t(),
          first_prompt: String.t() | nil,
          turns: non_neg_integer(),
          last_used: String.t() | nil,
          tokens: non_neg_integer() | nil,
          cost_usd: float() | nil
        }

  @doc """
  Merge options into the ambient configuration (last wins).

  Ambient options are applied to every subsequent `chat/2` and `say/2`
  call, with per-call options overriding them. Accepts config, query, and
  composition keys.

      configure(model: "sonnet", working_dir: ".")
      #=> :ok
  """
  @spec configure(keyword()) :: :ok
  def configure(opts) when is_list(opts) do
    Process.put(@config_key, Keyword.merge(ambient_config(), opts))
    :ok
  end

  @doc """
  Return the current ambient configuration keyword list.
  """
  @spec config() :: keyword()
  def config, do: ambient_config()

  @doc """
  Start a new conversation. Prints the response and returns the
  `t:ClaudeWrapper.Result.t/0`.

  Effective options are the ambient config (see `configure/1`) merged
  with `opts` (per-call wins). Config keys build the session config;
  composition keys build a prompt around `prompt`; everything else is
  forwarded as turn options. Per-call `opts` apply to this turn only and
  are **not** persisted -- use `configure/1` for sticky defaults.

  Raises `ClaudeWrapper.Error` on a CLI/render failure.
  """
  @spec chat(String.t(), keyword()) :: Result.t()
  def chat(prompt, opts \\ []) do
    # Per-call opts apply to THIS turn only; they are never written back to
    # ambient. configure/1 is the single source of sticky defaults, so a
    # one-off attach:/model: here can't silently ride along on later say/2
    # turns. run_turn stores the live session (which carries config
    # forward); ambient carries only configure-set query/composition defaults.
    effective = Keyword.merge(ambient_config(), opts)

    {config_opts, rest} = Keyword.split(effective, @config_keys)
    {composition_opts, query_opts} = Keyword.split(rest, @composition_keys)

    config = Config.new(config_opts)
    session = Session.new(config, query_opts)

    run_turn(session, prompt, composition_opts, [])
  end

  @doc """
  Continue the current conversation. Prints the response and returns the
  `t:ClaudeWrapper.Result.t/0`.

  Per-call `opts` are merged over the ambient query/composition options
  (per-call wins). Returns `:no_session` (with a hint) when no session is
  active; raises `ClaudeWrapper.Error` on a CLI/render failure.
  """
  @spec say(String.t(), keyword()) :: Result.t() | :no_session
  def say(prompt, opts \\ []) do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session. Start one with chat/2.\e[0m")
        :no_session

      session ->
        # Ambient (configure-set) query + composition opts apply to
        # follow-ups; config keys are already baked into the live session,
        # so they're dropped here. Per-call opts win, for this turn only.
        {_config_opts, rest} = Keyword.split(ambient_config(), @config_keys)
        effective = Keyword.merge(rest, opts)
        {composition_opts, query_opts} = Keyword.split(effective, @composition_keys)

        run_turn(session, prompt, composition_opts, query_opts)
    end
  end

  @doc """
  Branch the current conversation into a new session and switch to it.

  Forks the active session (see `ClaudeWrapper.Session.fork/3`), makes the
  branch the current session, prints the response, and returns the
  `t:ClaudeWrapper.Result.t/0`. Raises `ClaudeWrapper.Error` on failure
  (including `:no_session` when there is no active session to fork).
  """
  @spec fork(String.t(), keyword()) :: Result.t()
  def fork(prompt, opts \\ []) do
    case Process.get(@session_key) do
      nil -> raise Error.new(:no_session)
      session -> fork_session(session, prompt, opts)
    end
  end

  @doc """
  Resume `session_id` and immediately branch it into a new session.

  Resumes the given id with the ambient config, forks it, switches to the
  branch, prints the response, and returns the
  `t:ClaudeWrapper.Result.t/0`. Raises `ClaudeWrapper.Error` on failure.
  """
  @spec fork_from(String.t(), String.t(), keyword()) :: Result.t()
  def fork_from(session_id, prompt, opts \\ []) when is_binary(session_id) do
    {config_opts, _rest} = Keyword.split(ambient_config(), @config_keys)
    config = Config.new(config_opts)
    session = Session.resume(config, session_id)
    fork_session(session, prompt, opts)
  end

  @doc """
  List prior sessions for the ambient working directory (most recent
  first).

  Reads Claude Code's on-disk history for the configured `:working_dir`
  (or the current directory when unset). Each row is a map with `:id`,
  `:first_prompt`, `:turns`, `:last_used`, `:tokens`, and `:cost_usd`.
  Returns `[]` when history cannot be read.
  """
  @spec sessions() :: [session_summary()]
  def sessions do
    with {:ok, history} <- history_root(),
         {:ok, summaries} <-
           History.sessions_for_path(history, working_dir(), sort: :recency_desc) do
      Enum.map(summaries, &project_summary/1)
    else
      _ -> []
    end
  end

  @doc """
  Print a numbered list of prior sessions and resume the chosen one.

  Shows each session's turn count, age, and cost (or `—` when unknown),
  reads a selection via `IO.gets/1`, resumes it, and returns the chosen
  id. Empty input returns `:cancelled`.
  """
  @spec pick() :: String.t() | :cancelled
  def pick do
    case sessions() do
      [] ->
        IO.puts("\e[33mNo prior sessions for this directory.\e[0m")
        :cancelled

      summaries ->
        print_pick_list(summaries)
        read_pick_choice(summaries)
    end
  end

  @doc """
  Snapshot of the current session: `%{id, turns, cost_usd}` or `nil`.
  """
  @spec current() :: %{id: String.t() | nil, turns: non_neg_integer(), cost_usd: float()} | nil
  def current do
    case Process.get(@session_key) do
      nil ->
        nil

      session ->
        %{
          id: Session.session_id(session),
          turns: Session.turn_count(session),
          cost_usd: Session.total_cost(session)
        }
    end
  end

  @doc """
  Show total cost and turn count for the current session.
  """
  @spec cost() :: float() | :no_session
  def cost do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        :no_session

      session ->
        total = Session.total_cost(session)
        turns = Session.turn_count(session)
        IO.puts("\e[33m#{format_cost(total)} across #{turns} turn#{plural(turns)}\e[0m")
        total
    end
  end

  @doc """
  Print the conversation history.
  """
  @spec history() :: :ok | :no_session
  def history do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        :no_session

      session ->
        session |> Session.turns() |> print_history()
        :ok
    end
  end

  @doc """
  Reset the session and ambient config (start fresh on next `chat/2`).
  """
  @spec reset() :: :ok
  def reset do
    Process.delete(@session_key)
    Process.delete(@config_key)
    IO.puts("\e[33mSession cleared.\e[0m")
    :ok
  end

  @doc """
  Get the session ID (for resuming later).
  """
  @spec session_id() :: String.t() | nil
  def session_id do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.session_id(session)
    end
  end

  @doc """
  Resume a previous session by ID.

  Uses the ambient config (or pass new config/query options).
  """
  @spec resume(String.t(), keyword()) :: :ok
  def resume(sid, opts \\ []) do
    {config_opts, query_opts} = split_opts(opts)

    config =
      if config_opts == [] do
        Config.new(elem(Keyword.split(ambient_config(), @config_keys), 0))
      else
        Config.new(config_opts)
      end

    session = Session.resume(config, sid, query_opts)
    Process.put(@session_key, session)
    IO.puts("\e[33mResumed session #{sid}\e[0m")
    :ok
  end

  @doc """
  Get the last result struct (for programmatic access).
  """
  @spec last() :: Result.t() | nil
  def last do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.last_result(session)
    end
  end

  # --- turn execution -----------------------------------------------

  # Build the prompt (plain or composed), send it, and on success store
  # the session, print the result, and return the %Result{}. A failure
  # prints and raises.
  defp run_turn(session, prompt, composition_opts, query_opts) do
    IO.puts("\e[33m...\e[0m")

    {to_send, notice} = build_prompt(prompt, composition_opts)

    case Session.send(session, to_send, query_opts) do
      {:ok, new_session, result} ->
        Process.put(@session_key, new_session)
        if notice, do: IO.puts("\e[33m#{notice}\e[0m")
        print_result(result, new_session)
        result

      {:error, %Error{} = error} ->
        IO.puts("\e[31mError: #{Exception.message(error)}\e[0m")
        raise error
    end
  end

  # No composition keys -> send the raw string, no notice. Otherwise build
  # a %Prompt{}, render it now to both produce the notice and hand a plain
  # string to Session.send (single render). A render error short-circuits
  # to a raised ClaudeWrapper.Error via the caller.
  defp build_prompt(prompt, []), do: {prompt, nil}

  defp build_prompt(prompt, composition_opts) do
    built = compose(Prompt.new(prompt), composition_opts)

    case Prompt.render(built) do
      {:ok, rendered} -> {rendered, attach_notice(built, rendered)}
      {:error, %Error{} = error} -> raise error
    end
  end

  defp compose(prompt, opts) do
    Enum.reduce(opts, prompt, &apply_composition/2)
  end

  defp apply_composition({:prepend, values}, prompt),
    do: reduce_strings(prompt, values, &Prompt.prepend/2)

  defp apply_composition({:append, values}, prompt),
    do: reduce_strings(prompt, values, &Prompt.append/2)

  defp apply_composition({:attach, values}, prompt),
    do: reduce_strings(prompt, values, &Prompt.attach/2)

  defp apply_composition({:git_diff, false}, prompt), do: prompt
  defp apply_composition({:git_diff, true}, prompt), do: Prompt.git_diff(prompt, nil)
  defp apply_composition({:git_diff, ref}, prompt), do: Prompt.git_diff(prompt, ref)

  defp apply_composition({:git_log, false}, prompt), do: prompt
  defp apply_composition({:git_log, true}, prompt), do: Prompt.git_log(prompt)

  defp apply_composition({:git_log, n}, prompt) when is_integer(n),
    do: Prompt.git_log(prompt, n: n)

  defp apply_composition({:git_status, false}, prompt), do: prompt
  defp apply_composition({:git_status, _}, prompt), do: Prompt.git_status(prompt)

  defp apply_composition({:vars, vars}, prompt), do: Prompt.vars(prompt, vars)

  # A composition value may be a single string or a list of them.
  defp reduce_strings(prompt, values, fun) when is_list(values) do
    Enum.reduce(values, prompt, fn v, acc -> fun.(acc, v) end)
  end

  defp reduce_strings(prompt, value, fun), do: fun.(prompt, value)

  # Count the attached file blocks (each starts with a "# <path>" header
  # line) and the rendered byte size for the one-line notice.
  defp attach_notice(%Prompt{context: context}, rendered) do
    attaches = Enum.count(context, &match?({:attach, _}, &1))

    if attaches == 0 do
      nil
    else
      # Count attach headers (`# <path>`) only -- git context blocks now
      # carry `# git <cmd>` headers too, which must not inflate the count.
      files =
        rendered
        |> String.split("\n")
        |> Enum.count(&(String.starts_with?(&1, "# ") and not String.starts_with?(&1, "# git ")))

      "(attached #{files} file#{plural(files)}, ~#{kb(byte_size(rendered))})"
    end
  end

  defp kb(bytes), do: "#{Float.round(bytes / 1024, 1)}KB"

  # --- fork helpers -------------------------------------------------

  defp fork_session(session, prompt, opts) do
    IO.puts("\e[33m... (forking)\e[0m")

    case Session.fork(session, prompt, opts) do
      {:ok, branch, result} ->
        Process.put(@session_key, branch)
        print_result(result, branch)
        result

      {:error, %Error{} = error} ->
        IO.puts("\e[31mError: #{Exception.message(error)}\e[0m")
        raise error
    end
  end

  # --- history / pick helpers ---------------------------------------

  defp history_root do
    case Process.get(@history_key) do
      %History{} = h ->
        {:ok, h}

      _ ->
        case History.home() do
          {:ok, h} ->
            Process.put(@history_key, h)
            {:ok, h}

          {:error, _} = err ->
            err
        end
    end
  end

  defp project_summary(summary) do
    %{
      id: summary.session_id,
      first_prompt: summary.first_user_preview,
      turns: summary.message_count,
      last_used: summary.last_timestamp,
      tokens: summary.total_tokens,
      cost_usd: summary.total_cost_usd
    }
  end

  defp print_pick_list(summaries) do
    summaries
    |> Enum.with_index(1)
    |> Enum.each(fn {s, i} ->
      IO.puts(
        "\e[36m#{i})\e[0m #{s.turns} turn#{plural(s.turns)}  #{age(s.last_used)}  #{pick_cost(s.cost_usd)}  #{pick_preview(s.first_prompt)}"
      )
    end)
  end

  defp read_pick_choice(summaries) do
    case IO.gets("Pick a session (number, blank to cancel): ") do
      :eof -> :cancelled
      input -> resolve_pick(String.trim(to_string(input)), summaries)
    end
  end

  defp resolve_pick("", _summaries), do: :cancelled

  defp resolve_pick(input, summaries) do
    case Integer.parse(input) do
      {n, ""} when n >= 1 -> pick_index(summaries, n)
      _ -> invalid_pick()
    end
  end

  defp pick_index(summaries, n) do
    case Enum.at(summaries, n - 1) do
      nil ->
        invalid_pick()

      %{id: id} ->
        resume(id)
        id
    end
  end

  defp invalid_pick do
    IO.puts("\e[31mInvalid selection.\e[0m")
    :cancelled
  end

  defp pick_cost(nil), do: "—"
  defp pick_cost(cost), do: format_cost(cost)

  defp pick_preview(nil), do: ""
  defp pick_preview(preview), do: preview

  # Best-effort relative age from an ISO-8601 timestamp string.
  defp age(nil), do: "(unknown)"

  defp age(timestamp) when is_binary(timestamp) do
    case DateTime.from_iso8601(timestamp) do
      {:ok, dt, _offset} -> relative_age(DateTime.diff(DateTime.utc_now(), dt, :second))
      _ -> "(unknown)"
    end
  end

  defp relative_age(seconds) when seconds < 60, do: "just now"
  defp relative_age(seconds) when seconds < 3600, do: "#{div(seconds, 60)}m ago"
  defp relative_age(seconds) when seconds < 86_400, do: "#{div(seconds, 3600)}h ago"
  defp relative_age(seconds), do: "#{div(seconds, 86_400)}d ago"

  # --- print helpers ------------------------------------------------

  defp print_history([]) do
    IO.puts("\e[33mNo turns yet.\e[0m")
  end

  defp print_history(turns) do
    turns
    |> Enum.with_index(1)
    |> Enum.each(&print_turn/1)
  end

  defp print_turn({result, i}) do
    cost_str = if result.cost_usd, do: " (#{format_cost(result.cost_usd)})", else: ""
    error_str = if result.is_error, do: " \e[31m[error]\e[0m", else: ""

    IO.puts("\e[36m--- Turn #{i}#{cost_str}#{error_str} ---\e[0m")
    IO.puts(result.result)
    IO.puts("")
  end

  defp print_result(%Result{} = result, session) do
    IO.puts("")
    IO.puts(result.result)
    IO.puts("")

    cost_str = format_cost(result.cost_usd)
    total = Session.total_cost(session)
    turns = Session.turn_count(session)

    meta =
      if turns > 1 do
        "\e[33m(#{cost_str} this turn, #{format_cost(total)} total, #{turns} turns)\e[0m"
      else
        "\e[33m(#{cost_str}, #{turns} turn)\e[0m"
      end

    IO.puts(meta)
  end

  # Cost arrives from the CLI as either a float (typical) or an integer
  # zero (when a turn finishes without billing -- e.g. cache-only or
  # interrupted very early). Float.round/2 raises FunctionClauseError on
  # an integer; coerce by adding 0.0 so both shapes format the same way.
  # Reported in #64.
  @doc false
  @spec format_cost(number() | nil) :: String.t()
  def format_cost(nil), do: "?"
  def format_cost(cost) when is_number(cost), do: "$#{Float.round(cost + 0.0, 4)}"

  # --- opt / ambient helpers ----------------------------------------

  defp ambient_config, do: Process.get(@config_key, [])

  defp working_dir do
    Keyword.get(ambient_config(), :working_dir) || File.cwd!()
  end

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
