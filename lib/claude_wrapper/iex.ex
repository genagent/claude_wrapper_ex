defmodule ClaudeWrapper.IEx do
  @moduledoc """
  Interactive helpers for conversational use in IEx.

  Provides a minimal, REPL-friendly interface that manages session state
  implicitly so you can just talk to Claude.

  ## Usage

      iex> import ClaudeWrapper.IEx

      iex> chat("explain this codebase", working_dir: ".")
      # => prints response, shows cost

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

  Pass options to `chat/2` to configure the session. These persist for
  subsequent `say/2` calls:

      chat("hello", model: "sonnet", working_dir: "/my/project", max_turns: 5)

  Override per-turn with `say/2`:

      say("do something expensive", max_turns: 20)
  """

  alias ClaudeWrapper.{Config, Result, Session}

  @session_key :claude_wrapper_iex_session
  @config_key :claude_wrapper_iex_config

  @doc """
  Start a new conversation. Prints the response.

  Accepts all options from `ClaudeWrapper.query/2` -- config options
  (`:working_dir`, `:binary`, `:env`, `:timeout`, `:verbose`, `:debug`)
  and query options (`:model`, `:max_turns`, `:permission_mode`, etc.).
  """
  def chat(prompt, opts \\ []) do
    {config_opts, query_opts} = split_opts(opts)
    config = Config.new(config_opts)
    session = Session.new(config, query_opts)

    Process.put(@config_key, config)

    do_send(session, prompt, [])
  end

  @doc """
  Continue the current conversation. Prints the response.

  Accepts per-turn query option overrides.
  """
  def say(prompt, opts \\ []) do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session. Start one with chat/2.\e[0m")
        :no_session

      session ->
        do_send(session, prompt, opts)
    end
  end

  @doc """
  Show total cost and turn count for the current session.
  """
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
  Reset the session (start fresh on next `chat/2`).
  """
  def reset do
    Process.delete(@session_key)
    Process.delete(@config_key)
    IO.puts("\e[33mSession cleared.\e[0m")
    :ok
  end

  @doc """
  Get the session ID (for resuming later).
  """
  def session_id do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.session_id(session)
    end
  end

  @doc """
  Resume a previous session by ID.

  Uses the same config as the last `chat/2` call, or pass new options.
  """
  def resume(sid, opts \\ []) do
    {config_opts, query_opts} = split_opts(opts)

    config =
      if config_opts == [] do
        Process.get(@config_key) || Config.new()
      else
        Config.new(config_opts)
      end

    session = Session.resume(config, sid, query_opts)
    Process.put(@session_key, session)
    Process.put(@config_key, config)
    IO.puts("\e[33mResumed session #{sid}\e[0m")
    :ok
  end

  @doc """
  Get the last result struct (for programmatic access).
  """
  def last do
    case Process.get(@session_key) do
      nil -> nil
      session -> Session.last_result(session)
    end
  end

  # --- Private ---

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

  defp do_send(session, prompt, opts) do
    IO.puts("\e[33m...\e[0m")

    case Session.send(session, prompt, opts) do
      {:ok, new_session, result} ->
        Process.put(@session_key, new_session)
        print_result(result, new_session)
        :ok

      {:error, reason} ->
        IO.puts("\e[31mError: #{inspect(reason)}\e[0m")
        {:error, reason}
    end
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

  @config_keys [:binary, :working_dir, :env, :timeout, :verbose, :debug]

  defp split_opts(opts) do
    Enum.split_with(opts, fn {k, _v} -> k in @config_keys end)
  end

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
