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
  end
end
