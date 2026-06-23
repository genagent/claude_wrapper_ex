defmodule ClaudeWrapper.DuplexSession.Adapter.Test do
  @moduledoc """
  In-process test double for `ClaudeWrapper.DuplexSession.Adapter`.

  Instead of a `claude` subprocess, the transport is a lightweight
  controller process the test drives directly. The controller is created
  per session and passed in via `:controller` in the session's
  `:adapter_opts`; because nothing is shared between sessions, concurrent
  (`async: true`) tests cannot collide -- no global registry, no extra
  dependency.

  Drive it through `ClaudeWrapper.Test` rather than calling this module
  directly.

  ## Protocol

  The controller accepts:

    * `{:emit, lines}` -- send each line to the session as a
      `{handle, {:data, line}}` message (NDJSON the session parses)
    * `{:set_reply, lines}` -- queue a one-shot canned reply emitted on
      the next outbound `command/2` (a faked turn response)
    * `{:exit_status, code}` -- send the session `{handle, {:exit_status,
      code}}` (simulate the subprocess exiting)
    * `:close` -- stop

  and, on `open/1`, is told its `:owner` (the session pid) and linked to
  it so a session crash tears the controller down and vice versa.
  """

  @behaviour ClaudeWrapper.DuplexSession.Adapter

  @impl true
  def open(opts) do
    owner = Keyword.fetch!(opts, :owner)
    controller = Keyword.fetch!(opts, :controller)

    send(controller, {:bind_owner, owner})
    Process.link(controller)
    {:ok, controller}
  end

  @impl true
  def command(controller, iodata) do
    send(controller, {:command, IO.iodata_to_binary(iodata)})
    :ok
  end

  @impl true
  def close(controller) do
    if Process.alive?(controller), do: send(controller, :close)
    :ok
  end

  @doc false
  @spec start_controller() :: pid()
  def start_controller do
    spawn(fn -> loop(%{owner: nil, reply: nil}) end)
  end

  defp loop(state) do
    receive do
      {:bind_owner, owner} ->
        loop(%{state | owner: owner})

      {:command, _data} ->
        # A real turn replies to the prompt the session just wrote. If a
        # canned reply was queued, emit it now (one-shot).
        case state.reply do
          nil -> :ok
          lines -> emit(state.owner, lines)
        end

        loop(%{state | reply: nil})

      {:emit, lines} ->
        emit(state.owner, lines)
        loop(state)

      {:set_reply, lines} ->
        loop(%{state | reply: lines})

      {:exit_status, code} ->
        if state.owner, do: send(state.owner, {self(), {:exit_status, code}})
        loop(state)

      :close ->
        :ok
    end
  end

  defp emit(nil, _lines), do: :ok

  defp emit(owner, lines) do
    Enum.each(lines, fn line -> send(owner, {self(), {:data, line}}) end)
  end
end
