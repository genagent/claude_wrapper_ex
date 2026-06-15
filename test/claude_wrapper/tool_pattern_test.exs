defmodule ClaudeWrapper.ToolPatternTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.ToolPattern

  doctest ToolPattern

  describe "constructors" do
    test "tool/1 strips surrounding whitespace" do
      assert ToolPattern.tool("  Bash  ") |> ToolPattern.to_string() == "Bash"
    end

    test "tool_with_args/2 renders Name(args)" do
      pattern = ToolPattern.tool_with_args("Bash", "git log:*")
      assert ToolPattern.to_string(pattern) == "Bash(git log:*)"
    end

    test "tool_with_args/2 trims the name but not the args" do
      pattern = ToolPattern.tool_with_args("  Bash  ", "git log:*")
      assert ToolPattern.to_string(pattern) == "Bash(git log:*)"
    end

    test "all/1 wildcards the args" do
      assert ToolPattern.all("Write") |> ToolPattern.to_string() == "Write(*)"
    end

    test "mcp/2 renders mcp__server__tool" do
      assert ToolPattern.mcp("srv", "do_it") |> ToolPattern.to_string() == "mcp__srv__do_it"
      assert ToolPattern.mcp("srv", "*") |> ToolPattern.to_string() == "mcp__srv__*"
    end

    test "constructors build a %ToolPattern{} struct holding the canonical string" do
      assert %ToolPattern{value: "Read"} = ToolPattern.tool("Read")
    end
  end

  describe "parse/1 valid input" do
    test "accepts a bare name" do
      assert {:ok, %ToolPattern{value: "Bash"}} = ToolPattern.parse("Bash")
    end

    test "accepts a name with args" do
      assert {:ok, %ToolPattern{value: "Bash(git log:*)"}} = ToolPattern.parse("Bash(git log:*)")
    end

    test "accepts an mcp pattern" do
      assert {:ok, %ToolPattern{value: "mcp__srv__*"}} = ToolPattern.parse("mcp__srv__*")
    end

    test "trims surrounding whitespace" do
      assert {:ok, %ToolPattern{value: "Read"}} = ToolPattern.parse("  Read  ")
    end

    test "round-trips a constructed pattern" do
      built = ToolPattern.tool_with_args("Bash", "git log:*")
      assert {:ok, parsed} = ToolPattern.parse(ToolPattern.to_string(built))
      assert parsed == built
    end
  end

  describe "parse/1 errors" do
    test "rejects empty input" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_tool_pattern, reason: :empty}} =
               ToolPattern.parse("")

      assert {:error, %ClaudeWrapper.Error{kind: :invalid_tool_pattern, reason: :empty}} =
               ToolPattern.parse("   ")
    end

    test "rejects unbalanced parens" do
      assert {:error,
              %ClaudeWrapper.Error{
                kind: :invalid_tool_pattern,
                reason: {:unbalanced_parens, "Bash(git log"}
              }} = ToolPattern.parse("Bash(git log")

      assert {:error,
              %ClaudeWrapper.Error{
                kind: :invalid_tool_pattern,
                reason: {:unbalanced_parens, "Bashgit log)"}
              }} = ToolPattern.parse("Bashgit log)")

      assert {:error,
              %ClaudeWrapper.Error{
                kind: :invalid_tool_pattern,
                reason: {:unbalanced_parens, "Bash((nested))"}
              }} = ToolPattern.parse("Bash((nested))")
    end

    test "rejects a missing name before the args" do
      assert {:error, %ClaudeWrapper.Error{kind: :invalid_tool_pattern, reason: :missing_name}} =
               ToolPattern.parse("(args)")
    end

    test "rejects a comma" do
      assert {:error,
              %ClaudeWrapper.Error{
                kind: :invalid_tool_pattern,
                reason: {:illegal_char, "Bash,Read"}
              }} = ToolPattern.parse("Bash,Read")
    end

    test "rejects a mid-string control char" do
      # Leading/trailing whitespace is trimmed, so the control char must
      # be in the interior to trip the check.
      assert {:error,
              %ClaudeWrapper.Error{
                kind: :invalid_tool_pattern,
                reason: {:illegal_char, "Ba\nsh"}
              }} = ToolPattern.parse("Ba\nsh")
    end
  end

  describe "to_string/1 and String.Chars" do
    test "to_string/1 returns the rendered value" do
      assert ToolPattern.to_string(ToolPattern.tool("Read")) == "Read"
    end

    test "String.Chars matches to_string/1" do
      pattern = ToolPattern.tool_with_args("Bash", "ls")
      assert Kernel.to_string(pattern) == ToolPattern.to_string(pattern)
    end

    test "is usable in string interpolation" do
      assert "#{ToolPattern.mcp("srv", "*")}" == "mcp__srv__*"
    end
  end
end
