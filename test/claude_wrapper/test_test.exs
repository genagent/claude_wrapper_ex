defmodule ClaudeWrapper.TestTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{DuplexSession, Result}
  alias ClaudeWrapper.Test, as: CWTest

  # send/3 sets pending_turn as its handle_call returns; manual emits must
  # wait for that so the result routes back to the caller. (The canned
  # stub/2 path is race-free: it emits in reply to the send's command.)
  defp wait_for_turn(session, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 1_000

    cond do
      :sys.get_state(session).pending_turn != nil ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("turn never started")

      true ->
        Process.sleep(2)
        wait_for_turn(session, deadline)
    end
  end

  describe "start_session/1" do
    test "drives a full turn (deltas + result) with no binary or network" do
      {:ok, session, stub} = CWTest.start_session()
      DuplexSession.subscribe(session)

      task = Task.async(fn -> DuplexSession.send(session, "hi") end)
      wait_for_turn(session)

      CWTest.emit(stub, [CWTest.text_delta("Hel"), CWTest.text_delta("lo")])
      CWTest.emit_result(stub, result: "Hello", session_id: "s-1")

      assert {:ok, %Result{session_id: "s-1", result: "Hello"}} = Task.await(task)

      # The subscriber saw the streamed events and the terminal result.
      assert_received {:claude, {:stream_event, %{"type" => "stream_event"}}}
      assert_received {:claude, {:result, %Result{session_id: "s-1"}}}
    end

    test "a canned reply is emitted automatically on the next send/3" do
      {:ok, session, stub} = CWTest.start_session()

      CWTest.stub(stub, [
        CWTest.text_delta("Hi"),
        CWTest.result(result: "Hi", session_id: "canned")
      ])

      assert {:ok, %Result{session_id: "canned", result: "Hi"}} =
               DuplexSession.send(session, "anything")
    end

    test "the ClaudeWrapper.Stream layer works over a test session" do
      {:ok, session, stub} = CWTest.start_session()

      CWTest.stub(stub, [
        CWTest.text_delta("Hel"),
        CWTest.text_delta("lo"),
        CWTest.result(result: "Hello")
      ])

      assert session |> ClaudeWrapper.Stream.stream("hi") |> ClaudeWrapper.Stream.final_text() ==
               "Hello"
    end

    test "sessions are isolated: one stub's events never reach another" do
      {:ok, s1, stub1} = CWTest.start_session()
      {:ok, _s2, _stub2} = CWTest.start_session()
      DuplexSession.subscribe(s1)

      task = Task.async(fn -> DuplexSession.send(s1, "hi") end)
      wait_for_turn(s1)
      CWTest.emit_result(stub1, result: "one", session_id: "s1")

      assert {:ok, %Result{session_id: "s1"}} = Task.await(task)
    end
  end

  describe "exit_status/2" do
    test "simulates the subprocess exiting" do
      {:ok, session, stub} = CWTest.start_session()
      ref = DuplexSession.wait_for_exit(session, 0)
      assert ref == :running

      CWTest.exit_status(stub, 0)
      assert DuplexSession.wait_for_exit(session, 1_000) == :completed
    end
  end
end
