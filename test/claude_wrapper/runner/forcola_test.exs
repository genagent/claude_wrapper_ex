defmodule ClaudeWrapper.Runner.ForcolaTest do
  use ExUnit.Case, async: true

  # Drives the real forcola shim; skipped when it is not resolvable.
  @moduletag :forcola

  alias ClaudeWrapper.Runner.Forcola

  # Whether an OS process is still alive (kill -0 succeeds).
  defp os_alive?(pid) do
    match?({_, 0}, System.cmd("kill", ["-0", pid], stderr_to_stdout: true))
  end

  describe "run/4" do
    test "returns stdout and a zero exit on success" do
      assert {:ok, {"hi\n", 0}} = Forcola.run("echo", ["hi"], [], 5_000)
    end

    test "a non-zero exit is a result, not an error" do
      assert {:ok, {_stdout, 7}} = Forcola.run("sh", ["-c", "exit 7"], [], 5_000)
    end

    test "merges stderr into stdout when stderr_to_stdout is set" do
      assert {:ok, {out, 0}} =
               Forcola.run(
                 "sh",
                 ["-c", "echo out; echo err 1>&2"],
                 [stderr_to_stdout: true],
                 5_000
               )

      assert out =~ "out"
      assert out =~ "err"
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Forcola.run("sleep", ["10"], [], 300)
    end

    test "a missing binary returns a spawn error" do
      assert {:error, {:spawn, _reason}} =
               Forcola.run("definitely-not-a-real-binary-xyz", [], [], 5_000)
    end

    @tag :forcola_kill
    test "kills the child's process group on timeout (closes #185)" do
      pidfile = Path.join(System.tmp_dir!(), "cw_forcola_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pidfile) end)

      # The child records its pid, then sleeps well past the timeout.
      assert {:error, :timeout} =
               Forcola.run("sh", ["-c", "echo $$ > #{pidfile}; sleep 30"], [], 500)

      # Forcola confirms the group is dead before run/4 returns, so the
      # recorded process must already be gone -- no leaked CLI.
      pid = pidfile |> File.read!() |> String.trim()
      refute os_alive?(pid), "expected pid #{pid} to be killed on timeout, but it is alive"
    end
  end

  describe "stream_lines/4" do
    test "yields complete stdout lines" do
      lines =
        "printf"
        |> Forcola.stream_lines(["a\nb\nc\n"], [], nil)
        |> Enum.to_list()

      assert lines == ["a", "b", "c"]
    end

    test "halting early does not hang and kills the producer" do
      pidfile = Path.join(System.tmp_dir!(), "cw_forcola_s_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pidfile) end)

      # Emit one line, record the pid, then block. Taking a single line
      # halts the stream; the group must be killed so this returns fast.
      first =
        "sh"
        |> Forcola.stream_lines(["-c", "echo $$ > #{pidfile}; printf x\\\\n; sleep 30"], [], nil)
        |> Enum.take(1)

      assert first == ["x"]

      # Give the group-kill-on-halt a moment to complete, then confirm.
      pid = wait_for(fn -> read_trimmed(pidfile) end)
      assert eventually(fn -> not os_alive?(pid) end)
    end

    test "a continuously writing producer hits the whole-run timeout and is reaped" do
      pidfile = Path.join(System.tmp_dir!(), "cw_forcola_d_#{System.unique_integer([:positive])}")
      on_exit(fn -> File.rm(pidfile) end)

      script =
        "echo $$ > #{pidfile}; i=0; " <>
          "while [ \"$i\" -lt 40 ]; do printf 'tick\\n'; i=$((i + 1)); sleep 0.05; done; " <>
          "printf 'done\\n'"

      lines = Forcola.stream_lines("sh", ["-c", script], [], 500) |> Enum.to_list()

      assert "tick" in lines
      refute "done" in lines

      pid = wait_for(fn -> read_trimmed(pidfile) end)
      assert eventually(fn -> not os_alive?(pid) end)
    end
  end

  # Regression for a pre-0.3.4 forcola hang: `Forcola.run/2` and
  # `Forcola.Stream.lines/2` used to leave the child's stdin open and
  # unfed after spawn, so a child that reads stdin (as `claude -p` can,
  # for piped context) blocked until the timeout below instead of exiting
  # normally. forcola >= 0.3.4 closes stdin right after spawn; these
  # assert the child sees EOF promptly rather than riding out the timeout.
  describe "stdin is closed after spawn" do
    test "run/4: a child that reads stdin to EOF exits promptly" do
      start = System.monotonic_time(:millisecond)
      assert {:ok, {"", 0}} = Forcola.run("cat", [], [], 5_000)
      elapsed = System.monotonic_time(:millisecond) - start

      assert elapsed < 2_000, "expected stdin to be closed promptly, took #{elapsed}ms"
    end

    test "stream_lines/4: a child that reads stdin to EOF before emitting output does not hang" do
      start = System.monotonic_time(:millisecond)

      lines =
        "sh"
        |> Forcola.stream_lines(["-c", "cat > /dev/null; printf 'done\\n'"], [], 5_000)
        |> Enum.to_list()

      elapsed = System.monotonic_time(:millisecond) - start

      assert lines == ["done"]
      assert elapsed < 2_000, "expected stdin to be closed promptly, took #{elapsed}ms"
    end
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, ""} -> nil
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  # Generous budgets: after an early halt the group-kill runs
  # asynchronously (task shutdown -> port close -> shim SIGTERM ->
  # confirm), which can lag under full-suite load.
  defp wait_for(fun, tries \\ 300) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end

  defp eventually(fun, tries \\ 300) do
    cond do
      fun.() -> true
      tries > 0 -> Process.sleep(20) && eventually(fun, tries - 1)
      true -> false
    end
  end
end
