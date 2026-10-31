defmodule ClaudeWrapper.DuplexSession.CorrelationTest.WireAdapter do
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

defmodule ClaudeWrapper.DuplexSession.CorrelationTest do
  @moduledoc "A send/3 completes on its own prompt's result (#321)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Result}
  alias ClaudeWrapper.DuplexSession.CorrelationTest.WireAdapter

  defp start do
    {:ok, pid} =
      DuplexSession.start_link(
        config: Config.new(binary: "unused"),
        adapter: WireAdapter,
        adapter_opts: [test_pid: self()]
      )

    assert_receive {:wire_open, handle}
    :ok = DuplexSession.subscribe(pid)
    {pid, handle}
  end

  defp cli_says(pid, handle, msg) do
    send(pid, {handle, {:data, Jason.encode!(msg) <> "\n"}})
    :sys.get_state(pid)
  end

  # Send a prompt from another process; return the uuid it was stamped with.
  defp send_async(pid, prompt) do
    parent = self()
    spawn_link(fn -> send(parent, {:sent, prompt, DuplexSession.send(pid, prompt)}) end)
    assert_receive {:wire_out, %{"type" => "user", "uuid" => uuid} = msg}
    assert msg["message"]["content"] == prompt
    uuid
  end

  defp result(text, extra) do
    Map.merge(
      %{type: "result", subtype: "success", is_error: false, session_id: "s", result: text},
      extra
    )
  end

  test "each prompt carries a distinct v4 uuid" do
    {pid, handle} = start()
    first = send_async(pid, "one")
    assert first =~ ~r/\A[0-9a-f]{8}-[0-9a-f]{4}-4[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}\z/
    cli_says(pid, handle, result("r1", %{user_message_uuids: [first]}))
    assert_receive {:sent, "one", {:ok, _}}

    refute send_async(pid, "two") == first
  end

  test "a result for another prompt does not complete the pending send" do
    {pid, handle} = start()
    uuid = send_async(pid, "second prompt")

    # The CLI's own turn after a background task finishes.
    cli_says(pid, handle, result("BACKGROUND-FINISHED-REPLY", %{user_message_uuids: ["other"]}))
    assert_receive {:claude, {:unsolicited_result, %Result{result: "BACKGROUND-FINISHED-REPLY"}}}
    refute_received {:sent, _, _}

    cli_says(pid, handle, result("SECOND-PROMPT-REPLY", %{user_message_uuids: [uuid]}))
    assert_receive {:sent, "second prompt", {:ok, %Result{result: "SECOND-PROMPT-REPLY"}}}
    assert_receive {:claude, {:result, %Result{result: "SECOND-PROMPT-REPLY"}}}
  end

  test "the singular user_message_uuid also correlates" do
    {pid, handle} = start()
    uuid = send_async(pid, "p")

    cli_says(pid, handle, result("no", %{user_message_uuid: "other"}))
    refute_received {:sent, _, _}

    cli_says(pid, handle, result("yes", %{user_message_uuid: uuid}))
    assert_receive {:sent, "p", {:ok, %Result{result: "yes"}}}
  end

  test "a result with no pending send is unsolicited" do
    {pid, handle} = start()
    cli_says(pid, handle, result("idle", %{user_message_uuids: ["x"]}))
    assert_receive {:claude, {:unsolicited_result, %Result{result: "idle"}}}
    refute_received {:claude, {:result, _}}
  end

  test "a result without correlation fields completes the pending send (older CLIs)" do
    {pid, handle} = start()
    send_async(pid, "p")
    cli_says(pid, handle, result("legacy", %{}))
    assert_receive {:sent, "p", {:ok, %Result{result: "legacy"}}}
  end

  test "ClaudeWrapper.Stream ends on its own result and passes unsolicited ones through" do
    {pid, handle} = start()
    parent = self()

    spawn_link(fn ->
      send(parent, {:events, pid |> ClaudeWrapper.Stream.stream("p") |> Enum.to_list()})
    end)

    assert_receive {:wire_out, %{"type" => "user", "uuid" => uuid}}
    cli_says(pid, handle, result("bg", %{user_message_uuids: ["other"]}))
    cli_says(pid, handle, result("mine", %{user_message_uuids: [uuid]}))

    assert_receive {:events, events}
    assert Enum.any?(events, &match?({:unsolicited_result, %Result{result: "bg"}}, &1))
    assert {:result, %Result{result: "mine"}} = List.last(events)
  end
end
