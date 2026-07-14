defmodule ClaudeWrapper.RunnerTest do
  # Not async: one test overrides the :runner application env.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.Runner

  describe "impl/0" do
    test "defaults to Runner.Port" do
      assert Runner.impl() == ClaudeWrapper.Runner.Port
    end

    test "honors the :runner application env" do
      Application.put_env(:claude_wrapper, :runner, ClaudeWrapper.Runner.Forcola)
      on_exit(fn -> Application.delete_env(:claude_wrapper, :runner) end)

      assert Runner.impl() == ClaudeWrapper.Runner.Forcola
    end
  end

  describe "Runner.Port.run/4" do
    alias ClaudeWrapper.Runner.Port

    test "returns stdout and exit code on completion" do
      assert {:ok, {"hi\n", 0}} = Port.run("echo", ["hi"], [], nil)
    end

    test "surfaces a non-zero exit code" do
      assert {:ok, {_out, 5}} = Port.run("sh", ["-c", "exit 5"], [], nil)
    end

    test "a timeout returns {:error, :timeout}" do
      assert {:error, :timeout} = Port.run("sleep", ["10"], [], 200)
    end

    test "a missing binary returns a :binary_not_found signal (no-timeout path)" do
      assert {:error, {:binary_not_found, :enoent}} =
               Port.run("definitely-not-a-real-binary-xyz", [], [], nil)
    end

    test "a missing binary on the timeout path returns :binary_not_found (does not crash)" do
      # Regression (#200): the raise happens inside the linked Task, so it must
      # come back as a value rather than crashing this process.
      assert {:error, {:binary_not_found, :enoent}} =
               Port.run("definitely-not-a-real-binary-xyz", [], [], 1_000)
    end
  end

  describe "Runner.Port.stream_lines/4" do
    alias ClaudeWrapper.Runner.Port

    test "yields complete stdout lines" do
      lines =
        "printf"
        |> Port.stream_lines(["a\nb\nc\n"], [], nil)
        |> Enum.to_list()

      assert lines == ["a", "b", "c"]
    end

    test "reassembles a line longer than the port buffer instead of dropping it (#198)" do
      big = String.duplicate("A", 1_100_000)

      lines =
        "sh"
        |> Port.stream_lines(["-c", "head -c 1100000 /dev/zero | tr '\\0' A; echo"], [], nil)
        |> Enum.to_list()

      assert lines == [big]
    end

    test "a naturally-completing stream returns promptly, not after a 5s stall (#201)" do
      {micros, lines} =
        :timer.tc(fn ->
          "printf" |> Port.stream_lines(["a\nb\n"], [], nil) |> Enum.to_list()
        end)

      assert lines == ["a", "b"]

      assert micros < 2_000_000,
             "stream took #{div(micros, 1000)}ms (the 5s close stall regressed)"
    end

    test "an idle producer halts at the idle timeout instead of hanging (#217)" do
      {micros, lines} =
        :timer.tc(fn ->
          "sh"
          |> Port.stream_lines(["-c", "echo first; sleep 10"], [], 200)
          |> Enum.to_list()
        end)

      assert lines == ["first"]
      # halts on the 200ms idle bound, not the 10s sleep
      assert micros < 2_000_000
    end

    test "propagates :env to the spawned process (#217)" do
      lines =
        "sh"
        |> Port.stream_lines(["-c", "echo $CW_TEST"], [env: [{~c"CW_TEST", ~c"hello217"}]], nil)
        |> Enum.to_list()

      assert lines == ["hello217"]
    end

    test "propagates :cd to the spawned process (#217)" do
      # A unique leaf dir: `pwd` may resolve a parent symlink (/var -> /private/var
      # on macOS), so compare on the unique basename rather than the full path.
      dir = Path.join(System.tmp_dir!(), "cw_cd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(dir)
      on_exit(fn -> File.rm_rf(dir) end)

      lines =
        "sh"
        |> Port.stream_lines(["-c", "pwd"], [cd: dir], nil)
        |> Enum.to_list()

      assert [pwd] = lines
      assert String.ends_with?(pwd, Path.basename(dir))
    end
  end
end
