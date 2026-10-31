defmodule ClaudeWrapper.DuplexSession.TurnDeadlineTest.WireAdapter do
  @moduledoc false
  @behaviour ClaudeWrapper.DuplexSession.Adapter

  @impl true
  def open(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    handle = {:wire, make_ref(), test_pid}
    send(test_pid, {:wire_open, handle})
    {:ok, handle}
  end

  @impl true
  def command({:wire, _ref, test_pid}, iodata) do
    for line <- String.split(IO.iodata_to_binary(iodata), "\n", trim: true) do
      send(test_pid, {:wire_out, Jason.decode!(line)})
    end

    :ok
  end

  @impl true
  def close(_handle), do: :ok
end

defmodule ClaudeWrapper.DuplexSession.TurnDeadlineTest do
  @moduledoc "A turn whose caller times out, exits or cancels is interrupted (#323)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Error, Result}
  alias ClaudeWrapper.DuplexSession.TurnDeadlineTest.WireAdapter

  defp start(opts \\ []) do
    {:ok, pid} =
      DuplexSession.start_link(
        [
          config: Config.new(binary: "unused"),
          adapter: WireAdapter,
          adapter_opts: [test_pid: self()]
        ] ++
          opts
      )

    assert_receive {:wire_open, handle}
    {pid, handle}
  end

  defp cli_says(pid, handle, msg) do
    send(pid, {handle, {:data, Jason.encode!(msg) <> "\n"}})
    :sys.get_state(pid)
  end

  defp result_for(uuid, text),
    do: %{
      type: "result",
      subtype: "success",
      is_error: false,
      result: text,
      user_message_uuids: [uuid]
    }

  defp sent_uuid do
    assert_receive {:wire_out, %{"type" => "user", "uuid" => uuid}}
    uuid
  end

  defp assert_interrupt_written do
    assert_receive {:wire_out,
                    %{"type" => "control_request", "request" => %{"subtype" => "interrupt"}}}
  end

  test "a send/3 deadline returns :timeout, interrupts the turn, and frees the session after its result" do
    {pid, handle} = start()

    assert {:error, %Error{kind: :timeout, reason: 200}} = DuplexSession.send(pid, "slow", 200)
    uuid = sent_uuid()
    assert_interrupt_written()

    # The interrupted turn is still pending until its result arrives.
    assert {:error, %Error{kind: :turn_in_flight}} = DuplexSession.send(pid, "too soon", 1_000)

    cli_says(pid, handle, result_for(uuid, ""))

    parent = self()
    spawn_link(fn -> send(parent, {:next, DuplexSession.send(pid, "next", 5_000)}) end)
    next = sent_uuid()
    cli_says(pid, handle, result_for(next, "next answer"))
    assert_receive {:next, {:ok, %Result{result: "next answer"}}}
  end

  test "an :infinity send/3 sets no deadline" do
    {pid, handle} = start()
    parent = self()
    spawn_link(fn -> send(parent, {:done, DuplexSession.send(pid, "p", :infinity)}) end)
    uuid = sent_uuid()

    refute_receive {:wire_out, _}, 300
    cli_says(pid, handle, result_for(uuid, "ok"))
    assert_receive {:done, {:ok, %Result{result: "ok"}}}
  end

  test "send_async/3 delivers the outcome as a message" do
    {pid, handle} = start()
    assert {:ok, ref} = DuplexSession.send_async(pid, "p")
    uuid = sent_uuid()

    cli_says(pid, handle, result_for(uuid, "async answer"))
    assert_receive {:duplex_turn, ^ref, {:ok, %Result{result: "async answer"}}}
  end

  test "cancel/2 interrupts the async turn, whose result is still delivered" do
    {pid, handle} = start()
    {:ok, ref} = DuplexSession.send_async(pid, "p")
    uuid = sent_uuid()

    assert :ok = DuplexSession.cancel(pid, ref)
    assert_interrupt_written()

    cli_says(pid, handle, result_for(uuid, ""))
    assert_receive {:duplex_turn, ^ref, {:ok, %Result{}}}

    assert {:error, %Error{kind: :not_found}} = DuplexSession.cancel(pid, ref)
  end

  test "send_async/3 with a deadline reports :timeout as a message" do
    {pid, _handle} = start()
    {:ok, ref} = DuplexSession.send_async(pid, "p", 100)
    sent_uuid()

    assert_receive {:duplex_turn, ^ref, {:error, %Error{kind: :timeout, reason: 100}}}, 2_000
    assert_interrupt_written()
  end

  test "with cancel_on_caller_exit, the turn is interrupted when its caller exits" do
    {pid, _handle} = start(cancel_on_caller_exit: true)
    caller = spawn(fn -> DuplexSession.send(pid, "p", :infinity) end)
    sent_uuid()

    Process.exit(caller, :kill)
    assert_interrupt_written()
  end

  test "without cancel_on_caller_exit, a caller's exit leaves the turn running" do
    {pid, _handle} = start()
    caller = spawn(fn -> DuplexSession.send(pid, "p", :infinity) end)
    sent_uuid()

    Process.exit(caller, :kill)
    refute_receive {:wire_out, _}, 300
  end

  test "halting a ClaudeWrapper.Stream early interrupts the turn with cancel_on_caller_exit" do
    {pid, handle} = start(cancel_on_caller_exit: true)
    parent = self()

    spawn_link(fn ->
      send(parent, {:taken, pid |> ClaudeWrapper.Stream.stream("p") |> Enum.take(1)})
    end)

    sent_uuid()
    cli_says(pid, handle, %{type: "assistant", message: %{content: []}})
    assert_receive {:taken, [{:assistant, _}]}
    assert_interrupt_written()
  end
end
