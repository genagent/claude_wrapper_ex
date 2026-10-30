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

  ## Control requests

  The stream-json protocol carries `control_request` messages in both
  directions. `can_use_tool` is handled by `:on_permission` above; this
  session also exposes the rest of the channel as primitives:

    * `control/3` sends any outbound request (`%{subtype: "set_model",
      model: "sonnet"}`, `%{subtype: "mcp_status"}`, ...) and returns the
      CLI's response map. `interrupt/2` is built on it.
    * `:on_control_request` receives every other inbound request as
      `(subtype, request, request_id)` and returns a `t:control_reply/0`.
      Returning `:defer` leaves the request open for `respond_to_control/3`.

  The default inbound handler, `unsupported_control/3`, replies with an
  error, so an unhandled request never leaves the CLI waiting. If the CLI
  cancels a request with `control_cancel_request`, a pending deferral is
  dropped and subscribers receive `{:control_cancel, request_id}`.

  ## Initialize and in-process MCP servers

  `:initialize` sends the protocol's `initialize` request at start; pass
  `true`, or a map of extra fields (`hooks`, `agents`, ...) sent as given.
  `initialize_response/2` returns the CLI's answer (commands, models,
  account, permission mode, version). Hooks registered this way arrive as
  `hook_callback` requests at `:on_control_request`.

  `:sdk_mcp_servers` maps a server name to a `t:sdk_mcp_handler/0`. Each
  server is declared to the CLI as a `type: "sdk"` entry in its own
  `--mcp-config`, named in `initialize`, and its `mcp_message` requests are
  routed to the handler, which runs in its own process. Messages for other
  server names go to `:on_control_request`. The CLI connects these servers
  shortly after `initialize`. `ClaudeWrapper.DuplexSession.SdkMcp` builds
  a tool server from a list of tools.

  ## Subscriber events

  Subscribers receive plain messages of the form `{:claude, event}`:

    * `{:system_init, session_id}` -- the CLI's init event
    * `{:assistant, msg}` -- a full assistant turn (`SDKAssistantMessage`)
    * `{:stream_event, msg}` -- a partial assistant token
      (`SDKPartialAssistantMessage`)
    * `{:user, msg}` -- a user message (e.g. tool results, replays)
    * `{:result, %ClaudeWrapper.Result{}}` -- the parsed turn boundary
    * `{:transport_terminal, %ClaudeWrapper.DuplexSession.TransportTerminal{}}`
      -- Forcola's terminal evidence and bounded stderr tail
    * `{:control_cancel, request_id}` -- the CLI cancelled an inbound
      control request it had sent

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

  `wait_for_exit/2` blocks until the session exits and returns `:completed`
  for a clean shutdown or `{:failed, reason}` for a transport failure.
  With Forcola, the failure reason contains its structured terminal record;
  `shutdown/2` also returns that record on explicit close. The status is
  delivered live from `terminate/2`, so a caller must register before the
  session exits or subscribe to terminal events.

  `exit_status/1` is only a *live snapshot*: it reports `:running` while
  the session process is alive and `:completed` once the process is
  gone. It cannot distinguish a clean exit from a failed one after the
  fact -- use `wait_for_exit/2` if you need the failure reason.
  """

  use GenServer
  require Logger

  alias ClaudeWrapper.{Command, Config, Error, Query, Result, Telemetry}
  alias ClaudeWrapper.DuplexSession.{Adapter, TransportTerminal}

  @default_stderr_capture_bytes 16 * 1024
  @default_max_line_bytes 1_048_576

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

  A **2-arity** handler that returns `:defer` cannot be answered (nothing can
  learn the `request_id`), so it is logged and treated as a **deny** rather than
  wedging the turn -- use the 3-arity form to defer. If a turn ever does hang
  (a genuinely unresponsive CLI), `interrupt/1` is the reset path: it aborts the
  in-flight turn so the session accepts `send/3` again.

  Arity is detected at call time so existing 2-arity callbacks keep
  working unchanged.
  """
  @type permission_handler ::
          (String.t(), tool_input() -> permission_decision())
          | (String.t(), tool_input(), String.t() -> permission_decision())

  @typedoc """
  Reply to an inbound control request:

    * `{:ok, response}` -- a `success` control_response carrying `response`
    * `{:error, message}` -- an `error` control_response the CLI reports
    * `:defer` -- no reply now; answer later with `respond_to_control/3`
  """
  @type control_reply :: {:ok, map()} | {:error, String.t()} | :defer

  @typedoc """
  Handler for inbound control requests other than `can_use_tool`. Called
  with the request `subtype`, the full decoded `request` map (string keys),
  and the `request_id`.
  """
  @type control_handler :: (String.t(), map(), String.t() -> control_reply())

  @typedoc """
  An in-process MCP server: called with one decoded JSON-RPC message and
  returns the JSON-RPC response map, or `nil` for a notification. It runs
  in its own process, so a slow tool call does not block the session.
  `ClaudeWrapper.DuplexSession.SdkMcp.tool_server/2` builds one from a
  list of tools.
  """
  @type sdk_mcp_handler :: (map() -> map() | nil)

  @type option ::
          {:config, Config.t()}
          | {:query, Query.t()}
          | {:extra_args, [String.t()]}
          | {:on_permission, permission_handler()}
          | {:on_control_request, control_handler()}
          | {:initialize, boolean() | map()}
          | {:sdk_mcp_servers, %{String.t() => sdk_mcp_handler()}}
          | {:adapter, module()}
          | {:adapter_opts, keyword()}
          | {:owner, pid()}
          | {:name, GenServer.name()}
          | GenServer.option()

  @typedoc """
  Terminal liveness status of a session, mirroring the Rust crate's
  `SessionExitStatus`:

    * `:running` -- the session process is alive and usable.
    * `:completed` -- the session shut down cleanly (graceful
      `stop/3`/`close/1`, or the `claude` subprocess exited with status
      `0`).
    * `{:failed, reason}` -- the transport ended abnormally. Port adapters
      report `{:port_exit, code | term}`; Forcola preserves its terminal
      record under `{:transport_terminal, record}`.
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
          on_control_request: control_handler(),
          exit_status: exit_status(),
          exit_waiters: %{reference() => pid()},
          owner_ref: reference() | nil,
          transport_terminal: TransportTerminal.t() | nil,
          stderr: binary(),
          stderr_capture_bytes: non_neg_integer(),
          max_line_bytes: pos_integer() | :infinity,
          max_output_bytes: pos_integer() | :infinity,
          output_bytes: non_neg_integer(),
          deferred_permissions: MapSet.t(String.t()),
          deferred_controls: MapSet.t(String.t()),
          initialize: :not_requested | :pending | {:ok, map()} | {:error, Error.t()},
          initialize_waiters: [GenServer.from()],
          sdk_mcp_servers: %{String.t() => sdk_mcp_handler()},
          mcp_tasks: %{pid() => {reference(), String.t()}},
          turn_span: {integer(), map()} | nil,
          session_monotonic: integer() | nil
        }

  defstruct [
    :port,
    :adapter,
    :config,
    :session_id,
    :on_permission,
    :on_control_request,
    :owner_ref,
    :turn_span,
    :session_monotonic,
    buffer: <<>>,
    pending_turn: nil,
    pending_control: %{},
    subscribers: %{},
    exit_status: :running,
    exit_waiters: %{},
    transport_terminal: nil,
    stderr: <<>>,
    stderr_capture_bytes: @default_stderr_capture_bytes,
    max_line_bytes: @default_max_line_bytes,
    max_output_bytes: :infinity,
    output_bytes: 0,
    deferred_permissions: MapSet.new(),
    deferred_controls: MapSet.new(),
    initialize: :not_requested,
    initialize_waiters: [],
    sdk_mcp_servers: %{},
    mcp_tasks: %{}
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
    * `:on_permission` -- `t:permission_handler/0` for `can_use_tool`
      (default `deny_all/2`).
    * `:on_control_request` -- `t:control_handler/0` for every other
      inbound control request (default `unsupported_control/3`).
    * `:initialize` -- `true` or a map of extra fields: send `initialize`
      at start (see `initialize_response/2`). Implied by `:sdk_mcp_servers`.
    * `:sdk_mcp_servers` -- `%{name => t:sdk_mcp_handler/0}` in-process
      MCP servers.
    * `:adapter` -- transport module (default `Adapter.Port`).
    * `:adapter_opts` -- transport-specific options. Both built-in adapters
      accept `:max_line_bytes` (default 1 MiB), `:max_output_bytes` and
      `:stderr_capture_bytes` (default 16 KiB). `:max_output_bytes` defaults
      to 64 MiB on `Adapter.Forcola` and is unbounded on `Adapter.Port`,
      where a long-lived session's total output grows across turns. On
      `Adapter.Port` the session enforces the bounds and ends with
      `{:failed, {:transport_error, {:output_limit, :line | :output,
      limit}}}`. The Forcola adapter also takes an independent terminal
      recipient; see its module documentation.
    * `:owner` -- optional lifecycle owner to monitor.
    * `:name` -- register the GenServer under a name.

  All other keyword options are passed through to `GenServer.start_link/3`.

  Runner options are not supported: when `ClaudeWrapper.Runner.options/1`
  resolves a non-empty list for `:config` (its own `:runner_options`, or the
  `:runner_options` application env when that field is `nil`), this returns
  `{:error, %ClaudeWrapper.Error{kind: :invalid_runner_options, reason:
  {:unsupported_mode, :duplex}}}` before any adapter is opened. An explicit
  `runner_options: []` on the config overrides application defaults.

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

    # Checked here as well as in init/1 so the common path returns the
    # typed error without starting (and exiting) a linked process.
    with :ok <- reject_runner_options(Keyword.get(init_opts, :config)) do
      GenServer.start_link(__MODULE__, init_opts, start_opts)
    end
  end

  # Runner options are honored only by evidenced one-shot execution. Neither
  # duplex adapter can apply them, so a session never opens with them.
  defp reject_runner_options(%Config{} = config),
    do: Command.reject_runner_options(config, :duplex)

  defp reject_runner_options(_config), do: :ok

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
  Answer a deferred inbound control request.

  Used after the `:on_control_request` handler returned `:defer` for
  `request_id`. `reply` is `{:ok, response}` or `{:error, message}`.
  A `request_id` the session has no open deferral for (never deferred,
  already answered, or cancelled by the CLI) is a no-op returning `:ok`.
  """
  @spec respond_to_control(GenServer.server(), String.t(), control_reply()) ::
          :ok | {:error, Error.t()}
  def respond_to_control(_server, _request_id, :defer),
    do: {:error, Error.new(:cannot_defer_again)}

  def respond_to_control(server, request_id, reply) when is_binary(request_id) do
    GenServer.call(server, {:respond_to_control, request_id, validate_control_reply!(reply)})
  end

  @doc """
  The CLI's response to the `initialize` request sent at start.

  Available when the session was started with `:initialize` or
  `:sdk_mcp_servers`. Waits for the response if it has not arrived yet.
  The response describes the session: `commands`, `agents`, `models`,
  `account`, `output_style`, `current_permission_mode`, the CLI version
  and more, as the CLI reports them.

  Returns `{:error, %Error{kind: :not_found, reason:
  :initialize_not_requested}}` when no `initialize` was sent.
  """
  @spec initialize_response(GenServer.server(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def initialize_response(server, timeout \\ 10_000) do
    GenServer.call(server, :initialize_response, timeout)
  end

  @doc """
  Send an outbound `control_request` and wait for the CLI's response.

  `request` is a map with a `subtype` (atom or string key); the other
  fields are sent as given. Returns `{:ok, response}` with the CLI's
  response body (`%{}` when it sends none), `{:error, %Error{kind:
  :duplex_control_failed}}` when the CLI answers with an error, or
  `{:error, %Error{kind: :duplex_closed}}` when the transport is gone.

      {:ok, %{"model" => _}} =
        DuplexSession.control(pid, %{subtype: "set_model", model: "sonnet"})

      {:ok, %{"mcpServers" => servers}} =
        DuplexSession.control(pid, %{subtype: "mcp_status"})

  The request is not validated against the CLI's schema; an unknown
  subtype comes back as `:duplex_control_failed` with the CLI's message.
  """
  @spec control(GenServer.server(), map(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def control(server, request, timeout \\ 10_000) when is_map(request) do
    subtype = Map.get(request, :subtype) || Map.get(request, "subtype")

    unless is_binary(subtype) do
      raise ArgumentError, "control request needs a string :subtype, got: #{inspect(request)}"
    end

    GenServer.call(server, {:control, request}, timeout)
  end

  # --- Typed control requests -------------------------------------------
  #
  # Thin wrappers over control/3, checked against CLI 2.1.312. Each returns
  # the same errors as control/3.

  @doc """
  Switch the model for subsequent turns. Returns the model id the CLI
  resolved (`"sonnet"` resolves to a full model id).
  """
  @spec set_model(GenServer.server(), String.t(), timeout()) ::
          {:ok, String.t() | nil} | {:error, Error.t()}
  def set_model(server, model, timeout \\ 10_000) when is_binary(model) do
    with {:ok, response} <- control(server, %{subtype: "set_model", model: model}, timeout) do
      {:ok, response["model"]}
    end
  end

  @doc """
  Switch the permission mode. `mode` is a `t:ClaudeWrapper.Query.permission_mode/0`
  atom. The CLI also emits a `system`/`status` event with the new mode.
  """
  @spec set_permission_mode(GenServer.server(), Query.permission_mode(), timeout()) ::
          :ok | {:error, Error.t()}
  def set_permission_mode(server, mode, timeout \\ 10_000) when is_atom(mode) do
    request = %{subtype: "set_permission_mode", mode: Query.permission_mode_arg(mode)}

    with {:ok, _} <- control(server, request, timeout), do: :ok
  end

  @doc """
  Set the extended-thinking token budget for subsequent turns, or clear it
  with `nil`.
  """
  @spec set_max_thinking_tokens(GenServer.server(), non_neg_integer() | nil, timeout()) ::
          :ok | {:error, Error.t()}
  def set_max_thinking_tokens(server, tokens, timeout \\ 10_000)
      when is_nil(tokens) or (is_integer(tokens) and tokens >= 0) do
    request = %{subtype: "set_max_thinking_tokens", max_thinking_tokens: tokens}

    with {:ok, _} <- control(server, request, timeout), do: :ok
  end

  @doc """
  The session's MCP servers as the CLI reports them: one map per server with
  `name`, `status` (`"connected"`, `"pending"`, `"failed"`, `"disabled"`),
  `transport`, `scope`, and when connected, `serverInfo` and `tools`.
  """
  @spec mcp_status(GenServer.server(), timeout()) :: {:ok, [map()]} | {:error, Error.t()}
  def mcp_status(server, timeout \\ 10_000) do
    with {:ok, response} <- control(server, %{subtype: "mcp_status"}, timeout) do
      {:ok, Map.get(response, "mcpServers", [])}
    end
  end

  @doc "Enable or disable an MCP server for this session."
  @spec mcp_toggle(GenServer.server(), String.t(), boolean(), timeout()) ::
          :ok | {:error, Error.t()}
  def mcp_toggle(server, name, enabled, timeout \\ 10_000)
      when is_binary(name) and is_boolean(enabled) do
    request = %{subtype: "mcp_toggle", serverName: name, enabled: enabled}

    with {:ok, _} <- control(server, request, timeout), do: :ok
  end

  @doc """
  Reconnect a configured MCP server. The CLI rejects this for in-process
  (`:sdk_mcp_servers`) servers.
  """
  @spec mcp_reconnect(GenServer.server(), String.t(), timeout()) :: :ok | {:error, Error.t()}
  def mcp_reconnect(server, name, timeout \\ 30_000) when is_binary(name) do
    with {:ok, _} <- control(server, %{subtype: "mcp_reconnect", serverName: name}, timeout),
         do: :ok
  end

  @doc """
  Replace the session's dynamically configured MCP servers with `servers`
  (a `.mcp.json`-style `mcpServers` map). Returns the CLI's summary with
  `"added"`, `"removed"` and `"errors"`.
  """
  @spec mcp_set_servers(GenServer.server(), map(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def mcp_set_servers(server, servers, timeout \\ 30_000) when is_map(servers) do
    control(server, %{subtype: "mcp_set_servers", servers: servers}, timeout)
  end

  @doc "Stop a running background task by id."
  @spec stop_task(GenServer.server(), String.t(), timeout()) :: :ok | {:error, Error.t()}
  def stop_task(server, task_id, timeout \\ 10_000) when is_binary(task_id) do
    with {:ok, _} <- control(server, %{subtype: "stop_task", task_id: task_id}, timeout), do: :ok
  end

  @doc """
  Rewind files changed since the user message `user_message_id`. The CLI
  answers with an error when it holds no file checkpoint for that message.
  Options: `:dry_run` (boolean) is sent as `dryRun`.
  """
  @spec rewind_files(GenServer.server(), String.t(), keyword(), timeout()) ::
          {:ok, map()} | {:error, Error.t()}
  def rewind_files(server, user_message_id, opts \\ [], timeout \\ 30_000)
      when is_binary(user_message_id) do
    request =
      %{subtype: "rewind_files", user_message_id: user_message_id}
      |> then(fn req ->
        case Keyword.fetch(opts, :dry_run) do
          {:ok, dry_run} when is_boolean(dry_run) -> Map.put(req, :dryRun, dry_run)
          :error -> req
        end
      end)

    control(server, request, timeout)
  end

  @doc "The session's settings as the CLI reports them (`applied`, `effective`, ...)."
  @spec get_settings(GenServer.server(), timeout()) :: {:ok, map()} | {:error, Error.t()}
  def get_settings(server, timeout \\ 10_000),
    do: control(server, %{subtype: "get_settings"}, timeout)

  @doc "Send the `apply_flag_settings` control request with a settings map."
  @spec apply_flag_settings(GenServer.server(), map(), timeout()) :: :ok | {:error, Error.t()}
  def apply_flag_settings(server, settings, timeout \\ 10_000) when is_map(settings) do
    with {:ok, _} <-
           control(server, %{subtype: "apply_flag_settings", settings: settings}, timeout),
         do: :ok
  end

  @doc """
  Stop the session: shut down the GenServer, which calls the adapter's
  `close/1` on the port during `terminate/2`.

  With the default `ClaudeWrapper.DuplexSession.Adapter.Port`, close
  closes `claude`'s stdin, which an idle `claude` exits on, and its lifeline
  port: after 1 s a `claude` that is still running gets SIGINT, then SIGTERM
  2 s later, then SIGKILL (#303). Only the `claude` pid is signalled; stdio
  MCP servers it spawned stop only if `claude` stops them. This function does
  *not* wait for the child to exit; `timeout` is only the `GenServer.stop/3`
  terminate deadline.

  For SIGTERM-then-SIGKILL group termination that reaps the child and its
  process group, configure `ClaudeWrapper.DuplexSession.Adapter.Forcola`
  (`config :claude_wrapper, duplex_adapter: ClaudeWrapper.DuplexSession.Adapter.Forcola`).

  See also `close/1` for a short-form alias.
  """
  @spec stop(GenServer.server(), term(), timeout()) :: :ok
  def stop(server, reason \\ :normal, timeout \\ 5_000) do
    GenServer.stop(server, reason, timeout)
  end

  @doc """
  Graceful close: shorthand for `stop(server, :normal, 10_000)`.

  The `10_000` is the `GenServer.stop/3` terminate deadline, not a
  child-exit wait. See `stop/3` for the adapter caveat: the default
  `Adapter.Port` severs the pipes without signalling or reaping the
  child (orphaned per #185); use `Adapter.Forcola` for real
  SIGTERM-then-SIGKILL group termination.
  """
  @spec close(GenServer.server()) :: :ok
  def close(server), do: stop(server, :normal, 10_000)

  @doc """
  Stop the session and return structured transport evidence when available.

  With `Adapter.Forcola`, the return is `{:ok,
  %ClaudeWrapper.DuplexSession.TransportTerminal{}}` containing the native
  child status, cleanup confirmation, output completeness, and a bounded
  stderr tail. The default Port adapter returns a `TransportTerminal` with
  `evidence: :closed` and the tail of `claude`'s stderr (when the child
  exits on its own, the `{:transport_terminal, _}` event carries
  `evidence: {:exit_status, code}`). An adapter with neither returns
  `{:ok, nil}`. `close/1` and `stop/3` retain their `:ok` contract.

  A subscriber also receives `{:claude, {:transport_terminal, evidence}}`
  when the transport ends on its own. A caller that may lose ownership can
  pass `terminal_recipient: pid` in Forcola `:adapter_opts` to receive the
  native Forcola record independently of this session process.
  """
  @spec shutdown(GenServer.server(), timeout()) ::
          {:ok, TransportTerminal.t() | nil} | {:error, :not_found}
  def shutdown(server, timeout \\ 20_000) do
    GenServer.call(server, :shutdown, timeout)
  catch
    :exit, {reason, _} when reason in [:normal, :noproc] -> {:error, :not_found}
  end

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
    case control(server, %{subtype: "interrupt"}, timeout) do
      {:ok, _response} -> :ok
      {:error, _} = error -> error
    end
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
  `:completed` for a clean shutdown and `{:failed, reason}` on failure.
  Forcola failures retain the native terminal record in `reason` instead of
  projecting a signal or unconfirmed outcome onto an integer exit code.
  Returns `:completed` if the session had already exited before the caller
  could register; use a subscriber or `terminal_recipient` for that case.

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
    config = Keyword.fetch!(opts, :config)

    case reject_runner_options(config) do
      :ok -> open_session(opts, config)
      {:error, error} -> {:stop, error}
    end
  end

  defp open_session(opts, config) do
    Process.flag(:trap_exit, true)
    on_permission = Keyword.get(opts, :on_permission, &__MODULE__.deny_all/2)
    on_control_request = fetch_control_handler!(opts)

    # A `%Query{}`'s spawn-time knobs come first; explicit `:extra_args`
    # follow as the escape hatch (and win on any repeated flag).
    {query_args, config} =
      case Keyword.get(opts, :query) do
        %Query{} = query -> {Query.spawn_args(query), Query.with_spawn_env(query, config)}
        nil -> {[], config}
      end

    sdk_mcp_servers = fetch_sdk_mcp_servers!(opts)

    extra_args =
      query_args ++ Keyword.get(opts, :extra_args, []) ++ sdk_mcp_args(sdk_mcp_servers)

    # Tests substitute a fake binary (e.g. `cat`) that does not understand
    # the duplex flag set; they pass `:args_override` to bypass defaults.
    # Not part of the public surface.
    args = Keyword.get(opts, :args_override, build_args(extra_args))

    adapter = Keyword.get(opts, :adapter, default_adapter())
    adapter_opts = Keyword.get(opts, :adapter_opts, [])

    stderr_capture_bytes =
      Keyword.get(adapter_opts, :stderr_capture_bytes, @default_stderr_capture_bytes)

    unless is_integer(stderr_capture_bytes) and stderr_capture_bytes >= 0 do
      raise ArgumentError, ":stderr_capture_bytes must be a non-negative integer"
    end

    max_line_bytes = byte_bound!(adapter_opts, :max_line_bytes, @default_max_line_bytes)
    max_output_bytes = byte_bound!(adapter_opts, :max_output_bytes, :infinity)

    open_opts = [config: config, args: args, owner: self()] ++ adapter_opts

    # An optional lifecycle owner (e.g. the IEx evaluator driving DuplexIEx):
    # monitor it and stop when it dies, so an abandoned session reaps its claude
    # subprocess instead of orphaning it. Distinct from the adapter's `owner`
    # above (the GenServer, which receives the port's stdio messages).
    owner_ref =
      case Keyword.get(opts, :owner) do
        owner when is_pid(owner) -> Process.monitor(owner)
        _ -> nil
      end

    case adapter.open(open_opts) do
      {:ok, handle} ->
        session_monotonic = Telemetry.duplex_session_start(%{command: :duplex_session})

        state = %__MODULE__{
          port: handle,
          adapter: adapter,
          config: config,
          on_permission: on_permission,
          on_control_request: on_control_request,
          sdk_mcp_servers: sdk_mcp_servers,
          owner_ref: owner_ref,
          stderr_capture_bytes: stderr_capture_bytes,
          max_line_bytes: max_line_bytes,
          max_output_bytes: max_output_bytes,
          session_monotonic: session_monotonic
        }

        {:ok, maybe_initialize(state, Keyword.get(opts, :initialize, false))}

      {:error, reason} ->
        {:stop, reason}
    end
  end

  defp fetch_control_handler!(opts) do
    case Keyword.get(opts, :on_control_request, &__MODULE__.unsupported_control/3) do
      handler when is_function(handler, 3) -> handler
      _ -> raise ArgumentError, ":on_control_request must be a 3-arity function"
    end
  end

  defp fetch_sdk_mcp_servers!(opts) do
    servers = Keyword.get(opts, :sdk_mcp_servers, %{})

    valid? =
      is_map(servers) and
        Enum.all?(servers, fn {name, handler} -> is_binary(name) and is_function(handler, 1) end)

    unless valid? do
      raise ArgumentError, ":sdk_mcp_servers must map server names to 1-arity functions"
    end

    servers
  end

  # In-process servers are declared to the CLI as `type: "sdk"` entries in
  # their own --mcp-config; the CLI merges it with any other --mcp-config.
  defp sdk_mcp_args(servers) when map_size(servers) == 0, do: []

  defp sdk_mcp_args(servers) do
    entries = Map.new(servers, fn {name, _} -> {name, %{type: "sdk", name: name}} end)
    ["--mcp-config", Jason.encode!(%{mcpServers: entries})]
  end

  # Send `initialize` when asked for, or when SDK MCP servers need it to be
  # registered. Its response is held for initialize_response/2.
  defp maybe_initialize(%{sdk_mcp_servers: servers} = state, false)
       when map_size(servers) == 0,
       do: state

  defp maybe_initialize(state, initialize) do
    fields =
      case initialize do
        map when is_map(map) ->
          Map.new(map, fn {key, value} -> {to_string(key), value} end)

        flag when is_boolean(flag) ->
          %{}

        other ->
          raise ArgumentError, ":initialize must be a boolean or a map, got: #{inspect(other)}"
      end

    names = Enum.uniq(Map.get(fields, "sdkMcpServers", []) ++ Map.keys(state.sdk_mcp_servers))
    fields = if names == [], do: fields, else: Map.put(fields, "sdkMcpServers", names)
    request = Map.put(fields, "subtype", "initialize")

    request_id = generate_request_id()
    msg = %{type: "control_request", request_id: request_id, request: request}

    case state.adapter.command(state.port, [Jason.encode!(msg), ?\n]) do
      :ok ->
        %{
          state
          | initialize: :pending,
            pending_control: Map.put(state.pending_control, request_id, :initialize)
        }

      {:error, reason} ->
        error = Error.new(:terminated, reason: {:transport_write, reason})
        %{state | initialize: {:error, error}}
    end
  end

  # The transport to use when no explicit `:adapter` is given.
  # `Adapter.Port` by default; set globally with
  # `config :claude_wrapper, duplex_adapter: Adapter.Forcola` for
  # leak-free (process-group-kill) sessions.
  defp default_adapter do
    Application.get_env(:claude_wrapper, :duplex_adapter, Adapter.Port)
  end

  @impl true
  def handle_call({:send, prompt}, from, %{pending_turn: nil, port: port} = state)
      when not is_nil(port) do
    msg = %{
      type: "user",
      message: %{role: "user", content: prompt},
      parent_tool_use_id: nil
    }

    case state.adapter.command(port, [Jason.encode!(msg), ?\n]) do
      :ok ->
        span = Telemetry.duplex_turn_start(%{command: :duplex_turn, session_id: state.session_id})
        {:noreply, %{state | pending_turn: {from, []}, turn_span: span}}

      {:error, reason} ->
        {:reply, {:error, Error.new(:terminated, reason: {:transport_write, reason})}, state}
    end
  end

  def handle_call({:send, _prompt}, _from, %{pending_turn: nil, port: nil} = state) do
    {:reply, {:error, Error.new(:duplex_closed)}, state}
  end

  def handle_call({:send, _prompt}, _from, state) do
    {:reply, {:error, Error.new(:turn_in_flight)}, state}
  end

  def handle_call(:session_id, _from, state), do: {:reply, state.session_id, state}

  def handle_call(:exit_status, _from, state), do: {:reply, state.exit_status, state}

  def handle_call(:shutdown, _from, state) do
    {terminal, state} = close_transport(state)
    {:stop, :normal, {:ok, terminal}, state}
  end

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

  def handle_call({:respond_to_permission, _request_id, :defer}, _from, state) do
    {:reply, {:error, Error.new(:cannot_defer_again)}, state}
  end

  def handle_call({:respond_to_permission, request_id, decision}, _from, state) do
    if MapSet.member?(state.deferred_permissions, request_id) do
      write_permission_response(state, request_id, decision)

      {:reply, :ok,
       %{state | deferred_permissions: MapSet.delete(state.deferred_permissions, request_id)}}
    else
      # A genuine no-op for a request_id the session has no record of: never
      # deferred, or already answered / resolved by an interrupt. Previously this
      # wrote a stray control_response unconditionally, contradicting the docs.
      {:reply, :ok, state}
    end
  end

  def handle_call({:respond_to_control, request_id, reply}, _from, state) do
    if MapSet.member?(state.deferred_controls, request_id) do
      write_control_reply(state, request_id, reply)

      {:reply, :ok,
       %{state | deferred_controls: MapSet.delete(state.deferred_controls, request_id)}}
    else
      {:reply, :ok, state}
    end
  end

  def handle_call(:initialize_response, from, %{initialize: :pending} = state) do
    {:noreply, %{state | initialize_waiters: [from | state.initialize_waiters]}}
  end

  def handle_call(:initialize_response, _from, %{initialize: :not_requested} = state) do
    {:reply, {:error, Error.new(:not_found, reason: :initialize_not_requested)}, state}
  end

  def handle_call(:initialize_response, _from, state), do: {:reply, state.initialize, state}

  def handle_call({:control, _request}, _from, %{port: nil} = state) do
    {:reply, {:error, Error.new(:duplex_closed)}, state}
  end

  def handle_call({:control, request}, from, state) do
    request_id = generate_request_id()
    msg = %{type: "control_request", request_id: request_id, request: request}

    case state.adapter.command(state.port, [Jason.encode!(msg), ?\n]) do
      :ok ->
        {:noreply, %{state | pending_control: Map.put(state.pending_control, request_id, from)}}

      {:error, reason} ->
        {:reply, {:error, Error.new(:terminated, reason: {:transport_write, reason})}, state}
    end
  end

  @impl true
  def handle_info({port, {:data, chunk, ref}}, %{port: port} = state) do
    {complete, rest} = split_lines(state.buffer <> chunk)
    state = Enum.reduce(complete, %{state | buffer: rest}, &handle_line/2)
    state.adapter.ack(port, ref)
    {:noreply, state}
  end

  # Unacknowledged delivery (Adapter.Port, the test adapter): the session
  # holds the pending line, so it enforces the line and output bounds here
  # (#311). Adapter.Forcola bounds its own output.
  def handle_info({port, {:data, chunk}}, %{port: port} = state) do
    output_bytes = state.output_bytes + byte_size(chunk)
    {complete, rest} = split_lines(state.buffer <> chunk)

    case output_limit(state, output_bytes, complete, rest) do
      nil ->
        state =
          Enum.reduce(
            complete,
            %{state | buffer: rest, output_bytes: output_bytes},
            &handle_line/2
          )

        {:noreply, state}

      reason ->
        state = fail_pending(state, {:transport_error, reason})

        {:stop, :normal,
         %{state | buffer: <<>>, exit_status: {:failed, {:transport_error, reason}}}}
    end
  end

  def handle_info({port, {:stderr, line, ref}}, %{port: port} = state) do
    state = capture_stderr(state, line)
    state.adapter.ack(port, ref)
    {:noreply, state}
  end

  def handle_info({port, {:terminal, evidence}}, %{port: port} = state) do
    terminal = %TransportTerminal{evidence: evidence, stderr: state.stderr}
    broadcast(state, {:transport_terminal, terminal})
    state = fail_pending(state, {:transport_terminal, evidence})

    {:stop, :normal,
     %{
       state
       | port: nil,
         transport_terminal: terminal,
         exit_status: terminal_exit_status(evidence)
     }}
  end

  def handle_info({port, {:transport_error, reason}}, %{port: port} = state) do
    state = fail_pending(state, {:transport_error, reason})
    {:stop, :normal, %{state | exit_status: {:failed, {:transport_error, reason}}}}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port} = state) do
    state = state |> exited_terminal({:exit_status, code}) |> fail_pending({:port_exit, code})
    status = derive_exit_status({:port_exit, code})
    {:stop, :normal, %{state | port: nil, exit_status: status}}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    state = state |> exited_terminal({:exit, reason}) |> fail_pending({:port_exit, reason})
    status = derive_exit_status({:port_exit, reason})
    {:stop, :normal, %{state | port: nil, exit_status: status}}
  end

  # The lifecycle owner (e.g. an abandoned IEx evaluator) died: stop so
  # `terminate/2` closes the transport and reaps the claude subprocess, rather
  # than leaving it running ownerless until BEAM exit.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, %{owner_ref: ref} = state) do
    {:stop, :normal, state}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{port: %{monitor: ref}} = state) do
    state = fail_pending(state, {:transport_error, {:puller_down, reason}})

    {:stop, :normal,
     %{state | exit_status: {:failed, {:transport_error, {:puller_down, reason}}}}}
  end

  def handle_info({:mcp_reply, pid, response}, state) do
    case Map.pop(state.mcp_tasks, pid) do
      {nil, _} ->
        {:noreply, state}

      {{ref, id}, rest} ->
        Process.demonitor(ref, [:flush])
        write_control_reply(state, id, {:ok, %{mcp_response: response}})
        {:noreply, %{state | mcp_tasks: rest}}
    end
  end

  # An MCP handler process died without replying (it was killed): answer
  # the CLI so it does not wait on the request.
  def handle_info({:DOWN, _ref, :process, pid, reason}, %{mcp_tasks: tasks} = state)
      when is_map_key(tasks, pid) do
    {{_ref, id}, rest} = Map.pop(tasks, pid)
    write_control_reply(state, id, {:error, "MCP handler exited: #{inspect(reason)}"})
    {:noreply, %{state | mcp_tasks: rest}}
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
    {_terminal, state} =
      if is_nil(port), do: {state.transport_terminal, state}, else: close_transport(state)

    state = fail_pending(state, :terminated)
    Enum.each(Map.keys(state.mcp_tasks), &Process.exit(&1, :kill))
    notify_exit_waiters(state, final_exit_status(state, reason))

    Telemetry.duplex_session_stop(state.session_monotonic, %{
      command: :duplex_session,
      session_id: state.session_id
    })

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

  @doc """
  Default inbound control handler. Answers every request with an error in
  the CLI's own wording, so an unhandled request does not wait forever.

  Public so a custom handler can fall back to it for subtypes it ignores.
  """
  @spec unsupported_control(String.t(), map(), String.t()) :: control_reply()
  def unsupported_control(subtype, _request, _request_id),
    do: {:error, "Unsupported control request subtype: #{subtype}"}

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
      :defer ->
        if handler_arity(state.on_permission) == 3 do
          # 3-arity handler deferred: track the id so respond_to_permission/3 can
          # answer it later, and so an unknown/duplicate id is a genuine no-op.
          %{state | deferred_permissions: MapSet.put(state.deferred_permissions, id)}
        else
          # A 2-arity handler never receives the request_id, so no process can
          # answer -- the turn would wedge permanently with `alive?/1` still true.
          # Deny so the turn resolves, and tell the host to use the 3-arity form.
          Logger.warning(
            "DuplexSession: a 2-arity on_permission returned :defer for " <>
              "#{inspect(tool_name)}, but a 2-arity handler cannot receive the " <>
              "request_id needed to answer it later -- the turn would wedge. " <>
              "Denying. Use a 3-arity (tool_name, input, request_id) handler to defer."
          )

          write_permission_response(state, id, {:deny, "2-arity on_permission cannot defer"})
          state
        end

      _ ->
        write_permission_response(state, id, default_allow_input(decision, input))
        state
    end
  end

  # An mcp_message for an in-process server runs its handler in a separate
  # process; the reply is written when it finishes (see handle_info
  # {:mcp_reply, ...}). Messages for other server names fall through to
  # on_control_request.
  defp dispatch(
         %{
           "type" => "control_request",
           "request_id" => id,
           "request" => %{"subtype" => "mcp_message", "server_name" => name} = req
         },
         %{sdk_mcp_servers: servers} = state
       )
       when is_map_key(servers, name) do
    handler = Map.fetch!(servers, name)
    message = req["message"] || %{}
    session = self()

    {pid, ref} =
      spawn_monitor(fn ->
        Kernel.send(session, {:mcp_reply, self(), run_mcp_handler(handler, message)})
      end)

    %{state | mcp_tasks: Map.put(state.mcp_tasks, pid, {ref, id})}
  end

  # Any other inbound control request goes to the on_control_request
  # handler. Every path answers it unless the handler defers, so the CLI is
  # never left waiting on a request nobody handles.
  defp dispatch(
         %{
           "type" => "control_request",
           "request_id" => id,
           "request" => %{"subtype" => subtype} = req
         },
         state
       ) do
    reply =
      try do
        state.on_control_request.(subtype, req, id)
      rescue
        e ->
          Logger.error(
            "DuplexSession: on_control_request raised for #{inspect(subtype)}: #{inspect(e)}"
          )

          {:error, "control handler raised: #{Exception.message(e)}"}
      end

    case normalize_control_reply(reply) do
      :defer ->
        %{state | deferred_controls: MapSet.put(state.deferred_controls, id)}

      reply ->
        write_control_reply(state, id, reply)
        state
    end
  end

  # The CLI withdrew a request it sent. A late answer becomes a no-op.
  defp dispatch(%{"type" => "control_cancel_request", "request_id" => id}, state) do
    broadcast(state, {:control_cancel, id})

    %{
      state
      | deferred_controls: MapSet.delete(state.deferred_controls, id),
        deferred_permissions: MapSet.delete(state.deferred_permissions, id)
    }
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

      {:initialize, rest} ->
        settle_initialize(%{state | pending_control: rest}, control_reply(resp))

      {from, rest} ->
        GenServer.reply(from, control_reply(resp))
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
    # An API-error result is returned as a typed error (#316); subscribers
    # still see the result itself.
    GenServer.reply(from, Query.classify_api_error(result, nil, nil, nil))

    Telemetry.duplex_turn_stop(state.turn_span, %{
      command: :duplex_turn,
      session_id: result.session_id || state.session_id,
      cost_usd: result.cost_usd,
      exit_code: 0
    })

    # The turn is over; any still-tracked deferred permission ids are moot, so a
    # late respond_to_permission/3 for this turn becomes a documented no-op.
    %{state | pending_turn: nil, turn_span: nil, deferred_permissions: MapSet.new()}
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

  defp handler_arity(handler) do
    {:arity, arity} = :erlang.fun_info(handler, :arity)
    arity
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
    Telemetry.duplex_turn_exception(state.turn_span, reason)
    %{state | pending_turn: nil, turn_span: nil}
  end

  defp fail_pending_control(%{pending_control: pending} = state, _reason)
       when map_size(pending) == 0,
       do: state

  defp fail_pending_control(%{pending_control: pending} = state, reason) do
    error = fail_reason_to_error(reason)

    Enum.reduce(pending, %{state | pending_control: %{}}, fn
      {_id, :initialize}, acc ->
        settle_initialize(acc, {:error, error})

      {_id, from}, acc ->
        GenServer.reply(from, {:error, error})
        acc
    end)
  end

  defp control_reply(%{"subtype" => "success"} = resp), do: {:ok, resp["response"] || %{}}

  defp control_reply(%{"subtype" => "error", "error" => err}),
    do: {:error, control_failed(err)}

  defp control_reply(other), do: {:error, control_failed(other)}

  defp settle_initialize(state, result) do
    Enum.each(state.initialize_waiters, &GenServer.reply(&1, result))
    %{state | initialize: result, initialize_waiters: []}
  end

  # Runs in the handler process. Every outcome becomes a JSON-RPC message so
  # the CLI always gets an answer.
  defp run_mcp_handler(handler, message) do
    case handler.(message) do
      %{} = response -> response
      nil -> %{"jsonrpc" => "2.0", "result" => %{}}
      other -> jsonrpc_error(message, "MCP handler returned #{inspect(other)}")
    end
  rescue
    e -> jsonrpc_error(message, Exception.message(e))
  catch
    kind, reason -> jsonrpc_error(message, "#{kind}: #{inspect(reason)}")
  end

  defp jsonrpc_error(message, text) do
    error = %{"jsonrpc" => "2.0", "error" => %{"code" => -32_603, "message" => text}}

    case message do
      %{"id" => id} -> Map.put(error, "id", id)
      _ -> error
    end
  end

  # Map the internal fail-pending reasons to the canonical Error. A clean
  # `:terminated` (terminate/2) stays bare; a `{:port_exit, x}` from a
  # subprocess exit is carried in :reason so callers can recover the code.
  defp fail_reason_to_error(:terminated), do: Error.new(:terminated)

  defp fail_reason_to_error({:port_exit, _} = reason),
    do: Error.new(:terminated, reason: reason)

  defp fail_reason_to_error({:transport_terminal, _} = reason),
    do: Error.new(:terminated, reason: reason)

  defp fail_reason_to_error({:transport_error, _} = reason),
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

  defp write_control_reply(%{port: nil}, _request_id, _reply), do: :ok

  defp write_control_reply(state, request_id, reply) do
    response =
      case reply do
        {:ok, body} -> %{subtype: "success", request_id: request_id, response: body}
        {:error, message} -> %{subtype: "error", request_id: request_id, error: message}
      end

    msg = %{type: "control_response", response: response}
    state.adapter.command(state.port, [Jason.encode!(msg), ?\n])
    :ok
  end

  # A handler return outside the documented shapes becomes an error reply
  # rather than a crash or a request left unanswered.
  defp normalize_control_reply({:ok, body} = reply) when is_map(body), do: reply
  defp normalize_control_reply({:error, message} = reply) when is_binary(message), do: reply
  defp normalize_control_reply(:defer), do: :defer

  defp normalize_control_reply(other) do
    Logger.error("DuplexSession: on_control_request returned an invalid reply: #{inspect(other)}")
    {:error, "control handler returned an invalid reply"}
  end

  defp validate_control_reply!({:ok, body} = reply) when is_map(body), do: reply
  defp validate_control_reply!({:error, message} = reply) when is_binary(message), do: reply

  defp validate_control_reply!(other),
    do: raise(ArgumentError, "expected {:ok, map} or {:error, string}, got: #{inspect(other)}")

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

  defp capture_stderr(%{stderr_capture_bytes: 0} = state, _line), do: state

  defp capture_stderr(state, line) do
    combined = state.stderr <> line <> "\n"
    size = byte_size(combined)
    kept = min(size, state.stderr_capture_bytes)
    %{state | stderr: binary_part(combined, size - kept, kept)}
  end

  defp close_transport(%{port: nil} = state), do: {state.transport_terminal, state}

  defp close_transport(%{port: port, adapter: adapter} = state) do
    terminal = shut_transport(adapter, port, state)

    if terminal, do: broadcast(state, {:transport_terminal, terminal})

    status =
      cond do
        state.exit_status != :running -> state.exit_status
        terminal -> terminal_exit_status(terminal.evidence)
        true -> state.exit_status
      end

    {terminal, %{state | port: nil, transport_terminal: terminal, exit_status: status}}
  end

  # Close the transport and return its terminal record, if the adapter has one.
  defp shut_transport(adapter, port, state) do
    cond do
      function_exported?(adapter, :shutdown, 1) ->
        case adapter.shutdown(port) do
          {:ok, evidence} ->
            %TransportTerminal{evidence: evidence, stderr: state.stderr}

          {:error, reason} ->
            %TransportTerminal{evidence: {:error, reason}, stderr: state.stderr}
        end

      function_exported?(adapter, :stderr_tail, 2) ->
        stderr = adapter.stderr_tail(port, state.stderr_capture_bytes)
        :ok = adapter.close(port)
        %TransportTerminal{evidence: :closed, stderr: stderr}

      true ->
        :ok = adapter.close(port)
        nil
    end
  end

  # An adapter that captures stderr outside the message stream (Adapter.Port)
  # reports its tail when the child exits on its own, then releases the
  # transport's resources.
  defp exited_terminal(%{port: port, adapter: adapter} = state, evidence) do
    if function_exported?(adapter, :stderr_tail, 2) do
      terminal = %TransportTerminal{
        evidence: evidence,
        stderr: adapter.stderr_tail(port, state.stderr_capture_bytes)
      }

      :ok = adapter.close(port)
      broadcast(state, {:transport_terminal, terminal})
      %{state | transport_terminal: terminal}
    else
      state
    end
  end

  defp output_limit(state, output_bytes, complete, rest) do
    cond do
      over?(output_bytes, state.max_output_bytes) ->
        {:output_limit, :output, state.max_output_bytes}

      over?(byte_size(rest), state.max_line_bytes) or
          Enum.any?(complete, &over?(byte_size(&1), state.max_line_bytes)) ->
        {:output_limit, :line, state.max_line_bytes}

      true ->
        nil
    end
  end

  defp over?(_bytes, :infinity), do: false
  defp over?(bytes, limit), do: bytes > limit

  defp byte_bound!(opts, key, default) do
    case Keyword.get(opts, key, default) do
      :infinity ->
        :infinity

      bytes when is_integer(bytes) and bytes > 0 ->
        bytes

      other ->
        raise ArgumentError,
              "#{inspect(key)} must be a positive integer or :infinity, got: #{inspect(other)}"
    end
  end

  defp terminal_exit_status(:closed), do: :completed

  defp terminal_exit_status(%{confirmation: :confirmed, cause: :explicit_close}),
    do: :completed

  defp terminal_exit_status(%{
         confirmation: :confirmed,
         cause: :child_exit,
         status: 0,
         output: :complete
       }),
       do: :completed

  defp terminal_exit_status(evidence), do: {:failed, {:transport_terminal, evidence}}

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
