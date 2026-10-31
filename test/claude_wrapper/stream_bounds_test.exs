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
