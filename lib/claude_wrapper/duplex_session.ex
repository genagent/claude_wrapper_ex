defmodule ClaudeWrapper.DuplexSession do
  @moduledoc """
  Long-lived `claude` session over the CLI's stream-json duplex protocol.

  Holds a single `claude` subprocess open across many turns, communicating
  via NDJSON on stdin/stdout. Complementary to `ClaudeWrapper.Query` and
  `ClaudeWrapper.Session` -- those spawn one subprocess per turn and are
  the right fit for short-lived hosts (escripts, mix tasks, batch jobs).
  `DuplexSession` is for long-running hosts (Phoenix servers, agent
  runtimes, OTP applications) where holding a `claude` open across turns
  is cheap.

  This is the mode `@anthropic-ai/claude-agent-sdk` uses internally and
  that the `@agentclientprotocol/claude-agent-acp` bridge relies on for
  IDE integrations like Zed's agent panel.

  See `https://github.com/genagent/claude_wrapper_ex/issues/55` for the
  full design discussion and phased rollout.

  ## Usage

      config = ClaudeWrapper.Config.new()

      # Provide a permission callback to decide on tool use mid-turn.
      # The default is to deny everything.
      on_permission = fn tool_name, _input ->
        if tool_name in ["Bash", "Edit"], do: {:deny, "not allowed"}, else: :allow
      end

      {:ok, pid} =
        ClaudeWrapper.DuplexSession.start_link(
          config: config,
          on_permission: on_permission
        )

      # Subscribe the calling process to streaming events.
      :ok = ClaudeWrapper.DuplexSession.subscribe(pid)

      {:ok, result} = ClaudeWrapper.DuplexSession.send(pid, "Say hi.")

      ClaudeWrapper.DuplexSession.stop(pid)

  ## Permission callback

  The optional `:on_permission` callback runs synchronously inside the
  GenServer when the CLI emits a `can_use_tool` control request. Two
  arities are supported and detected at call time:

    * `(tool_name, input) -> decision` -- when the decision can be made
      from the tool name and input alone (allow/deny lists, role-based
      policy, etc.).

    * `(tool_name, input, request_id) -> decision` -- when the handler
      may return `:defer` and a separate process needs to call
      `respond_to_permission/3` later. The `request_id` lets the
      handler correlate the deferred response with the original
      request (e.g. broadcast `{:permission_request, request_id, ...}`
      to a UI; the UI eventually answers via `respond_to_permission/3`).

  The decision is one of:

    * `:allow` -- allow the tool with the original input
    * `{:allow, updated_input}` -- allow the tool with a modified input
      map (sandbox a path, redact a secret, etc.)
    * `{:deny, reason}` -- deny the tool with a reason string the model
      will see
    * `:defer` -- do not respond synchronously; the caller is expected
      to invoke `respond_to_permission/3` later

  The callback runs in the GenServer process, so synchronous decisions
  must be fast. For slow decisions, return `:defer` and answer later.

  The default callback is `&deny_all/2`, which denies every tool call.
  Without an explicit callback or one of the CLI's other permission
  modes (`plan`, `bypass_permissions`, etc.) tool use will not work.

  ## Subscriber events

  Subscribers receive plain messages of the form `{:claude, event}`:

    * `{:system_init, session_id}` -- the CLI's init event
    * `{:assistant, msg}` -- a full assistant turn (`SDKAssistantMessage`)
    * `{:stream_event, msg}` -- a partial assistant token
      (`SDKPartialAssistantMessage`)
    * `{:user, msg}` -- a user message (e.g. tool results, replays)
    * `{:result, %ClaudeWrapper.Result{}}` -- the parsed turn boundary

  Subscribers are monitored; if a subscriber crashes or exits, it is
  automatically removed.

  > #### Subscriber delivery has no capacity bound {: .info}
  >
  > The Rust crate backs `subscribe` with a bounded
  > `tokio::sync::broadcast` channel (default capacity 256) and slow
  > consumers observe a `Lagged` error. The Elixir session instead
  > delivers each event with `Process.send/3` straight into every
  > subscriber's process mailbox, which is unbounded, so there is no
  > `subscriber_capacity` knob and no lag/drop semantics: a slow
  > subscriber simply accumulates messages in its own mailbox. Apply
  > back-pressure at the subscriber (drain promptly, or unsubscribe)
  > if that is a concern.

  ## Health and liveness

  `alive?/1`, `exit_status/1`, and `wait_for_exit/2` give service-shaped
  hosts non-consuming visibility into whether a session is still usable,
  mirroring the Rust crate's `is_alive` / `exit_status` / `wait_for_exit`
  (`SessionExitStatus`). See `t:exit_status/0`.

  `wait_for_exit/2` is the authoritative source of the terminal status:
  it blocks until the session exits and returns `:completed` for a clean
  shutdown or `{:failed, {:port_exit, code}}` when the underlying
  `claude` subprocess exits with a non-zero status (or the port closes
  abnormally). The status is delivered live from `terminate/2`, so there
  is no persisted state and nothing to read post-mortem.

  `exit_status/1` is only a *live snapshot*: it reports `:running` while
  the session process is alive and `:completed` once the process is
  gone. It cannot distinguish a clean exit from a failed one after the
  fact -- use `wait_for_exit/2` if you need the failure reason.
  """

  use GenServer
  require Logger

  alias ClaudeWrapper.{Config, Error, Query, Result}
  alias ClaudeWrapper.DuplexSession.Adapter

  @type tool_input :: map()

  @type permission_decision ::
          :allow
          | {:allow, tool_input()}
          | {:deny, String.t()}
          | :defer

  @typedoc """
  Permission decision callback. Two arities are supported:

    * `(tool_name, input) -> decision` -- the original signature.
      Use when the decision can be made from the tool name and input
      alone (allow/deny lists, role-based policy, etc.).

    * `(tool_name, input, request_id) -> decision` -- carries the
      `request_id` of the inbound `can_use_tool` control request.
      Required if the handler returns `:defer` and a different
      process needs to call `respond_to_permission/3` later (chat
      UI: handler broadcasts the request to a LiveView, which
      surfaces approve/deny and answers asynchronously).

  Arity is detected at call time so existing 2-arity callbacks keep
  working unchanged.
  """
  @type permission_handler ::
          (String.t(), tool_input() -> permission_decision())
          | (String.t(), tool_input(), String.t() -> permission_decision())

  @type option ::
          {:config, Config.t()}
          | {:query, Query.t()}
          | {:extra_args, [String.t()]}
          | {:on_permission, permission_handler()}
          | {:name, GenServer.name()}
          | GenServer.option()

  @typedoc """
  Terminal liveness status of a session, mirroring the Rust crate's
  `SessionExitStatus`:

    * `:running` -- the session process is alive and usable.
    * `:completed` -- the session shut down cleanly (graceful
      `stop/3`/`close/1`, or the `claude` subprocess exited with status
      `0`).
    * `{:failed, reason}` -- the `claude` subprocess exited abnormally
      (non-zero status, or the port closed with an error reason). The
      `reason` is the recorded `{:port_exit, code | term}` tuple.
  """
  @type exit_status :: :running | :completed | {:failed, term()}

  @type state :: %__MODULE__{
          port: Adapter.handle() | nil,
          adapter: module(),
          config: Config.t(),
          session_id: String.t() | nil,
          buffer: binary(),
          pending_turn: {GenServer.from(), [map()]} | nil,
          pending_control: %{String.t() => GenServer.from()},
          subscribers: %{pid() => reference()},
          on_permission: permission_handler(),
          exit_status: exit_status(),
          exit_waiters: %{reference() => pid()}
        }

  defstruct [
    :port,
    :adapter,
    :config,
    :session_id,
    :on_permission,
    buffer: <<>>,
    pending_turn: nil,
    pending_control: %{},
    subscribers: %{},
    exit_status: :running,
    exit_waiters: %{}
  ]

  # --- Public API ------------------------------------------------------

  @doc """
  Start a duplex session.

  ## Options

    * `:config` -- (required) `%ClaudeWrapper.Config{}` struct.
    * `:query` -- a `%ClaudeWrapper.Query{}` whose spawn-time knobs
      (model, system prompt, permission mode, tool allow/deny lists,
      mcp config, effort, turn/budget caps, session continuity, ...)
      configure the session. Built with the same `Query` setters and
      `apply_opts/2` as the one-shot path; the query's prompt and
      transport-format flags are ignored (the session owns its
      stream-json transport and takes prompts per turn via `send/3`).
      See `ClaudeWrapper.Query.spawn_args/1`.
    * `:extra_args` -- extra CLI flags to append, applied after the
      `:query` flags (e.g. `["--permission-mode", "plan"]`). The
      escape hatch for flags not yet on `Query`.
    * `:name` -- register the GenServer under a name.

  All other keyword options are passed through to `GenServer.start_link/3`.

  ## Examples

      query =
        ClaudeWrapper.Query.new("")
        |> ClaudeWrapper.Query.model("sonnet")
        |> ClaudeWrapper.Query.allowed_tool("Read")
        |> ClaudeWrapper.Query.max_turns(20)

      {:ok, pid} =
        ClaudeWrapper.DuplexSession.start_link(config: config, query: query)
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc """
  Send a user prompt. Blocks until the turn's `result` event arrives.

  Returns `{:ok, %Result{}}` on success, `{:error,
  %ClaudeWrapper.Error{kind: :turn_in_flight}}` if another turn is
  already running, or `{:error, %ClaudeWrapper.Error{}}` on failure.

  The default `timeout` is 120 seconds because the entire turn duration
  must complete within it (cold start + model latency + tool calls).
  """
  @spec send(GenServer.server(), String.t(), timeout()) ::
          {:ok, Result.t()} | {:error, term()}
  def send(server, prompt, timeout \\ 120_000) when is_binary(prompt) do
    GenServer.call(server, {:send, prompt}, timeout)
  end

  @doc """
  Return the session ID assigned by the CLI on `system/init`, or `nil`
  if init has not yet been observed.
  """
  @spec session_id(GenServer.server()) :: String.t() | nil
  def session_id(server), do: GenServer.call(server, :session_id)

  @doc """
  Subscribe the calling process to streaming events.

  Subscribers receive plain `{:claude, event}` messages -- see the
  module doc for the event vocabulary. The subscriber is monitored;
  if it exits, it is automatically removed.

  Subscribing the same process twice is a no-op.
  """
  @spec subscribe(GenServer.server()) :: :ok
  def subscribe(server), do: GenServer.call(server, {:subscribe, self()})

  @doc """
  Stop sending events to the calling process. Idempotent.
  """
  @spec unsubscribe(GenServer.server()) :: :ok
  def unsubscribe(server), do: GenServer.call(server, {:unsubscribe, self()})

  @doc """
  Answer a deferred permission request.

  Used after the `:on_permission` callback returned `:defer` for the
  given `request_id`. Calling this with a `request_id` the session has
  no record of is a no-op (returns `:ok`). The `decision` accepts the
  same shape as a synchronous handler return value, except `:defer`,
  which is rejected with `{:error, %ClaudeWrapper.Error{kind:
  :cannot_defer_again}}`.

  > #### `:allow` and `updatedInput` {: .info}
  >
  > A synchronous handler returning plain `:allow` has its `updatedInput`
  > defaulted to the original tool input automatically, since the
  > dispatch site has the input in scope. The deferred path does not --
  > the session does not retain per-request input across the defer
  > boundary. If you need `updatedInput` populated (Claude's permission
  > protocol requires it for `behavior: "allow"`), capture the input
  > when the handler defers and pass `{:allow, input}` here rather than
  > plain `:allow`.
  """
  @spec respond_to_permission(GenServer.server(), String.t(), permission_decision()) ::
          :ok | {:error, Error.t()}
  def respond_to_permission(_server, _request_id, :defer),
    do: {:error, Error.new(:cannot_defer_again)}

  def respond_to_permission(server, request_id, decision)
      when is_binary(request_id) do
    GenServer.call(server, {:respond_to_permission, request_id, decision})
  end

  @doc """
  Stop the session. Closes the port, waits for the child to exit, and
  shuts down the GenServer.

  See also `close/1` for a short-form alias.
  """
  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ 5_000) do
    GenServer.stop(server, reason, timeout)
  end

  @doc """
  Graceful close: shorthand for `stop(server, :normal, 10_000)`.

  Closes the port (which sends SIGTERM to the child), waits up to
  10 seconds for it to exit, and shuts down the GenServer.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server), do: stop(server, :normal, 10_000)

  @doc """
  Send an `interrupt` control_request to the CLI. The CLI cancels any
  in-flight turn and emits a `result` with a cancel-flavored stop
  reason; that result still flows through the normal `send/3` reply.

  This call returns once the CLI acknowledges the interrupt with a
  matching `control_response`. The caller of `send/3` will receive
  its own reply when the resulting `result` event arrives.

  Calling `interrupt/1` outside of an active turn is harmless: the
  CLI accepts the request, acks it, and emits a synthetic result the
  GenServer drops.
  """
  @spec interrupt(GenServer.server(), timeout()) :: :ok | {:error, term()}
  def interrupt(server, timeout \\ 10_000) do
    GenServer.call(server, :interrupt, timeout)
  end

  @doc """
  Cheap, non-consuming liveness check. Mirrors the Rust `is_alive`.

  Returns `true` while the session process is alive, `false` once it has
  exited (cleanly or with an error). Resolves registered names and pids;
  any non-pid name that does not resolve is treated as not alive.
  """
  @spec alive?(GenServer.server()) :: boolean()
  def alive?(server) do
    case resolve_pid(server) do
      pid when is_pid(pid) -> Process.alive?(pid)
      nil -> false
    end
  end

  @doc """
  Live snapshot of the session's `t:exit_status/0`. Mirrors the Rust
  `exit_status` / `SessionExitStatus`, but is best-effort only.

  Returns `:running` while the session process is alive and `:completed`
  once it is gone. Unlike `wait_for_exit/2`, this cannot distinguish a
  clean exit from a failed one after the fact: the session keeps no
  persisted terminal status, so a dead process always reads back as
  `:completed`. If you need the failure reason (e.g.
  `{:failed, {:port_exit, code}}`), use `wait_for_exit/2`, which is the
  authoritative source.
  """
  @spec exit_status(GenServer.server()) :: exit_status()
  def exit_status(server) do
    case resolve_pid(server) do
      pid when is_pid(pid) ->
        if Process.alive?(pid) do
          call_exit_status(pid)
        else
          :completed
        end

      nil ->
        :completed
    end
  end

  @doc """
  Block until the session exits, then return its terminal
  `t:exit_status/0`. Mirrors the Rust `wait_for_exit`.

  This is the authoritative source of the terminal status. It returns
  `:completed` for a clean shutdown and `{:failed, {:port_exit, code}}`
  when the underlying `claude` subprocess exited with a non-zero status
  (or the port closed abnormally). Returns immediately (`:completed`) if
  the session has already exited.

  Implemented with a `Process.monitor/1` plus a one-shot waiter
  registration on the session: `terminate/2` sends each registered
  waiter the precise terminal status, and the monitor `:DOWN` is the
  fallback if the session dies before (or during) registration. Multiple
  concurrent callers are fine and the call does not consume the session.

  `timeout` (default 5 seconds) bounds the wait; on timeout this returns
  `:running` to signal "still alive past the deadline" (the analog of
  the Rust call simply not having resolved yet).
  """
  @spec wait_for_exit(GenServer.server(), timeout()) :: exit_status()
  def wait_for_exit(server, timeout \\ 5_000) do
    case resolve_pid(server) do
      nil -> :completed
      pid when is_pid(pid) -> await_exit(pid, timeout)
    end
  end

  # Register as an exit waiter and block for the terminal status. The
  # monitor guards the window where the session dies before/while we
  # register: if the GenServer.call races a shutdown (:noproc/:normal
  # exit), we fall through to the :DOWN branch rather than raising.
  defp await_exit(pid, timeout) do
    mref = Process.monitor(pid)
    ref = make_ref()
    register_exit_waiter(pid, ref)

    receive do
      {:duplex_exit, ^ref, status} ->
        Process.demonitor(mref, [:flush])
        status

      {:DOWN, ^mref, :process, ^pid, reason} ->
        down_reason_to_status(reason)
    after
      timeout ->
        Process.demonitor(mref, [:flush])
        :running
    end
  end

  # GenServer.call that tolerates the process dying mid-call. A normal
  # shutdown (:normal/:noproc) means the :DOWN message is already (or
  # about to be) in our mailbox, so swallow the exit and let await_exit's
  # receive pick it up. Any other exit is genuinely unexpected; re-raise.
  defp register_exit_waiter(pid, ref) do
    GenServer.call(pid, {:await_exit, ref})
  catch
    :exit, {reason, _} when reason in [:normal, :noproc, :shutdown] -> :ok
    :exit, {{:shutdown, _}, _} -> :ok
  end

  defp call_exit_status(pid) do
    GenServer.call(pid, :exit_status)
  catch
    :exit, {reason, _} when reason in [:normal, :noproc, :shutdown] -> :completed
    :exit, {{:shutdown, _}, _} -> :completed
  end

  # --- GenServer callbacks --------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    on_permission = Keyword.get(opts, :on_permission, &__MODULE__.deny_all/2)

    # A `%Query{}`'s spawn-time knobs come first; explicit `:extra_args`
    # follow as the escape hatch (and win on any repeated flag).
    query_args =
      case Keyword.get(opts, :query) do
        %Query{} = query -> Query.spawn_args(query)
        nil -> []
      end

    extra_args = query_args ++ Keyword.get(opts, :extra_args, [])

    # Tests substitute a fake binary (e.g. `cat`) that does not understand
    # the duplex flag set; they pass `:args_override` to bypass defaults.
    # Not part of the public surface.
    args = Keyword.get(opts, :args_override, build_args(extra_args))

    adapter = Keyword.get(opts, :adapter, Adapter.Port)
    adapter_opts = Keyword.get(opts, :adapter_opts, [])
    open_opts = [config: config, args: args, owner: self()] ++ adapter_opts

    case adapter.open(open_opts) do
      {:ok, handle} ->
        {:ok,
         %__MODULE__{
           port: handle,
           adapter: adapter,
           config: config,
           on_permission: on_permission
         }}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  @impl true
  def handle_call({:send, prompt}, from, %{pending_turn: nil, port: port} = state)
      when not is_nil(port) do
    msg = %{
      type: "user",
      message: %{role: "user", content: prompt},
      parent_tool_use_id: nil
    }

    state.adapter.command(port, [Jason.encode!(msg), ?\n])
    {:noreply, %{state | pending_turn: {from, []}}}
  end

  def handle_call({:send, _prompt}, _from, %{pending_turn: nil, port: nil} = state) do
    {:reply, {:error, Error.new(:duplex_closed)}, state}
  end

  def handle_call({:send, _prompt}, _from, state) do
    {:reply, {:error, Error.new(:turn_in_flight)}, state}
  end

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  def handle_call(:exit_status, _from, state), do: {:reply, state.exit_status, state}

  def handle_call({:await_exit, ref}, {pid, _tag}, state) do
    {:reply, :ok, %{state | exit_waiters: Map.put(state.exit_waiters, ref, pid)}}
  end

  def handle_call({:subscribe, pid}, _from, state) do
    state =
      if Map.has_key?(state.subscribers, pid) do
        state
      else
        ref = Process.monitor(pid)
        %{state | subscribers: Map.put(state.subscribers, pid, ref)}
      end

    {:reply, :ok, state}
  end

  def handle_call({:unsubscribe, pid}, _from, state) do
    {:reply, :ok, drop_subscriber(state, pid)}
  end

  def handle_call({:respond_to_permission, request_id, decision}, _from, state) do
    write_permission_response(state, request_id, decision)
    {:reply, :ok, state}
  end

  def handle_call(:interrupt, _from, %{port: nil} = state) do
    {:reply, {:error, Error.new(:duplex_closed)}, state}
  end

  def handle_call(:interrupt, from, state) do
    request_id = generate_request_id()

    msg = %{
      type: "control_request",
      request_id: request_id,
      request: %{subtype: "interrupt"}
    }

    state.adapter.command(state.port, [Jason.encode!(msg), ?\n])
    {:noreply, %{state | pending_control: Map.put(state.pending_control, request_id, from)}}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {complete, rest} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(complete, %{state | buffer: rest}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = fail_pending(state, {:port_exit, code})
    status = derive_exit_status({:port_exit, code})
    {:stop, :normal, %{state | port: nil, exit_status: status}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    state = fail_pending(state, {:port_exit, reason})
    status = derive_exit_status({:port_exit, reason})
    {:stop, :normal, %{state | port: nil, exit_status: status}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.subscribers, pid) do
      ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(reason, %{port: port} = state) do
    if not is_nil(port), do: state.adapter.close(port)
    fail_pending(state, :terminated)
    notify_exit_waiters(state, final_exit_status(state, reason))
    :ok
  end

  # --- Internals ------------------------------------------------------

  @doc false
  @spec build_args([String.t()]) :: [String.t()]
  def build_args(extra) do
    [
      "--input-format",
      "stream-json",
      "--output-format",
      "stream-json",
      "--include-partial-messages",
      "--verbose",
      "--print",
      "--permission-prompt-tool",
      "stdio"
    ] ++ extra
  end

  @doc """
  Default permission handler. Denies every tool call.

  Public so it can be referenced as a default value (`&deny_all/2`).
  """
  @spec deny_all(String.t(), tool_input()) :: permission_decision()
  def deny_all(_tool_name, _input), do: {:deny, "no permission handler installed"}

  # Manual newline splitting on raw binary. We deliberately avoid Port
  # `:line` mode because stream-json messages can carry tool results
  # larger than any reasonable line cap; `:line` reports {:noeol, partial}
  # which we would have to reassemble anyway. See issue #42.
  @doc false
  @spec split_lines(binary()) :: {[binary()], binary()}
  def split_lines(bin) when is_binary(bin) do
    parts = :binary.split(bin, "\n", [:global])
    {complete, [trailing]} = Enum.split(parts, -1)
    {complete, trailing}
  end

  defp handle_line("", state), do: state

  defp handle_line(line, state) do
    case Jason.decode(line) do
      {:ok, msg} ->
        dispatch(msg, state)

      {:error, _reason} ->
        Logger.warning("DuplexSession: non-JSON line from claude: #{inspect(line)}")
        state
    end
  end

  # Inbound permission request: the CLI is asking whether a tool may
  # run. We delegate to the user's on_permission callback. If they
  # return :defer, we don't write a response now; the caller will
  # call respond_to_permission/3 later.
  defp dispatch(
         %{
           "type" => "control_request",
           "request_id" => id,
           "request" => %{"subtype" => "can_use_tool"} = req
         },
         state
       ) do
    tool_name = req["tool_name"]
    input = req["input"] || %{}

    decision =
      try do
        invoke_permission_handler(state.on_permission, tool_name, input, id)
      rescue
        e ->
          Logger.error(
            "DuplexSession: on_permission raised for #{inspect(tool_name)}: #{inspect(e)}"
          )

          {:deny, "permission handler raised: #{Exception.message(e)}"}
      end

    case decision do
      :defer -> :ok
      _ -> write_permission_response(state, id, default_allow_input(decision, input))
    end

    state
  end

  # Reply to an outbound control_request we sent (e.g. interrupt).
  # The CLI may also emit control_responses with no matching pending
  # request_id (e.g. delayed cancellations); those are dropped.
  defp dispatch(
         %{"type" => "control_response", "response" => %{"request_id" => id} = resp},
         state
       ) do
    case Map.pop(state.pending_control, id) do
      {nil, _} ->
        state

      {from, rest} ->
        reply =
          case resp do
            %{"subtype" => "success"} -> :ok
            %{"subtype" => "error", "error" => err} -> {:error, control_failed(err)}
            other -> {:error, control_failed(other)}
          end

        GenServer.reply(from, reply)
        %{state | pending_control: rest}
    end
  end

  # system/init carries the session_id we'll need for resume in later PRs.
  defp dispatch(%{"type" => "system", "subtype" => "init", "session_id" => sid}, state) do
    broadcast(state, {:system_init, sid})
    %{state | session_id: sid}
  end

  # Turn boundary: reply to the waiting caller with a parsed Result.
  defp dispatch(%{"type" => "result"} = msg, %{pending_turn: {from, _events}} = state) do
    result = Result.from_json(msg)
    broadcast(state, {:result, result})
    GenServer.reply(from, {:ok, result})
    %{state | pending_turn: nil}
  end

  defp dispatch(%{"type" => "result"} = msg, state) do
    broadcast(state, {:result, Result.from_json(msg)})
    state
  end

  defp dispatch(%{"type" => "assistant"} = msg, state) do
    broadcast(state, {:assistant, msg})
    accumulate(state, msg)
  end

  defp dispatch(%{"type" => "stream_event"} = msg, state) do
    broadcast(state, {:stream_event, msg})
    accumulate(state, msg)
  end

  defp dispatch(%{"type" => "user"} = msg, state) do
    broadcast(state, {:user, msg})
    accumulate(state, msg)
  end

  # Other system subtypes (e.g. compact_boundary), unknown types: still
  # accumulate inside an active turn so callers that later inspect the
  # turn record can see them, but do not broadcast as a typed event.
  defp dispatch(msg, state), do: accumulate(state, msg)

  # Detect the user's callback arity once and apply with the right
  # number of arguments. 3-arity gets the request_id so a deferred
  # handler can correlate respond_to_permission/3 calls later.
  defp invoke_permission_handler(handler, tool_name, input, request_id) do
    case :erlang.fun_info(handler, :arity) do
      {:arity, 3} -> handler.(tool_name, input, request_id)
      {:arity, 2} -> handler.(tool_name, input)
    end
  end

  defp accumulate(%{pending_turn: {from, events}} = state, msg) do
    %{state | pending_turn: {from, [msg | events]}}
  end

  defp accumulate(state, _msg), do: state

  defp broadcast(%{subscribers: subs}, _event) when map_size(subs) == 0, do: :ok

  defp broadcast(%{subscribers: subs}, event) do
    Enum.each(subs, fn {pid, _ref} ->
      Process.send(pid, {:claude, event}, [])
    end)
  end

  defp drop_subscriber(state, pid) do
    case Map.pop(state.subscribers, pid) do
      {nil, _} ->
        state

      {ref, rest} ->
        Process.demonitor(ref, [:flush])
        %{state | subscribers: rest}
    end
  end

  defp fail_pending(state, reason) do
    state
    |> fail_pending_turn(reason)
    |> fail_pending_control(reason)
  end

  defp fail_pending_turn(%{pending_turn: nil} = state, _reason), do: state

  defp fail_pending_turn(%{pending_turn: {from, _}} = state, reason) do
    GenServer.reply(from, {:error, fail_reason_to_error(reason)})
    %{state | pending_turn: nil}
  end

  defp fail_pending_control(%{pending_control: pending} = state, _reason)
       when map_size(pending) == 0,
       do: state

  defp fail_pending_control(%{pending_control: pending} = state, reason) do
    error = fail_reason_to_error(reason)

    Enum.each(pending, fn {_id, from} ->
      GenServer.reply(from, {:error, error})
    end)

    %{state | pending_control: %{}}
  end

  # Map the internal fail-pending reasons to the canonical Error. A clean
  # `:terminated` (terminate/2) stays bare; a `{:port_exit, x}` from a
  # subprocess exit is carried in :reason so callers can recover the code.
  defp fail_reason_to_error(:terminated), do: Error.new(:terminated)

  defp fail_reason_to_error({:port_exit, _} = reason),
    do: Error.new(:terminated, reason: reason)

  # Wrap an interrupt/permission control_request failure reported by the
  # CLI via a `subtype: "error"` control_response.
  defp control_failed(reason), do: Error.new(:duplex_control_failed, reason: reason)

  # Wraps a permission decision in the SDK's control_response envelope
  # and writes it to the transport's stdin. Shape mirrors the SDK's
  # PermissionResult / SDKControlResponse schemas (see sdk.d.ts).
  defp write_permission_response(%{port: nil}, _request_id, _decision), do: :ok

  defp write_permission_response(state, request_id, decision) do
    response = decision_to_permission_response(decision)

    msg = %{
      type: "control_response",
      response: %{
        subtype: "success",
        request_id: request_id,
        response: response
      }
    }

    state.adapter.command(state.port, [Jason.encode!(msg), ?\n])
    :ok
  end

  defp decision_to_permission_response(:allow),
    do: %{behavior: "allow"}

  defp decision_to_permission_response({:allow, updated_input}) when is_map(updated_input),
    do: %{behavior: "allow", updatedInput: updated_input}

  defp decision_to_permission_response({:deny, reason}) when is_binary(reason),
    do: %{behavior: "deny", message: reason}

  # Plain `:allow` is ambiguous over the wire: Claude's permission
  # protocol validates the response with Zod and requires
  # `updatedInput` even when the input is unmodified. We default it to
  # the original `input` so callers don't have to thread it back
  # through their state just to say "yes, run the tool as-is".
  @doc false
  def default_allow_input(:allow, input) when is_map(input), do: {:allow, input}
  def default_allow_input(decision, _input), do: decision

  # 16 random bytes -> 32-char lowercase hex. Plenty of entropy to
  # avoid collisions in our pending_control map and matches the SDK's
  # use of UUID-shaped strings.
  defp generate_request_id do
    :crypto.strong_rand_bytes(16) |> Base.encode16(case: :lower)
  end

  # --- Health helpers (internals) -------------------------------------

  # Resolve a GenServer.server() reference to a concrete pid. Pids pass
  # through; registered names (atoms / {:via, ...} / {name, node}) are
  # looked up via GenServer.whereis/1, which returns nil if unregistered.
  defp resolve_pid(pid) when is_pid(pid), do: pid
  defp resolve_pid(server), do: GenServer.whereis(server)

  # Map a port-exit observation to a terminal status. A status code of 0
  # (or a reason of :normal) is a clean completion; anything else is a
  # failure carrying the original {:port_exit, ...} tuple.
  defp derive_exit_status({:port_exit, 0}), do: :completed
  defp derive_exit_status({:port_exit, :normal}), do: :completed
  defp derive_exit_status({:port_exit, _} = reason), do: {:failed, reason}

  # The terminal status to hand to exit waiters from terminate/2. A port
  # exit already recorded a status in state; honor it. Otherwise the
  # GenServer is being stopped externally (stop/3, close/1, supervisor)
  # -- :normal and :shutdown are clean completions, any other reason is a
  # failure.
  defp final_exit_status(%{exit_status: status}, _reason) when status != :running, do: status
  defp final_exit_status(_state, :normal), do: :completed
  defp final_exit_status(_state, :shutdown), do: :completed
  defp final_exit_status(_state, {:shutdown, _}), do: :completed
  defp final_exit_status(_state, reason), do: {:failed, reason}

  # Notify every registered exit waiter with the terminal status. Called
  # once from terminate/2. This is the authoritative delivery path; the
  # monitor :DOWN that each waiter also holds is only the fallback for
  # the death-before-registration race.
  defp notify_exit_waiters(%{exit_waiters: waiters}, _status)
       when map_size(waiters) == 0,
       do: :ok

  defp notify_exit_waiters(%{exit_waiters: waiters}, status) do
    Enum.each(waiters, fn {ref, pid} ->
      Process.send(pid, {:duplex_exit, ref, status}, [])
    end)
  end

  # Fallback translation of a monitor :DOWN reason into a terminal status,
  # used only when a waiter never received a {:duplex_exit, ...} message
  # (the session died before/while it registered). We stop with :normal
  # even when the child failed (to keep supervision semantics unchanged),
  # so a clean-looking down reason is treated as :completed; only a
  # genuinely abnormal exit (e.g. a hard kill) maps to {:failed, reason}.
  defp down_reason_to_status(:noproc), do: :completed
  defp down_reason_to_status(:normal), do: :completed
  defp down_reason_to_status(:shutdown), do: :completed
  defp down_reason_to_status({:shutdown, _}), do: :completed
  defp down_reason_to_status(reason), do: {:failed, reason}
end
