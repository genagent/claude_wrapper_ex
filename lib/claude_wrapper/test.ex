defmodule ClaudeWrapper.Test do
  @moduledoc """
  Drive a `ClaudeWrapper.DuplexSession` against an in-process double, with
  no `claude` binary and no network.

  `start_session/1` returns a live session wired to
  `ClaudeWrapper.DuplexSession.Adapter.Test` plus a *stub* handle you feed
  NDJSON events to. The session behaves exactly as it does over a real
  subprocess -- same `send/3`, same subscriber events, same `Result` -- so
  it is a faithful way to test code that drives `claude_wrapper`.

  Each `start_session/1` gets its own stub process and nothing is shared
  between sessions, so `async: true` tests are safe.

  ## Example

      {:ok, session, stub} = ClaudeWrapper.Test.start_session()

      # `send/3` blocks until the turn's result, so drive it from a task.
      task = Task.async(fn -> ClaudeWrapper.DuplexSession.send(session, "hi") end)

      ClaudeWrapper.Test.emit(stub, [
        ClaudeWrapper.Test.text_delta("Hello")
      ])
      ClaudeWrapper.Test.emit_result(stub, result: "Hello", session_id: "s-1")

      {:ok, %ClaudeWrapper.Result{session_id: "s-1"}} = Task.await(task)

  ## Canned replies

  For the common "send a prompt, get a fixed answer" shape, queue a reply
  and it is emitted automatically on the next `send/3`:

      ClaudeWrapper.Test.stub(stub, [
        ClaudeWrapper.Test.text_delta("Hi"),
        ClaudeWrapper.Test.result(result: "Hi")
      ])

      {:ok, _result} = ClaudeWrapper.DuplexSession.send(session, "anything")
  """

  alias ClaudeWrapper.{Config, DuplexSession}
  alias ClaudeWrapper.DuplexSession.Adapter

  @typedoc "A line to feed the session: a map (JSON-encoded) or a raw string."
  @type line :: map() | String.t()

  @doc """
  Start a `DuplexSession` backed by the test adapter.

  Returns `{:ok, session, stub}` where `stub` is the controller handle you
  pass to `emit/2`, `emit_result/2`, and `stub/2`.

  Options:

    * `:config` -- a `t:ClaudeWrapper.Config.t/0` (a dummy is used by
      default; the test adapter never launches a binary)
    * `:on_permission` -- forwarded to `DuplexSession.start_link/1`
    * any other `DuplexSession` option except `:adapter`/`:adapter_opts`
  """
  @spec start_session(keyword()) :: {:ok, pid(), pid()}
  def start_session(opts \\ []) do
    config = Keyword.get(opts, :config, Config.new(binary: "claude-wrapper-test-double"))
    controller = Adapter.Test.start_controller()

    ds_opts =
      opts
      |> Keyword.drop([:config, :adapter, :adapter_opts])
      |> Keyword.merge(
        config: config,
        adapter: Adapter.Test,
        adapter_opts: [controller: controller]
      )

    {:ok, session} = DuplexSession.start_link(ds_opts)
    {:ok, session, controller}
  end

  @doc """
  Feed NDJSON `lines` to the session now, as if the subprocess emitted
  them. Each line is a map (JSON-encoded) or a raw string.
  """
  @spec emit(pid(), [line()] | line()) :: :ok
  def emit(stub, lines) do
    send(stub, {:emit, normalize(lines)})
    :ok
  end

  @doc """
  Emit a `result` event, ending the current turn.

  `attrs` are merged into a minimal success result (see `result/1`).
  """
  @spec emit_result(pid(), keyword()) :: :ok
  def emit_result(stub, attrs \\ []), do: emit(stub, [result(attrs)])

  @doc """
  Queue a one-shot canned reply emitted automatically on the next
  `DuplexSession.send/3`. Use for the "prompt in, fixed answer out" shape.
  """
  @spec stub(pid(), [line()] | line()) :: :ok
  def stub(stub, lines) do
    send(stub, {:set_reply, normalize(lines)})
    :ok
  end

  @doc "Simulate the subprocess exiting with `code`."
  @spec exit_status(pid(), integer()) :: :ok
  def exit_status(stub, code) do
    send(stub, {:exit_status, code})
    :ok
  end

  # -- event builders ------------------------------------------------

  @doc "A `stream_event` carrying a text delta."
  @spec text_delta(String.t(), non_neg_integer()) :: map()
  def text_delta(text, index \\ 0) do
    block_delta(index, %{"type" => "text_delta", "text" => text})
  end

  @doc "A `stream_event` carrying an extended-thinking delta."
  @spec thinking_delta(String.t(), non_neg_integer()) :: map()
  def thinking_delta(text, index \\ 0) do
    block_delta(index, %{"type" => "thinking_delta", "thinking" => text})
  end

  @doc "A minimal success `result` event; `attrs` override the defaults."
  @spec result(keyword()) :: map()
  def result(attrs \\ []) do
    base = %{
      "type" => "result",
      "subtype" => "success",
      "is_error" => false,
      "result" => Keyword.get(attrs, :result, ""),
      "session_id" => Keyword.get(attrs, :session_id, "test-session")
    }

    Enum.reduce(attrs, base, fn {k, v}, acc -> Map.put(acc, to_string(k), v) end)
  end

  defp block_delta(index, delta) do
    %{
      "type" => "stream_event",
      "event" => %{"type" => "content_block_delta", "index" => index, "delta" => delta}
    }
  end

  defp normalize(lines) when is_list(lines), do: Enum.map(lines, &to_line/1)
  defp normalize(line), do: [to_line(line)]

  defp to_line(map) when is_map(map), do: Jason.encode!(map) <> "\n"
  defp to_line(str) when is_binary(str), do: ensure_newline(str)

  defp ensure_newline(str) do
    if String.ends_with?(str, "\n"), do: str, else: str <> "\n"
  end
end
