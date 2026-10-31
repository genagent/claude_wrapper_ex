defmodule ClaudeWrapper.DuplexSession.AdapterPortBoundsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession}
  alias ClaudeWrapper.DuplexSession.{Adapter, TransportTerminal}

  @moduletag :tmp_dir

  defp fake(dir, body) do
    path = Path.join(dir, "fake_claude")
    File.write!(path, "#!/bin/sh\n" <> body)
    File.chmod!(path, 0o755)
    path
  end

  # Fakes that write something the test must observe wait for this file,
  # which go/1 creates once the test has subscribed.
  defp gate(dir), do: "while [ ! -f '#{Path.join(dir, "go")}' ]; do sleep 0.02; done\n"
  defp go(dir), do: File.touch!(Path.join(dir, "go"))

  # Register for the exit status, then release the fake, so a session that
  # fails fast cannot exit before the waiter is registered.
  defp exit_after_go(pid, dir) do
    task = Task.async(fn -> DuplexSession.wait_for_exit(pid, 5_000) end)
    wait_until(fn -> map_size(:sys.get_state(pid).exit_waiters) > 0 end)
    go(dir)
    Task.await(task)
  end

  defp wait_until(fun, attempts \\ 200) do
    cond do
      fun.() -> :ok
      attempts == 0 -> flunk("condition not met")
      true -> Process.sleep(5) && wait_until(fun, attempts - 1)
    end
  end

  defp start(dir, body, adapter_opts \\ []) do
    Process.flag(:trap_exit, true)

    {:ok, pid} =
      DuplexSession.start_link(
        config: Config.new(binary: fake(dir, body)),
        adapter: Adapter.Port,
        adapter_opts: adapter_opts,
        args_override: []
      )

    :ok = DuplexSession.subscribe(pid)
    pid
  end

  describe "line and output bounds (#311)" do
    test "an unterminated line over max_line_bytes ends the session", %{tmp_dir: dir} do
      pid =
        start(dir, gate(dir) <> "head -c 200000 /dev/zero | tr '\\\\0' a\nexec sleep 30\n",
          max_line_bytes: 65_536
        )

      assert {:failed, {:transport_error, {:output_limit, :line, 65_536}}} =
               exit_after_go(pid, dir)
    end

    test "a large line under the bound is delivered", %{tmp_dir: dir} do
      text = String.duplicate("x", 500_000)

      line =
        Jason.encode!(%{type: "assistant", message: %{content: [%{type: "text", text: text}]}})

      File.write!(Path.join(dir, "line.json"), line <> "\n")

      pid = start(dir, gate(dir) <> "cat '#{Path.join(dir, "line.json")}'\nexec cat >/dev/null\n")
      go(dir)

      assert_receive {:claude,
                      {:assistant, %{"message" => %{"content" => [%{"text" => ^text}]}}}},
                     5_000

      assert DuplexSession.alive?(pid)
      DuplexSession.close(pid)
    end

    test "total output over max_output_bytes ends the session", %{tmp_dir: dir} do
      pid =
        start(
          dir,
          gate(dir) <>
            "i=0\nwhile [ $i -lt 200 ]; do echo '{\"type\":\"noise\",\"pad\":\"0123456789\"}'; i=$((i+1)); done\nexec sleep 30\n",
          max_output_bytes: 4_096
        )

      assert {:failed, {:transport_error, {:output_limit, :output, 4_096}}} =
               exit_after_go(pid, dir)
    end

    test "an invalid bound raises at start", %{tmp_dir: dir} do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               DuplexSession.start_link(
                 config: Config.new(binary: fake(dir, "exec cat\n")),
                 adapter: Adapter.Port,
                 adapter_opts: [max_line_bytes: 0],
                 args_override: []
               )
    end
  end

  describe "stderr capture (#311)" do
    test "shutdown/1 returns the stderr tail, which never reaches the VM", %{tmp_dir: dir} do
      pid = start(dir, "echo STDERR-MARKER >&2\nexec cat >/dev/null\n")
      Process.sleep(200)

      assert {:ok, %TransportTerminal{evidence: :closed, stderr: "STDERR-MARKER\n"}} =
               DuplexSession.shutdown(pid)
    end

    test "a child that exits reports its tail and removes the file", %{tmp_dir: dir} do
      pid = start(dir, gate(dir) <> "echo exiting-3 >&2\nexit 3\n")
      go(dir)

      assert_receive {:claude,
                      {:transport_terminal,
                       %TransportTerminal{evidence: {:exit_status, 3}, stderr: "exiting-3\n"}}},
                     5_000

      assert_receive {:EXIT, ^pid, :normal}, 5_000
    end

    test "the tail keeps the last stderr_capture_bytes", %{tmp_dir: dir} do
      pid =
        start(dir, "printf 'aaaaabbbbb' >&2\nexec cat >/dev/null\n", stderr_capture_bytes: 5)

      Process.sleep(200)
      assert {:ok, %TransportTerminal{stderr: "bbbbb"}} = DuplexSession.shutdown(pid)
    end

    test "stderr_capture_bytes 0 discards stderr", %{tmp_dir: dir} do
      pid = start(dir, "echo gone >&2\nexec cat >/dev/null\n", stderr_capture_bytes: 0)
      Process.sleep(200)
      assert {:ok, %TransportTerminal{stderr: ""}} = DuplexSession.shutdown(pid)
    end
  end

  test "a missing binary fails start_link", %{tmp_dir: dir} do
    Process.flag(:trap_exit, true)

    assert {:error, {:binary_not_found, :enoent}} =
             DuplexSession.start_link(
               config: Config.new(binary: Path.join(dir, "missing")),
               adapter: Adapter.Port,
               args_override: []
             )
  end
end
