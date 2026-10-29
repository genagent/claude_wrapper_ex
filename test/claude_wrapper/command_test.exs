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

      {out, 0} =
        System.cmd(
          "/bin/sh",
          Command.launcher_args(System.find_executable("printf"), [fmt | argv])
        )

      received = out |> String.split("\n", trim: false) |> Enum.take(length(argv))
      assert received == argv
    end
  end

  describe "launcher_args/2 (#196, #305)" do
    test "passes the binary and each argument as positional parameters" do
      assert Command.launcher_args("claude", ["--setting-sources", ""]) ==
               [
                 "-c",
                 ~S(exec "$@" </dev/null),
                 "claude-wrapper",
                 "claude",
                 "--setting-sources",
                 ""
               ]
    end

    test "an empty arg stays a distinct token" do
      binary = executable_fixture("argv")

      assert {"--setting-sources\n\nnext\n", 0} =
               System.cmd(
                 "/bin/sh",
                 Command.launcher_args(binary, ["--setting-sources", "", "next"])
               )
    end

    test "executes a binary whose path contains spaces" do
      binary = executable_fixture("claude runner")

      assert {"first arg\nsecond\n", 0} =
               System.cmd("/bin/sh", Command.launcher_args(binary, ["first arg", "second"]))
    end

    test "treats shell metacharacters in the binary path literally" do
      for name <- ["claude$HOME", "claude;echo injected", "claude's CLI"] do
        binary = executable_fixture(name)

        assert {"literal\n", 0} =
                 System.cmd("/bin/sh", Command.launcher_args(binary, ["literal"]))
      end
    end

    test "gives the binary an empty stdin" do
      dir = Path.dirname(executable_fixture("unused"))
      binary = Path.join(dir, "read_stdin")
      File.write!(binary, "#!/bin/sh\ncat\necho eof\n")
      File.chmod!(binary, 0o755)

      assert {"eof\n", 0} = System.cmd("/bin/sh", Command.launcher_args(binary, []))
    end
  end

  defp executable_fixture(name) do
    dir =
      Path.join(System.tmp_dir!(), "claude-wrapper-command-#{System.unique_integer([:positive])}")

    File.mkdir_p!(dir)
    on_exit(fn -> File.rm_rf!(dir) end)

    binary = Path.join(dir, name)
    File.write!(binary, "#!/bin/sh\nprintf '%s\\n' \"$@\"\n")
    File.chmod!(binary, 0o755)
    binary
  end
end
