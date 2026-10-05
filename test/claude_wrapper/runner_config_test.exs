defmodule ClaudeWrapper.RunnerConfigTest do
  # Covers the runner/config-correctness fixes: config.timeout enforcement on the
  # subcommand path (Config.exec/2, #204), raw/2 routing through the configured
  # Runner (#204), and Query.stream/2's terminal truncation event (#209).
  #
  # async: false -- the raw/2 and stream tests swap the global `:runner`.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, Error, Query, Result}

  defmodule TimeoutRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:error, :timeout}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  defmodule OkRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"out\n", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  # Leading noise + a decoy system/init line before the terminal result line, to
  # exercise extract_json's noise-skipping and last-JSON-line selection (#232).
  defmodule NoisyJsonRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout) do
      stdout =
        [
          "[warning] npm notice",
          Jason.encode!(%{"type" => "system", "subtype" => "init", "session_id" => "s1"}),
          Jason.encode!(%{
            "type" => "result",
            "subtype" => "success",
            "result" => "ok",
            "num_turns" => 1
          })
        ]
        |> Enum.join("\n")

      {:ok, {stdout, 0}}
    end

    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  defmodule NoJsonRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"warning: something\nstill not json", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  defmodule EmptyRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  defmodule IoErrorRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:error, :closed}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout), do: []
  end

  defmodule ResultRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout) do
      [
        ~s({"type":"system","subtype":"init","session_id":"s1"}),
        ~s({"type":"assistant","message":{}}),
        ~s({"type":"result","result":"done"})
      ]
    end
  end

  defmodule TruncatedRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, _timeout) do
      # no terminal "result" event -> a stalled/truncated run
      [
        ~s({"type":"system","subtype":"init","session_id":"s1"}),
        ~s({"type":"assistant","message":{}})
      ]
    end
  end

  defmodule DeadlineRunner do
    @behaviour ClaudeWrapper.Runner
    @impl true
    def run(_binary, _args, _opts, _timeout), do: {:ok, {"", 0}}
    @impl true
    def stream_lines(_binary, _args, _opts, timeout) do
      send(self(), {:stream_timeout, timeout})
      [~s({"type":"result","result":"done"})]
    end
  end

  setup do
    prev = Application.get_env(:claude_wrapper, :runner)

    on_exit(fn ->
      if prev,
        do: Application.put_env(:claude_wrapper, :runner, prev),
        else: Application.delete_env(:claude_wrapper, :runner)
    end)

    :ok
  end

  describe "Config.exec/2 (subcommand timeout, #204)" do
    test "returns {output, code} for a command that completes within the timeout" do
      config = Config.new(binary: System.find_executable("printf"), timeout: 5_000)
      assert {"hello", 0} = Config.exec(config, ["hello"])
    end

    test "bounds a slow command by config.timeout and synthesizes a timeout result" do
      config = Config.new(binary: System.find_executable("sleep"), timeout: 50)
      assert {message, 124} = Config.exec(config, ["2"])
      assert message =~ "timed out"
    end
  end

  describe "raw/2 (routes through the configured Runner, #204)" do
    test "maps a runner timeout to a typed Error (no longer bypasses the runner)" do
      Application.put_env(:claude_wrapper, :runner, TimeoutRunner)
      assert {:error, %Error{kind: :timeout}} = ClaudeWrapper.raw(["config", "list"])
    end

    test "trims a successful runner result" do
      Application.put_env(:claude_wrapper, :runner, OkRunner)
      assert {:ok, "out"} = ClaudeWrapper.raw(["config", "list"])
    end
  end

  describe "Query.stream/2 truncation signal (#209)" do
    defp stream_events(runner) do
      Application.put_env(:claude_wrapper, :runner, runner)
      "hi" |> Query.new() |> Query.stream(Config.new()) |> Enum.to_list()
    end

    test "a clean run (ending with a result event) emits no truncation event" do
      events = stream_events(ResultRunner)

      assert Enum.any?(events, &(&1.type == "result"))
      refute Enum.any?(events, &(&1.type == "error" and &1.data["error"] == "stream_truncated"))
    end

    test "a truncated run (no result event) ends with a terminal truncation error event" do
      events = stream_events(TruncatedRunner)
      last = List.last(events)

      assert last.type == "error"
      assert last.data["error"] == "stream_truncated"
    end

    test "the public streaming API passes a finite timeout to the runner" do
      Application.put_env(:claude_wrapper, :runner, DeadlineRunner)

      assert [%ClaudeWrapper.StreamEvent{type: "result"}] =
               ClaudeWrapper.stream("hi", timeout: 500) |> Enum.to_list()

      assert_receive {:stream_timeout, 500}
    end

    test "the default runner truncates a continuously writing stream at the whole-run deadline" do
      Application.put_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Port)
      script = Path.join(System.tmp_dir!(), "cw_deadline_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(script) end)

      File.write!(script, """
      #!/bin/sh
      i=0
      while [ "$i" -lt 30 ]; do
        printf '%s\\n' '{"type":"assistant","message":{}}' 2>/dev/null || exit 0
        i=$((i + 1))
        sleep 0.05
      done
      printf '%s\\n' '{"type":"result","result":"done"}'
      """)

      File.chmod!(script, 0o755)

      events = ClaudeWrapper.stream("hi", binary: script, timeout: 500) |> Enum.to_list()

      assert Enum.any?(events, &(&1.type == "assistant"))
      refute Enum.any?(events, &(&1.type == "result"))
      assert List.last(events).data["error"] == "stream_truncated"
    end
  end

  describe "Query.execute/2 offline via Runner override (#232)" do
    defp execute(runner) do
      Application.put_env(:claude_wrapper, :runner, runner)
      "hi" |> Query.new() |> Query.execute(Config.new())
    end

    test "skips leading noise and selects the last JSON line" do
      # proves extract_json both skips the warning line AND picks the terminal
      # result over the earlier system/init decoy.
      assert {:ok, %Result{result: "ok", num_turns: 1}} = execute(NoisyJsonRunner)
    end

    test "maps non-JSON stdout to an Error.json" do
      assert {:error, %Error{kind: :json}} = execute(NoJsonRunner)
    end

    test "maps empty stdout to an Error.json" do
      assert {:error, %Error{kind: :json}} = execute(EmptyRunner)
    end

    test "maps a runner timeout to Error.timeout" do
      assert {:error, %Error{kind: :timeout}} = execute(TimeoutRunner)
    end

    test "maps a generic runner error to Error.io" do
      assert {:error, %Error{kind: :io}} = execute(IoErrorRunner)
    end
  end
end
