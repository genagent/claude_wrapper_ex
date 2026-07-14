defmodule ClaudeWrapper.RunnerConfigTest do
  # Covers the runner/config-correctness fixes: config.timeout enforcement on the
  # subcommand path (Config.exec/2, #204), raw/2 routing through the configured
  # Runner (#204), and Query.stream/2's terminal truncation event (#209).
  #
  # async: false -- the raw/2 and stream tests swap the global `:runner`.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, Error, Query}

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
  end
end
