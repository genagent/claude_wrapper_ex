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

  ## PR 1 scope

  This module currently implements the minimal happy path: `start_link/1`,
  `send/3`, port spawn, line buffering, and `result -> reply`. Subscribers,
  permission callbacks, and interrupt are **not yet wired** -- they land in
  follow-up PRs.

  ## Usage

      config = ClaudeWrapper.Config.new()

      {:ok, pid} = ClaudeWrapper.DuplexSession.start_link(config: config)
      {:ok, result} = ClaudeWrapper.DuplexSession.send(pid, "Say hi.")

      ClaudeWrapper.DuplexSession.session_id(pid)
      #=> "abc123-..."

      ClaudeWrapper.DuplexSession.stop(pid)
  """

  use GenServer
  require Logger

  alias ClaudeWrapper.{Config, Result}

  @type option ::
          {:config, Config.t()}
          | {:extra_args, [String.t()]}
          | {:name, GenServer.name()}
          | GenServer.option()

  @type state :: %__MODULE__{
          port: port() | nil,
          config: Config.t(),
          session_id: String.t() | nil,
          buffer: binary(),
          pending_turn: {GenServer.from(), [map()]} | nil
        }

  defstruct [
    :port,
    :config,
    :session_id,
    buffer: <<>>,
    pending_turn: nil
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

    args = build_args(extra_args)

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, args}] ++
        port_env_opts(config) ++
        port_cd_opts(config)

    port = Port.open({:spawn_executable, config.binary}, port_opts)
    {:ok, %__MODULE__{port: port, config: config}}
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
      "--print"
    ] ++ extra
  end

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

  # system/init carries the session_id we'll need for resume in later PRs.
  defp dispatch(%{"type" => "system", "subtype" => "init", "session_id" => sid}, state) do
    %{state | session_id: sid}
  end

  # Turn boundary: reply to the waiting caller with a parsed Result.
  defp dispatch(%{"type" => "result"} = msg, %{pending_turn: {from, _events}} = state) do
    GenServer.reply(from, {:ok, Result.from_json(msg)})
    %{state | pending_turn: nil}
  end

  defp dispatch(%{"type" => "result"}, state), do: state

  # Within an active turn, accumulate every other event for later use
  # (subscribers in PR 2 will read these). Outside a turn, drop.
  defp dispatch(msg, %{pending_turn: {from, events}} = state) do
    %{state | pending_turn: {from, [msg | events]}}
  end

  defp dispatch(_msg, state), do: state

  defp fail_pending(%{pending_turn: nil} = state, _reason), do: state

  defp fail_pending(%{pending_turn: {from, _}} = state, reason) do
    GenServer.reply(from, {:error, reason})
    %{state | pending_turn: nil}
  end

  defp port_env_opts(%Config{env: []}), do: []
  defp port_env_opts(%Config{env: env}), do: [{:env, env}]

  defp port_cd_opts(%Config{working_dir: nil}), do: []
  defp port_cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
