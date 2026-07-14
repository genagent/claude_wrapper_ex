defmodule ClaudeWrapper.StreamTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Result}
  alias ClaudeWrapper.Stream, as: CWStream

  # Same fake-claude trick as DuplexSessionTest: drive a DuplexSession
  # against `cat`, then inject NDJSON turn events via Port.command/2.
  # `cat` echoes the prompt the session writes on :send (a "user" event),
  # then echoes whatever the injector feeds.

  defp start_with_fake_claude do
    config = Config.new(binary: System.find_executable("cat"))
    {:ok, pid} = DuplexSession.start_link(config: config, args_override: [])
    pid
  end

  defp inject(pid, term) do
    state = :sys.get_state(pid)
    Port.command(state.port, [Jason.encode!(term), ?\n])
  end

  # Wait until the stream consumer has subscribed, then feed the turn's
  # events from this (separate) process so the consumer can pull them
  # while it blocks in the stream's receive loop. No sleeps.
  defp feed_turn(pid, events) do
    spawn(fn ->
      wait_for_subscriber(pid)
      Enum.each(events, &inject(pid, &1))
    end)
  end

  defp wait_for_subscriber(pid, deadline \\ nil) do
    deadline = deadline || System.monotonic_time(:millisecond) + 2_000

    cond do
      :sys.get_state(pid).subscribers != %{} ->
        :ok

      System.monotonic_time(:millisecond) > deadline ->
        flunk("no subscriber registered within 2s")

      true ->
        Process.sleep(2)
        wait_for_subscriber(pid, deadline)
    end
  end

  defp text_delta(text) do
    %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "text_delta", "text" => text}
      }
    }
  end

  defp thinking_delta(text) do
    %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_delta",
        "index" => 0,
        "delta" => %{"type" => "thinking_delta", "thinking" => text}
      }
    }
  end

  defp tool_use_start(id, name) do
    %{
      "type" => "stream_event",
      "event" => %{
        "type" => "content_block_start",
        "index" => 0,
        "content_block" => %{"type" => "tool_use", "id" => id, "name" => name}
      }
    }
  end

  defp result_event do
    %{"type" => "result", "subtype" => "success", "result" => "ok", "session_id" => "s-1"}
  end

  describe "stream/3 elements" do
    test "yields decoded events ending with the terminal {:result, _}" do
      pid = start_with_fake_claude()
      feed_turn(pid, [text_delta("Hi"), result_event()])

      events = pid |> CWStream.stream("say hi") |> Enum.to_list()

      # The terminal element is the parsed Result; the text delta we fed
      # arrives before it (same writer preserves order).
      assert {:result, %Result{}} = List.last(events)
      assert Enum.any?(events, &match?({:stream_event, _}, &1))
    end
  end

  describe "projections" do
    test "text_deltas/1 yields only the text delta strings, in order" do
      pid = start_with_fake_claude()
      feed_turn(pid, [text_delta("Hel"), text_delta("lo"), result_event()])

      assert pid |> CWStream.stream("hi") |> CWStream.text_deltas() |> Enum.to_list() ==
               ["Hel", "lo"]
    end

    test "thinking_deltas/1 yields only thinking deltas" do
      pid = start_with_fake_claude()

      feed_turn(pid, [thinking_delta("hmm"), text_delta("answer"), result_event()])

      assert pid |> CWStream.stream("hi") |> CWStream.thinking_deltas() |> Enum.to_list() ==
               ["hmm"]
    end

    test "tool_uses/1 yields %{id, name} per tool-use block start" do
      pid = start_with_fake_claude()

      feed_turn(pid, [tool_use_start("tu_1", "Read"), text_delta("x"), result_event()])

      assert pid |> CWStream.stream("hi") |> CWStream.tool_uses() |> Enum.to_list() ==
               [%{id: "tu_1", name: "Read"}]
    end
  end

  describe "terminals" do
    test "final_text/1 concatenates the text deltas" do
      pid = start_with_fake_claude()
      feed_turn(pid, [text_delta("Hel"), text_delta("lo"), result_event()])

      assert pid |> CWStream.stream("hi") |> CWStream.final_text() == "Hello"
    end

    test "final_result/1 returns the turn's Result" do
      pid = start_with_fake_claude()
      feed_turn(pid, [text_delta("x"), result_event()])

      assert %Result{session_id: "s-1"} =
               pid |> CWStream.stream("hi") |> CWStream.final_result()
    end

    test "collect/1 returns both the text and the result from one turn" do
      pid = start_with_fake_claude()
      feed_turn(pid, [text_delta("Hel"), text_delta("lo"), result_event()])

      assert %{text: "Hello", result: %Result{session_id: "s-1"}} =
               pid |> CWStream.stream("hi") |> CWStream.collect()
    end
  end

  describe "failure" do
    test "a turn-in-flight send surfaces a terminal {:error, _} (no hang)" do
      pid = start_with_fake_claude()

      # Occupy the session with a turn that never completes, so the
      # stream's own send hits :turn_in_flight.
      spawn(fn -> DuplexSession.send(pid, "occupy", 5_000) end)
      wait_for_subscriber_free(pid)

      events = pid |> CWStream.stream("second") |> Enum.to_list()

      # The concurrent "occupy" turn is driven through `cat`, which echoes its
      # user message; depending on scheduling that echo can land in this stream
      # before the rejection (a fake-harness artifact -- real claude does not
      # echo another turn's message into a new subscriber). What this test pins
      # is that the send is rejected *terminally*: Enum.to_list returned (no
      # hang) and turn_in_flight is the final event.
      assert {:error, %ClaudeWrapper.Error{kind: :turn_in_flight}} = List.last(events)
    end

    # The occupying turn registers a pending_turn but no subscriber; wait
    # for the pending turn to be in flight before the stream sends.
    defp wait_for_subscriber_free(pid, deadline \\ nil) do
      deadline = deadline || System.monotonic_time(:millisecond) + 2_000

      cond do
        :sys.get_state(pid).pending_turn != nil ->
          :ok

        System.monotonic_time(:millisecond) > deadline ->
          flunk("occupying turn never went in flight")

        true ->
          Process.sleep(2)
          wait_for_subscriber_free(pid, deadline)
      end
    end
  end
end
