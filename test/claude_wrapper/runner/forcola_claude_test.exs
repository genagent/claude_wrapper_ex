defmodule ClaudeWrapper.Runner.ForcolaClaudeTest do
  @moduledoc """
  Leak-freedom of `ClaudeWrapper.Runner.Forcola` /
  `ClaudeWrapper.DuplexSession.Adapter.Forcola` against the real `claude`
  binary: on a timeout, an early halt, or session teardown the whole
  `claude` process group (the CLI and any stdio MCP server it spawned) is
  killed, where the default `Port` path would leak it (#185).

  Runs the real CLI, so it is excluded by default:

      mix test --include integration test/claude_wrapper/runner/forcola_claude_test.exs

  Every spawned process is tagged with a unique marker in its argv, and
  cleanup only ever signals processes matching that marker -- never a
  broad `claude` kill, which would hit an unrelated session.
  """
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, DuplexSession, Runner}
  alias ClaudeWrapper.DuplexSession.Adapter.Forcola, as: ForcolaAdapter

  @moduletag :integration
  @moduletag :forcola

  setup_all do
    unless System.find_executable("claude") do
      raise "claude binary not found on PATH; required for the forcola/claude integration tests"
    end

    :ok
  end

  describe "one-shot (Runner.Forcola)" do
    test "a timeout kills the claude process group (no leak)" do
      marker = new_marker("ONESHOT")
      on_exit(fn -> hard_cleanup(marker) end)

      task = watch(marker)

      assert {:error, :timeout} =
               Runner.Forcola.run(
                 "claude",
                 ["-p", "#{marker} think for a long time, then reply OK", "--max-turns", "1"],
                 [stderr_to_stdout: true],
                 2_500
               )

      seen = Task.await(task, 6_000)
      assert seen != [], "expected to observe the claude process while it ran"

      # Forcola confirms the group is dead before run/4 returns.
      assert await_gone(marker), "claude leaked after timeout: #{inspect(find_pids(marker))}"
    end
  end

  describe "one-shot + stdio MCP server (Runner.Forcola)" do
    setup do
      unless System.find_executable("python3") do
        raise "python3 not found; required for the MCP-child reaping test"
      end

      rid = System.unique_integer([:positive])
      mcp_marker = "STRESSMCP_#{rid}"
      dir = Path.join(System.tmp_dir!(), "cw_forcola_mcp_#{rid}")
      File.mkdir_p!(dir)
      # Script path carries the marker, so pgrep -f finds the child.
      script = Path.join(dir, "#{mcp_marker}.py")
      File.write!(script, mcp_server_source())
      File.chmod!(script, 0o755)

      config = Path.join(dir, "mcp.json")

      File.write!(
        config,
        ~s({"mcpServers":{"stress":{"type":"stdio","command":"python3","args":["#{script}"]}}})
      )

      on_exit(fn ->
        hard_cleanup(mcp_marker)
        File.rm_rf(dir)
      end)

      {:ok, mcp_marker: mcp_marker, mcp_config: config}
    end

    test "a timeout reaps claude and its MCP server child together", ctx do
      claude_marker = new_marker("MCPCLA")
      on_exit(fn -> hard_cleanup(claude_marker) end)

      both = fn -> {find_pids(claude_marker), find_pids(ctx.mcp_marker)} end
      watcher = watch_pair(both)

      assert {:error, :timeout} =
               Runner.Forcola.run(
                 "claude",
                 [
                   "-p",
                   "#{claude_marker} reply OK",
                   "--mcp-config",
                   ctx.mcp_config,
                   "--max-turns",
                   "1"
                 ],
                 [stderr_to_stdout: true],
                 6_000
               )

      {claude_seen, mcp_seen} = Task.await(watcher, 10_000)
      assert claude_seen != [], "expected to observe claude while it ran"
      assert mcp_seen != [], "expected claude to spawn the stdio MCP server child"

      assert await_gone(claude_marker), "claude leaked: #{inspect(find_pids(claude_marker))}"
      assert await_gone(ctx.mcp_marker), "MCP child leaked: #{inspect(find_pids(ctx.mcp_marker))}"
    end
  end

  describe "duplex (Adapter.Forcola)" do
    test "closing the session reaps the claude process" do
      marker = new_marker("DUPLEX")
      on_exit(fn -> hard_cleanup(marker) end)

      {:ok, pid} =
        DuplexSession.start_link(
          config: Config.new(binary: "claude"),
          adapter: ForcolaAdapter,
          extra_args: ["--append-system-prompt", marker]
        )

      assert await_present(marker), "claude did not spawn for the duplex session"

      :ok = DuplexSession.stop(pid)

      assert await_gone(marker),
             "claude leaked after session close: #{inspect(find_pids(marker))}"
    end
  end

  describe "concurrency (Runner.Forcola)" do
    test "many concurrent timeouts leave no leaked processes" do
      marker = new_marker("CHURN")
      on_exit(fn -> hard_cleanup(marker) end)

      n = 8

      results =
        1..n
        |> Enum.map(fn i ->
          Task.async(fn ->
            Runner.Forcola.run(
              "claude",
              ["-p", "#{marker}_#{i} wait then OK", "--max-turns", "1"],
              [stderr_to_stdout: true],
              2_000
            )
          end)
        end)
        |> Task.await_many(30_000)

      assert Enum.all?(results, &match?({:error, :timeout}, &1))
      assert await_gone(marker), "leaked after churn: #{inspect(find_pids(marker))}"
    end
  end

  # --- helpers ---------------------------------------------------------

  defp new_marker(tag), do: "STRESS#{tag}_#{System.unique_integer([:positive])}"

  # OS pids whose argv contains `marker`.
  defp find_pids(marker) do
    case System.cmd("pgrep", ["-f", marker], stderr_to_stdout: true) do
      {out, 0} -> out |> String.split("\n", trim: true)
      _ -> []
    end
  end

  # Watch for the marker to appear while a run is in flight; returns the
  # pids seen (or [] if never observed within the window).
  defp watch(marker), do: Task.async(fn -> poll_until_seen(marker, 60) end)

  defp poll_until_seen(_marker, 0), do: []

  defp poll_until_seen(marker, tries) do
    case find_pids(marker) do
      [] ->
        Process.sleep(80)
        poll_until_seen(marker, tries - 1)

      pids ->
        pids
    end
  end

  # Accumulate the union of pids seen from a {a, b} sampler over the run.
  defp watch_pair(sampler) do
    Task.async(fn ->
      Enum.reduce(1..80, {[], []}, fn _, {a, b} ->
        Process.sleep(80)
        {sa, sb} = sampler.()
        {Enum.uniq(a ++ sa), Enum.uniq(b ++ sb)}
      end)
    end)
  end

  defp await_present(marker, tries \\ 60) do
    Enum.any?(1..tries, fn _ ->
      if find_pids(marker) == [],
        do:
          (
            Process.sleep(100)
            false
          ),
        else: true
    end)
  end

  defp await_gone(marker, tries \\ 100) do
    Enum.any?(1..tries, fn _ ->
      if find_pids(marker) == [],
        do: true,
        else:
          (
            Process.sleep(50)
            false
          )
    end)
  end

  # Marker-scoped SIGKILL: only touches processes whose argv matches the
  # test's unique marker, never an unrelated claude session.
  defp hard_cleanup(marker) do
    System.cmd("pkill", ["-9", "-f", marker], stderr_to_stdout: true)
    :ok
  end

  defp mcp_server_source do
    """
    #!/usr/bin/env python3
    import sys, json


    def send(o):
        sys.stdout.write(json.dumps(o) + "\\n")
        sys.stdout.flush()


    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            m = json.loads(line)
        except Exception:
            continue
        mid = m.get("id")
        method = m.get("method")
        if method == "initialize":
            send({"jsonrpc": "2.0", "id": mid, "result": {"protocolVersion": "2024-11-05",
                  "capabilities": {"tools": {}}, "serverInfo": {"name": "stress", "version": "0"}}})
        elif method == "tools/list":
            send({"jsonrpc": "2.0", "id": mid, "result": {"tools": []}})
        elif mid is not None:
            send({"jsonrpc": "2.0", "id": mid, "result": {}})
    """
  end
end
