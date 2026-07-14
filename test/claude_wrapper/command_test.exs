defmodule ClaudeWrapper.CommandTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Command

  describe "shell_escape/1 (#196)" do
    test "leaves strictly-safe tokens bare" do
      for safe <- ["--model", "sonnet", "/path/to/file.json", "issue-42", "a,b:c=d.5"] do
        assert Command.shell_escape(safe) == safe
      end
    end

    test "single-quotes shell metacharacters the old denylist missed" do
      assert Command.shell_escape("a>b") == "'a>b'"
      assert Command.shell_escape("glob_*.txt") == "'glob_*.txt'"
      assert Command.shell_escape("~/project") == "'~/project'"
      assert Command.shell_escape("a b") == "'a b'"
    end

    test "single-quotes the empty string so it survives word-splitting" do
      assert Command.shell_escape("") == "''"
    end

    test "escapes an embedded single quote" do
      assert Command.shell_escape("it's") == ~S('it'\''s')
    end
  end

  describe "shell_cmd_args/2 (#196)" do
    test "an empty arg (e.g. hermetic's --setting-sources \"\") stays a distinct token" do
      assert Command.shell_cmd_args("claude", ["--setting-sources", ""]) ==
               ["-c", "claude --setting-sources '' < /dev/null"]
    end
  end
end
