defmodule ClaudeWrapper.Runner.CollectorTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Runner.Collector

  # A fake native run: sends the given frames to the observer target the
  # way Forcola's :output_observer does, then returns `outcome`.
  defp frames(frames, outcome \\ :finished) do
    fn {pid, ref} ->
      Enum.each(frames, fn frame -> send(pid, {ref, frame}) end)
      outcome
    end
  end

  defp recorder do
    test = self()
    tag = make_ref()

    observer = fn line ->
      send(test, {tag, self(), line})
      :continue
    end

    {observer, tag}
  end

  defp observed(tag) do
    receive do
      {^tag, _pid, line} -> [line | observed(tag)]
    after
      0 -> []
    end
  end

  test "reassembles fragmented stdout frames into lines and never observes stderr" do
    {observer, tag} = recorder()
    init = ~s({"type":"system","subtype":"init","session_id":"native-session"})
    {a, rest} = String.split_at(init, 9)
    {b, c} = String.split_at(rest, 20)

    run =
      frames([
        {:stdout, a},
        {:stderr, "stderr line\n"},
        {:stdout, b},
        {:stdout, c <> "\nsecond\nthi"},
        {:stdout, "rd\n"}
      ])

    assert {:done, :finished, %{lines_dropped: 0}} = Collector.run(run, observer)
    assert observed(tag) == [init, "second", "third"]
  end

  test "the observer runs in the execution caller" do
    {observer, tag} = recorder()
    caller = self()
    assert {:done, _, _} = Collector.run(frames([{:stdout, "one\n"}]), observer)
    assert_received {^tag, ^caller, "one"}
  end

  test "an unterminated final line is observed" do
    {observer, tag} = recorder()
    assert {:done, _, _} = Collector.run(frames([{:stdout, "a\nb"}]), observer)
    assert observed(tag) == ["a", "b"]
  end

  test "lines over the bound are withheld and counted, later lines still observed" do
    {observer, tag} = recorder()

    run =
      frames([
        {:stdout, "short\n0123456"},
        {:stdout, "789AB\nok\n"},
        {:stdout, "exactly10!\n"},
        {:stdout, "tail-over-the-bound"}
      ])

    assert {:done, _, %{lines_dropped: 2}} = Collector.run(run, observer, max_line_bytes: 10)
    assert observed(tag) == ["short", "ok", "exactly10!"]
  end

  test "observer replacement and :observed are honored" do
    test = self()

    observer = fn line ->
      send(test, {:first, line})

      {:continue,
       fn later ->
         send(test, {:later, later})
         :observed
       end}
    end

    assert {:done, _, _} = Collector.run(frames([{:stdout, "1\n2\n3\n"}]), observer)
    assert_received {:first, "1"}
    assert_received {:later, "2"}
    refute_received {_, "3"}
  end

  test "helper death returns helper_down with lines seen so far and leaves no messages" do
    {observer, tag} = recorder()

    run = fn {pid, ref} ->
      send(pid, {ref, {:stdout, "before\npartial"}})
      exit(:boom)
    end

    assert {:helper_down, :boom, %{lines_dropped: 0}} = Collector.run(run, observer)
    assert observed(tag) == ["before"]
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "a raising native run is reported as helper death" do
    run = fn _target -> raise ArgumentError, "invalid option" end
    assert {:helper_down, {%ArgumentError{}, _stack}, _stats} = Collector.run(run, nil)
  end

  test "helper throws and exits retain bounded stdout and stderr" do
    for fail <- [fn -> throw(:thrown) end, fn -> exit(:exited) end] do
      run = fn {pid, ref} ->
        send(pid, {ref, {:stdout, "out"}})
        send(pid, {ref, {:stderr, "diagnostic"}})
        fail.()
      end

      assert {:helper_down, _, stats} = Collector.run(run, nil, max_output_bytes: 6)
      assert stats.stdout == "out"
      assert stats.stderr == "dia"
      assert stats.output_truncated == true
      assert {:messages, []} = Process.info(self(), :messages)
    end
  end

  test "observer raises, throws and exits drain the native run and preserve its outcome" do
    for {kind, reason, fail} <- [
          {:error, %RuntimeError{message: "observer failed"}, fn -> raise "observer failed" end},
          {:throw, :thrown, fn -> throw(:thrown) end},
          {:exit, :exited, fn -> exit(:exited) end}
        ] do
      test = self()

      run = fn {pid, ref} ->
        send(pid, {ref, {:stdout, "first\nsecond\n"}})
        send(pid, {ref, {:stderr, "tail"}})
        send(test, :native_finished)
        :native_outcome
      end

      observer = fn _ ->
        send(test, :observed)
        fail.()
      end

      assert {:done, :native_outcome, stats} = Collector.run(run, observer)
      assert stats.observer_error == {kind, reason}
      assert stats.stdout == "first\nsecond\n"
      assert stats.stderr == "tail"
      assert_received :native_finished
      assert_received :observed
      refute_received :observed
      assert {:messages, []} = Process.info(self(), :messages)
    end
  end

  test "observer failure on the unterminated tail is recorded after completion" do
    assert {:done, :finished, %{observer_error: {:throw, :tail}}} =
             Collector.run(frames([{:stdout, "tail"}]), fn _ -> throw(:tail) end)

    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "caller death ends the helper that owns the native run" do
    test = self()

    run = fn _target ->
      {:links, [watcher]} = Process.info(self(), :links)
      send(test, {:helper, self(), watcher})

      receive do
        :never -> :ok
      end
    end

    caller = spawn(fn -> Collector.run(run, nil) end)
    assert_receive {:helper, helper, watcher}, 1_000
    monitor = Process.monitor(helper)
    watcher_monitor = Process.monitor(watcher)
    Process.exit(caller, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^helper, {:caller_down, ^helper}}, 1_000
    assert_receive {:DOWN, ^watcher_monitor, :process, ^watcher, _reason}, 1_000
  end

  test "helper completion retires its watcher" do
    test = self()

    run = fn _target ->
      {:links, [watcher]} = Process.info(self(), :links)
      send(test, {:helper, self(), watcher})

      receive do
        :finish -> :finished
      end
    end

    spawn(fn -> send(test, {:outcome, Collector.run(run, nil)}) end)
    assert_receive {:helper, helper, watcher}, 1_000
    monitor = Process.monitor(watcher)
    send(helper, :finish)
    assert_receive {:outcome, {:done, :finished, _stats}}, 1_000
    assert_receive {:DOWN, ^monitor, :process, ^watcher, :killed}, 1_000
  end

  test "no private messages linger after completion" do
    run = frames([{:stdout, "x\n"}, {:stderr, "y"}], {:ok, :result})
    assert {:done, {:ok, :result}, _} = Collector.run(run, fn _ -> :continue end)
    assert {:messages, []} = Process.info(self(), :messages)
  end

  test "frames are delivered before the outcome even under a burst" do
    {observer, tag} = recorder()
    lines = for n <- 1..2_000, do: "line-#{n}"
    run = frames(Enum.map(lines, &{:stdout, &1 <> "\n"}))
    assert {:done, :finished, _} = Collector.run(run, observer)
    assert observed(tag) == lines
  end
end
