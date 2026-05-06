defmodule ClaudeWrapper.DuplexIEx do
  @moduledoc """
  Interactive helpers for driving `ClaudeWrapper.DuplexSession` from IEx.

  Spawns a long-lived `claude` subprocess, holds it across many turns,
  and prints streaming text deltas to stdout as they arrive. Sibling to
  `ClaudeWrapper.IEx`, which uses the simpler per-call `Query`/`Session`
  flow.

  ## Usage

      iex> import ClaudeWrapper.DuplexIEx

      iex> start(working_dir: ".")
      Claude session started.

      iex> say("Explain the README briefly.")
      ...streams text...
      ($0.0123, 1 turn)
      :ok

      iex> say("Now suggest a one-line tagline.")
      ...streams text...
      :ok

      iex> interrupt()
      :ok

      iex> close()
      :ok

  ## When to use this vs `ClaudeWrapper.IEx`

  Both are interactive REPL surfaces. `ClaudeWrapper.IEx` (the
  pre-existing one) spawns a fresh `claude` subprocess per turn and is
  the simplest thing that works for casual use. `ClaudeWrapper.DuplexIEx`
  holds one subprocess open, so subsequent turns avoid CLI cold start
  and the experience feels more like talking to a chat UI -- partial
  tokens appear as they're generated, mid-turn cancel via `interrupt/0`
  is clean, and a permission callback can react to tool requests in
  flight.

  ## Defaults

  - Working dir defaults to `File.cwd!()` so the session sees your
    current project
  - Permission mode defaults to `"bypassPermissions"` so tool calls
    just work in the REPL without a permission callback. **This is
    not safe** for prompts you do not control. For trustworthy use,
    pass `permission_mode: "default"` and an `on_permission` callback
  - All `ClaudeWrapper.Config` options (`:binary`, `:env`, `:timeout`,
    etc.) are accepted and forwarded to `ClaudeWrapper.Config.new/1`
  - All `ClaudeWrapper.DuplexSession` options (`:on_permission`,
    `:extra_args`) are forwarded as well
  """

  alias ClaudeWrapper.{Config, DuplexSession, Result}

  @session_key :claude_wrapper_duplex_iex_session
  @printer_key :claude_wrapper_duplex_iex_printer

  # --- Public API -----------------------------------------------------

  @doc """
  Start a new duplex session and a streaming printer process.

  Stores the session pid and printer pid in the process dictionary
  for the rest of the helpers to find. If a session is already
  running for this process, it is closed first.
  """
  @spec start(keyword()) :: :ok | {:error, term()}
  def start(opts \\ []) do
    if Process.get(@session_key), do: close()

    {config_opts, duplex_opts} = split_opts(opts)

    config_opts =
      Keyword.put_new_lazy(config_opts, :working_dir, fn -> File.cwd!() end)

    config = Config.new(config_opts)

    extra_args =
      duplex_opts
      |> Keyword.get(:extra_args, [])
      |> ensure_permission_mode(duplex_opts)

    duplex_opts =
      duplex_opts
      |> Keyword.delete(:extra_args)
      |> Keyword.put(:config, config)
      |> Keyword.put(:extra_args, extra_args)

    case DuplexSession.start_link(duplex_opts) do
      {:ok, pid} ->
        printer = spawn_printer(pid)
        Process.put(@session_key, pid)
        Process.put(@printer_key, printer)
        IO.puts("\e[33mClaude session started.\e[0m")
        :ok

      {:error, _} = err ->
        err
    end
  end

  @doc """
  Send a prompt in the current session. Streaming text is printed as
  it arrives. Returns `:ok` on success or `{:error, reason}` on failure.

  Per-call options:
    * `:timeout` -- override the 120-second default for this turn

  All other options are ignored at this layer; pass DuplexSession
  options (such as `:on_permission`) to `start/1` instead.
  """
  @spec say(String.t(), keyword()) :: :ok | {:error, term()}
  def say(prompt, opts \\ []) when is_binary(prompt) do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session. Start one with start/1.\e[0m")
        {:error, :no_session}

      pid ->
        timeout = Keyword.get(opts, :timeout, 120_000)

        case DuplexSession.send(pid, prompt, timeout) do
          {:ok, %Result{} = result} ->
            print_meta(result)
            :ok

          {:error, reason} ->
            IO.puts("\e[31mError: #{inspect(reason)}\e[0m")
            {:error, reason}
        end
    end
  end

  @doc """
  Cancel the current in-flight turn. Returns `:ok` once the CLI
  acknowledges, or `{:error, reason}` if no session is running.
  """
  @spec interrupt(timeout()) :: :ok | {:error, term()}
  def interrupt(timeout \\ 10_000) do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        {:error, :no_session}

      pid ->
        DuplexSession.interrupt(pid, timeout)
    end
  end

  @doc """
  Close the current session, kill the printer, and clear stored state.

  Named `close/0` (rather than the more obvious `stop/0`) to avoid
  colliding with `ClaudeWrapper.Workshop.stop/0` when both modules are
  imported. Mirrors the underlying `ClaudeWrapper.DuplexSession.close/1`.
  """
  @spec close() :: :ok
  def close do
    if printer = Process.delete(@printer_key) do
      Process.exit(printer, :shutdown)
    end

    if pid = Process.delete(@session_key) do
      try do
        DuplexSession.close(pid)
      catch
        :exit, _ -> :ok
      end
    end

    IO.puts("\e[33mSession closed.\e[0m")
    :ok
  end

  @doc """
  Print the current session's id and pid.
  """
  @spec status() :: :ok | :no_session
  def status do
    case Process.get(@session_key) do
      nil ->
        IO.puts("\e[31mNo active session.\e[0m")
        :no_session

      pid ->
        sid = DuplexSession.session_id(pid)
        IO.puts("\e[33mSession #{sid || "<not yet initialized>"} (#{inspect(pid)})\e[0m")
        :ok
    end
  end

  @doc """
  Return the CLI session id for resuming later, or `nil` if no
  session is running.
  """
  @spec session_id() :: String.t() | nil
  def session_id do
    case Process.get(@session_key) do
      nil -> nil
      pid -> DuplexSession.session_id(pid)
    end
  end

  @doc """
  Return the raw `DuplexSession` pid for direct API access, or `nil`.
  """
  @spec pid() :: pid() | nil
  def pid, do: Process.get(@session_key)

  # --- Printer process -----------------------------------------------

  # The printer subscribes to the session and writes incremental text
  # to stdout. Running it in a separate process keeps the user's IEx
  # mailbox clean and isolates the GenServer from any IO failure.
  @doc false
  def spawn_printer(session_pid) do
    parent = self()

    spawn_link(fn ->
      Process.flag(:trap_exit, true)
      :ok = DuplexSession.subscribe(session_pid)
      Kernel.send(parent, :printer_subscribed)
      printer_loop()
    end)
    |> tap(fn _printer ->
      receive do
        :printer_subscribed -> :ok
      after
        2_000 -> :ok
      end
    end)
  end

  defp printer_loop do
    receive do
      {:claude, event} ->
        handle_event(event)
        printer_loop()

      {:EXIT, _from, _reason} ->
        :ok

      :stop ->
        :ok

      _ ->
        printer_loop()
    end
  end

  @doc false
  def handle_event({:stream_event, %{"event" => %{"delta" => %{"text" => text}}}})
      when is_binary(text) do
    IO.write(text)
  end

  def handle_event({:stream_event, _other}), do: :ok

  def handle_event({:assistant, _msg}), do: :ok

  def handle_event({:user, %{"message" => %{"content" => content}}}) when is_list(content) do
    Enum.each(content, fn
      %{"type" => "tool_result", "content" => parts} when is_list(parts) ->
        text =
          Enum.map_join(parts, "", fn
            %{"type" => "text", "text" => t} -> t
            _ -> ""
          end)

        if text != "", do: IO.write("\n\e[2m[tool] #{truncate(text, 200)}\e[0m\n")

      _ ->
        :ok
    end)
  end

  def handle_event({:user, _other}), do: :ok

  def handle_event({:system_init, sid}) do
    IO.puts("\e[2m[session #{sid}]\e[0m")
  end

  def handle_event({:result, _result}) do
    # The final newline + cost meta is printed by the say/2 caller via
    # print_meta/1; the printer just stops accumulating text here.
    IO.puts("")
  end

  def handle_event(_other), do: :ok

  # --- Private --------------------------------------------------------

  defp print_meta(%Result{} = result) do
    cost_str = format_cost(result.cost_usd)
    turns_str = "#{result.num_turns || 1} turn#{plural(result.num_turns || 1)}"

    IO.puts("\e[33m(#{cost_str}, #{turns_str})\e[0m")
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

  defp ensure_permission_mode(extra_args, duplex_opts) do
    cond do
      "--permission-mode" in extra_args or "--dangerously-skip-permissions" in extra_args ->
        extra_args

      Keyword.has_key?(duplex_opts, :on_permission) ->
        # Caller has provided a callback; let the CLI default to the
        # mode that prompts (i.e., "default") so the callback fires.
        ["--permission-mode", "default" | extra_args]

      true ->
        # No callback and no explicit mode: skip permissions entirely
        # for REPL ergonomics. This matches the existing IEx test
        # behavior. Pass --permission-mode "default" + an
        # :on_permission callback for trustworthy use.
        ["--dangerously-skip-permissions" | extra_args]
    end
  end

  defp truncate(s, max) when byte_size(s) <= max, do: s
  defp truncate(s, max), do: binary_part(s, 0, max - 1) <> "…"

  defp plural(1), do: ""
  defp plural(_), do: "s"
end
