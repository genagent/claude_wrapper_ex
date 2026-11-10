defmodule ClaudeWrapper.StreamBoundsTest do
  @moduledoc "Query.stream/2 line bound, final unterminated line, and backpressure (#312)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Error, Query, Runner, StreamEvent}

  @moduletag :tmp_dir

  defp fake(dir, body) do
    path = Path.join(dir, "fake_claude")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  defp stream(dir, body, runner, opts \\ []) do
    config = Config.new([binary: fake(dir, body), runner: runner, timeout: 10_000] ++ opts)
    Query.new("p") |> Query.stream(config) |> Enum.to_list()
  end

  @init ~s({"type":"system","subtype":"init","session_id":"s"})
  @result ~s({"type":"result","subtype":"success","is_error":false,"result":"done","session_id":"s"})

  for runner <- [Runner.Port, Runner.Forcola] do
    describe inspect(runner) do
      if runner == Runner.Forcola, do: @describetag(:forcola)

      test "a line over max_line_bytes ends the stream with a line_limit event", %{tmp_dir: dir} do
        marker = Path.join(dir, "after")

        events =
          stream(
            dir,
            "echo '#{@init}'\nhead -c 200000 /dev/zero | tr '\\0' a\necho\necho '#{@result}'\nsleep 1\ntouch '#{marker}'\n",
            unquote(runner),
            max_line_bytes: 65_536
          )

        assert [%StreamEvent{type: "system"}, last] = events

        assert %StreamEvent{type: "error", data: %{"error" => "line_limit", "limit" => 65_536}} =
                 last

        # Forcola kills the group, so the fake never finishes. Runner.Port
        # signals only the CLI pid, which a shell script defers while its
        # foreground child runs, so the marker is not checked there.
        if unquote(runner) == Runner.Forcola do
          Process.sleep(1_500)
          refute File.exists?(marker)
        end
      end

      test "an unterminated run of bytes over the bound ends the stream", %{tmp_dir: dir} do
        events =
          stream(
            dir,
            "head -c 200000 /dev/zero | tr '\\0' a\nexec sleep 30\n",
            unquote(runner),
            max_line_bytes: 65_536
          )

        assert [%StreamEvent{type: "error", data: %{"error" => "line_limit"}}] = events
      end

      test "idle_timeout_ms ends a stalled stream before the whole-run timeout", %{tmp_dir: dir} do
        started = System.monotonic_time(:millisecond)

        events =
          stream(dir, "echo '#{@init}'\nexec sleep 8\n", unquote(runner), idle_timeout_ms: 500)

        elapsed = System.monotonic_time(:millisecond) - started

        assert [
                 %StreamEvent{type: "system"},
                 %StreamEvent{type: "error", data: %{"error" => "stream_truncated"}}
               ] = events

        assert elapsed < 5_000
      end

      test "idle_timeout_ms does not end a stream that keeps writing", %{tmp_dir: dir} do
        tick = ~s({"type":"system","subtype":"tick","session_id":"s"})
        ticks = Enum.map_join(1..5, "", fn _ -> "sleep 0.3\necho '#{tick}'\n" end)

        events =
          stream(
            dir,
            "echo '#{@init}'\n" <> ticks <> "echo '#{@result}'\n",
            unquote(runner),
            idle_timeout_ms: 1_000
          )

        assert %StreamEvent{type: "result"} = List.last(events)
        assert length(events) == 7
      end

      test "a line under the bound is delivered whole", %{tmp_dir: dir} do
        text = String.duplicate("x", 300_000)

        line =
          Jason.encode!(%{type: "assistant", message: %{content: [%{type: "text", text: text}]}})

        File.write!(Path.join(dir, "line.json"), line <> "\n")

        events =
          stream(
            dir,
            "cat '#{Path.join(dir, "line.json")}'\necho '#{@result}'\n",
            unquote(runner)
          )

        assert [%StreamEvent{type: "assistant", raw: ^line}, %StreamEvent{type: "result"}] =
                 events
      end

      test "a final line with no trailing newline is emitted", %{tmp_dir: dir} do
        events = stream(dir, "echo '#{@init}'\nprintf '%s' '#{@result}'\n", unquote(runner))

        assert [%StreamEvent{type: "system"}, %StreamEvent{type: "result"}] = events
      end
    end
  end

  test "an invalid max_line_bytes raises" do
    assert_raise ArgumentError, fn -> Config.new(binary: "x", max_line_bytes: 0) end
  end

  test "idle_timeout_ms defaults to nil and rejects non-positive values" do
    assert Config.new(binary: "x").idle_timeout_ms == nil
    assert Config.new(binary: "x", idle_timeout_ms: 1_000).idle_timeout_ms == 1_000
    assert_raise ArgumentError, fn -> Config.new(binary: "x", idle_timeout_ms: 0) end
    assert_raise ArgumentError, fn -> Config.new(binary: "x", idle_timeout_ms: "1000") end
  end

  defmodule OptsRunner do
    @moduledoc false
    def stream_lines(_binary, _args, opts, timeout) do
      send(opts[:test_pid] || self(), {:stream_opts, opts, timeout})
      []
    end
  end

  test "a custom runner receives idle_timeout_ms in stream opts" do
    config = Config.new(binary: "x", runner: OptsRunner, timeout: 5_000, idle_timeout_ms: 750)
    Query.new("p") |> Query.stream(config) |> Enum.to_list()

    assert_received {:stream_opts, opts, 5_000}
    assert opts[:idle_timeout_ms] == 750

    Query.new("p") |> Query.stream(Config.new(binary: "x", runner: OptsRunner)) |> Enum.to_list()
    assert_received {:stream_opts, opts, nil}
    refute Keyword.has_key?(opts, :idle_timeout_ms)
  end

  test "ClaudeWrapper.stream/2 routes idle_timeout_ms and max_line_bytes to Config" do
    ClaudeWrapper.stream("p",
      binary: "x",
      runner: OptsRunner,
      idle_timeout_ms: 750,
      max_line_bytes: 2_048,
      release_env: :inherit
    )
    |> Enum.to_list()

    assert_received {:stream_opts, opts, nil}
    assert opts[:idle_timeout_ms] == 750
    assert opts[:max_line_bytes] == 2_048
  end

  @tag :forcola
  test "Runner.Forcola reads on demand: a stalled consumer holds the CLI back", %{tmp_dir: dir} do
    progress = Path.join(dir, "progress")

    # 20,000 lines of 2 KiB; the fake records how many it has written.
    body = """
    pad=$(head -c 2048 /dev/zero | tr '\\0' p)
    i=0
    while [ $i -lt 20000 ]; do
      echo "{\\"type\\":\\"noise\\",\\"pad\\":\\"$pad\\"}"
      i=$((i+1))
      if [ $((i % 100)) -eq 0 ]; then echo $i > '#{progress}.tmp'; mv '#{progress}.tmp' '#{progress}'; fi
    done
    echo '#{@result}'
    """

    config = Config.new(binary: fake(dir, body), runner: Runner.Forcola, timeout: 30_000)
    parent = self()

    # The consumer blocks inside the reducer after the first event, without
    # halting the stream.
    consumer =
      spawn(fn ->
        Query.new("p")
        |> Query.stream(config)
        |> Enum.each(fn _event ->
          send(parent, :got_one)
          receive do: (:never -> :ok)
        end)
      end)

    on_exit(fn -> Process.exit(consumer, :kill) end)

    assert_receive :got_one, 5_000
    Process.sleep(1_000)

    {:message_queue_len, queued} = Process.info(consumer, :message_queue_len)

    written =
      case File.read(progress) do
        {:ok, text} -> text |> String.trim() |> String.to_integer()
        {:error, :enoent} -> 0
      end

    # Eager forwarding put every line in the consumer's mailbox and let the
    # CLI write all 20,000 (40 MiB). On demand, about one 64 KiB credit
    # window is in flight, plus what the OS pipe holds.
    assert queued < 500
    assert written < 2_000
  end

  @tag :forcola
  test "observed execution on Runner.Forcola reports an over-limit line as :output_limit",
       %{tmp_dir: dir} do
    config =
      Config.new(
        binary: fake(dir, "head -c 200000 /dev/zero | tr '\\0' a\necho\n"),
        runner: Runner.Forcola,
        timeout: 10_000,
        max_line_bytes: 65_536
      )

    assert {:error, %Error{kind: :output_limit, reason: %{limit: {:line, :stdout, 65_536}}}} =
             Query.execute(Query.new("p"), config, session_observer: {self(), make_ref()})
  end
end
