defmodule ClaudeWrapper.Runner.ForcolaTest do
  use ExUnit.Case, async: true

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
  end

  defp read_trimmed(path) do
    case File.read(path) do
      {:ok, ""} -> nil
      {:ok, contents} -> String.trim(contents)
      _ -> nil
    end
  end

  defp wait_for(fun, tries \\ 50) do
    case fun.() do
      nil when tries > 0 ->
        Process.sleep(20)
        wait_for(fun, tries - 1)

      value ->
        value
    end
  end

  defp eventually(fun, tries \\ 50) do
    cond do
      fun.() -> true
      tries > 0 -> Process.sleep(20) && eventually(fun, tries - 1)
      true -> false
    end
  end
end
