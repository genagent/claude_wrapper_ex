defmodule ClaudeWrapper.DuplexSession do
  @moduledoc """
  **EXPERIMENTAL.** Long-lived `claude` session over the CLI's stream-json
  duplex protocol.

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

  ## Current scope

  Implemented so far: minimal happy path (PR 1), subscribers (PR 2),
  and permission callbacks (PR 3). Interrupt (PR 4) is **not yet wired**.

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
  GenServer when the CLI emits a `can_use_tool` control request. It must
  return one of:

    * `:allow` -- allow the tool with the original input
    * `{:allow, updated_input}` -- allow the tool with a modified input
      map (sandbox a path, redact a secret, etc.)
    * `{:deny, reason}` -- deny the tool with a reason string the model
      will see
    * `:defer` -- do not respond synchronously; the caller is expected
      to invoke `respond_to_permission/3` later. Use this when a human
      decision is required and the GenServer must not block

  The callback runs in the GenServer process, so synchronous decisions
  must be fast. For slow decisions, return `:defer` and answer later
  via `respond_to_permission/3`.

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
  """

  use GenServer
  require Logger

  alias ClaudeWrapper.{Config, Result}

  @type tool_input :: map()

  @type permission_decision ::
          :allow
          | {:allow, tool_input()}
          | {:deny, String.t()}
          | :defer

  @type permission_handler :: (String.t(), tool_input() -> permission_decision())

  @type option ::
          {:config, Config.t()}
          | {:extra_args, [String.t()]}
          | {:on_permission, permission_handler()}
          | {:name, GenServer.name()}
          | GenServer.option()

  @type state :: %__MODULE__{
          port: port() | nil,
          config: Config.t(),
          session_id: String.t() | nil,
          buffer: binary(),
          pending_turn: {GenServer.from(), [map()]} | nil,
          subscribers: %{pid() => reference()},
          on_permission: permission_handler()
        }

  defstruct [
    :port,
    :config,
    :session_id,
    :on_permission,
    buffer: <<>>,
    pending_turn: nil,
    subscribers: %{}
  ]

  # --- Public API ------------------------------------------------------

  @doc """
  Start a duplex session.

  ## Options

    * `:config` -- (required) `%ClaudeWrapper.Config{}` struct.
    * `:extra_args` -- extra CLI flags to append (e.g.
      `["--permission-mode", "plan", "--max-turns", "1"]`).
    * `:name` -- register the GenServer under a name.

  All other keyword options are passed through to `GenServer.start_link/3`.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts) do
    {start_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, start_opts)
  end

  @doc """
  Send a user prompt. Blocks until the turn's `result` event arrives.

  Returns `{:ok, %Result{}}` on success, `{:error, :turn_in_flight}` if
  another turn is already running, or `{:error, reason}` on failure.

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
  which is rejected with `{:error, :cannot_defer_again}`.
  """
  @spec respond_to_permission(GenServer.server(), String.t(), permission_decision()) ::
          :ok | {:error, :cannot_defer_again}
  def respond_to_permission(_server, _request_id, :defer),
    do: {:error, :cannot_defer_again}

  def respond_to_permission(server, request_id, decision)
      when is_binary(request_id) do
    GenServer.call(server, {:respond_to_permission, request_id, decision})
  end

  @doc """
  Stop the session. Closes the port, waits for the child to exit, and
  shuts down the GenServer.
  """
  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ 5_000) do
    GenServer.stop(server, reason, timeout)
  end

  # --- GenServer callbacks --------------------------------------------

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)
    config = Keyword.fetch!(opts, :config)
    extra_args = Keyword.get(opts, :extra_args, [])
    on_permission = Keyword.get(opts, :on_permission, &__MODULE__.deny_all/2)

    # Tests substitute a fake binary (e.g. `cat`) that does not understand
    # the duplex flag set; they pass `:args_override` to bypass defaults.
    # Not part of the public surface.
    args = Keyword.get(opts, :args_override, build_args(extra_args))

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, args}] ++
        port_env_opts(config) ++
        port_cd_opts(config)

    port = Port.open({:spawn_executable, config.binary}, port_opts)
    {:ok, %__MODULE__{port: port, config: config, on_permission: on_permission}}
  end

  @impl true
  def handle_call({:send, prompt}, from, %{pending_turn: nil, port: port} = state)
      when not is_nil(port) do
    msg = %{
      type: "user",
      message: %{role: "user", content: prompt},
      parent_tool_use_id: nil
    }

    Port.command(port, [Jason.encode!(msg), ?\n])
    {:noreply, %{state | pending_turn: {from, []}}}
  end

  def handle_call({:send, _prompt}, _from, %{pending_turn: nil, port: nil} = state) do
    {:reply, {:error, :port_closed}, state}
  end

  def handle_call({:send, _prompt}, _from, state) do
    {:reply, {:error, :turn_in_flight}, state}
  end

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

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
    write_permission_response(state.port, request_id, decision)
    {:reply, :ok, state}
  end

  @impl true
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    {complete, rest} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(complete, %{state | buffer: rest}, &handle_line/2)
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = fail_pending(state, {:port_exit, code})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    state = fail_pending(state, {:port_exit, reason})
    {:stop, :normal, %{state | port: nil}}
  end

  def handle_info({:DOWN, ref, :process, pid, _reason}, state) do
    case Map.get(state.subscribers, pid) do
      ^ref -> {:noreply, %{state | subscribers: Map.delete(state.subscribers, pid)}}
      _ -> {:noreply, state}
    end
  end

  def handle_info(_other, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port} = state) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    fail_pending(state, :terminated)
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
        state.on_permission.(tool_name, input)
      rescue
        e ->
          Logger.error(
            "DuplexSession: on_permission/2 raised for #{inspect(tool_name)}: #{inspect(e)}"
          )

          {:deny, "permission handler raised: #{Exception.message(e)}"}
      end

    case decision do
      :defer -> :ok
      _ -> write_permission_response(state.port, id, decision)
    end

    state
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

  defp fail_pending(%{pending_turn: nil} = state, _reason), do: state

  defp fail_pending(%{pending_turn: {from, _}} = state, reason) do
    GenServer.reply(from, {:error, reason})
    %{state | pending_turn: nil}
  end

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]

  # Wraps a permission decision in the SDK's control_response envelope
  # and writes it to the port's stdin. Shape mirrors the SDK's
  # PermissionResult / SDKControlResponse schemas (see sdk.d.ts).
  defp write_permission_response(nil, _request_id, _decision), do: :ok

  defp write_permission_response(port, request_id, decision) do
    response = decision_to_permission_response(decision)

    msg = %{
      type: "control_response",
      response: %{
        subtype: "success",
        request_id: request_id,
        response: response
      }
    }

    Port.command(port, [Jason.encode!(msg), ?\n])
    :ok
  end

  defp decision_to_permission_response(:allow),
    do: %{behavior: "allow"}

  defp decision_to_permission_response({:allow, updated_input}) when is_map(updated_input),
    do: %{behavior: "allow", updatedInput: updated_input}

  defp decision_to_permission_response({:deny, reason}) when is_binary(reason),
    do: %{behavior: "deny", message: reason}
end
