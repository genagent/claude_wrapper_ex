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

    test "single-quotes every shell-significant character" do
      for c <- [
            "<",
            ">",
            "*",
            "?",
            "[",
            "]",
            "\t",
            ";",
            "|",
            "&",
            "$",
            "`",
            " ",
            "\"",
            "\\",
            "\n"
          ] do
        assert Command.shell_escape("x" <> c <> "y") == "'x" <> c <> "y'"
      end

      # the bare single quote is the one char needing the '\'' dance
      assert Command.shell_escape("'") == ~S(''\''')
    end
  end

  describe "shell_escape/1 /bin/sh round-trip (#217)" do
    test "an adversarial argv survives /bin/sh verbatim (no split, glob, or substitution)" do
      argv = [
        "--setting-sources",
        "",
        "--strict-mcp-config",
        "a b",
        "a>b",
        "glob_*.txt",
        "it's",
        "a;rm -rf x",
        "$HOME",
        "`id`"
      ]

      fmt = String.duplicate("%s\\n", length(argv))
      ["-c", shell_cmd] = Command.shell_cmd_args("printf", [fmt | argv])

      {out, 0} = System.cmd("/bin/sh", ["-c", shell_cmd])

      received = out |> String.split("\n", trim: false) |> Enum.take(length(argv))
      assert received == argv
    end
  end

  describe "shell_cmd_args/2 (#196)" do
    test "an empty arg (e.g. hermetic's --setting-sources \"\") stays a distinct token" do
      assert Command.shell_cmd_args("claude", ["--setting-sources", ""]) ==
               ["-c", "claude --setting-sources '' < /dev/null"]
    end
  end
end
