defmodule ClaudeWrapper.PromptTest do
  # async: false -- the git_diff tests change the process working directory
  # (render/1 expands globs and runs `git diff` relative to the process
  # cwd), which is global state that cannot be shared across async tests.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Error, Prompt}

  setup do
    base = Path.join(System.tmp_dir!(), "cwx_prompt_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  describe "builders" do
    test "new sets the base" do
      assert %Prompt{base: "hi", prepends: [], appends: [], context: []} = Prompt.new("hi")
    end

    test "prepend/append/attach/git_diff accumulate in call order" do
      prompt =
        "base"
        |> Prompt.new()
        |> Prompt.prepend("p1")
        |> Prompt.attach("a/*.ex")
        |> Prompt.git_diff(nil)
        |> Prompt.append("ap1")
        |> Prompt.git_diff("HEAD~1")
        |> Prompt.prepend("p2")

      assert prompt.prepends == ["p1", "p2"]
      assert prompt.appends == ["ap1"]
      assert prompt.context == [{:attach, "a/*.ex"}, {:diff, nil}, {:diff, "HEAD~1"}]
    end
  end

  describe "render/1 ordering" do
    test "joins prepends -> base -> appends with blank lines" do
      rendered =
        "base text"
        |> Prompt.new()
        |> Prompt.prepend("first")
        |> Prompt.prepend("second")
        |> Prompt.append("last")
        |> Prompt.render()

      assert {:ok, "first\n\nsecond\n\nbase text\n\nlast"} = rendered
    end

    test "base-only renders just the base" do
      assert {:ok, "just base"} = "just base" |> Prompt.new() |> Prompt.render()
    end

    test "attachments come after base and before appends", %{base: base} do
      file = Path.join(base, "only.txt")
      File.write!(file, "FILE BODY")

      rendered =
        "the base"
        |> Prompt.new()
        |> Prompt.prepend("PRE")
        |> Prompt.attach(file)
        |> Prompt.append("POST")
        |> Prompt.render()

      assert {:ok, text} = rendered
      pre_idx = index_of(text, "PRE")
      base_idx = index_of(text, "the base")
      file_idx = index_of(text, "FILE BODY")
      post_idx = index_of(text, "POST")
      assert pre_idx < base_idx
      assert base_idx < file_idx
      assert file_idx < post_idx
    end
  end

  describe "render/1 attach" do
    test "a single file is fenced and headed by its path", %{base: base} do
      file = Path.join(base, "hello.ex")
      File.write!(file, "defmodule Hello do\nend\n")

      assert {:ok, text} = "go" |> Prompt.new() |> Prompt.attach(file) |> Prompt.render()
      assert text =~ "# #{file}\n```\ndefmodule Hello do\nend\n```"
    end

    test "a glob expands sorted, each file fenced and headed", %{base: base} do
      File.write!(Path.join(base, "b.txt"), "BBB")
      File.write!(Path.join(base, "a.txt"), "AAA")
      File.write!(Path.join(base, "c.txt"), "CCC")

      glob = Path.join(base, "*.txt")
      assert {:ok, text} = "go" |> Prompt.new() |> Prompt.attach(glob) |> Prompt.render()

      a = Path.join(base, "a.txt")
      b = Path.join(base, "b.txt")
      c = Path.join(base, "c.txt")

      # Sorted order: a, b, c.
      assert index_of(text, "# #{a}") < index_of(text, "# #{b}")
      assert index_of(text, "# #{b}") < index_of(text, "# #{c}")
      assert text =~ "```\nAAA\n```"
      assert text =~ "```\nBBB\n```"
      assert text =~ "```\nCCC\n```"
    end

    test "a glob matching nothing is a :not_found error", %{base: base} do
      glob = Path.join(base, "nope-*.zzz")

      assert {:error, %Error{kind: :not_found, reason: ^glob}} =
               "go" |> Prompt.new() |> Prompt.attach(glob) |> Prompt.render()
    end

    test "oversized files are skipped", %{base: base} do
      small = Path.join(base, "small.txt")
      big = Path.join(base, "big.txt")
      File.write!(small, "keepme")
      # 300 KB > 256 KB cap.
      File.write!(big, String.duplicate("x", 300 * 1024))

      glob = Path.join(base, "*.txt")
      assert {:ok, text} = "go" |> Prompt.new() |> Prompt.attach(glob) |> Prompt.render()
      assert text =~ "# #{small}"
      assert text =~ "keepme"
      refute text =~ "# #{big}"
    end

    test "non-text (invalid UTF-8) files are skipped", %{base: base} do
      good = Path.join(base, "good.txt")
      binfile = Path.join(base, "bin.dat")
      File.write!(good, "readable")
      File.write!(binfile, <<0xFF, 0xFE, 0x00, 0x01>>)

      glob = Path.join(base, "*")
      assert {:ok, text} = "go" |> Prompt.new() |> Prompt.attach(glob) |> Prompt.render()
      assert text =~ "# #{good}"
      refute text =~ "# #{binfile}"
    end
  end

  describe "render/1 git_diff" do
    test "working-tree diff is fenced as ```diff", %{base: base} do
      init_repo(base)
      File.write!(Path.join(base, "tracked.txt"), "v1\n")
      git!(base, ["add", "."])
      git!(base, ["commit", "-m", "init"])
      File.write!(Path.join(base, "tracked.txt"), "v2\n")

      rendered =
        in_dir(base, fn ->
          "review" |> Prompt.new() |> Prompt.git_diff(nil) |> Prompt.render()
        end)

      assert {:ok, text} = rendered
      assert text =~ "```diff"
      assert text =~ "-v1"
      assert text =~ "+v2"
    end

    test "diff against a ref is fenced as ```diff", %{base: base} do
      init_repo(base)
      File.write!(Path.join(base, "f.txt"), "one\n")
      git!(base, ["add", "."])
      git!(base, ["commit", "-m", "c1"])
      File.write!(Path.join(base, "f.txt"), "two\n")
      git!(base, ["add", "."])
      git!(base, ["commit", "-m", "c2"])

      rendered =
        in_dir(base, fn ->
          "review" |> Prompt.new() |> Prompt.git_diff("HEAD~1") |> Prompt.render()
        end)

      assert {:ok, text} = rendered
      assert text =~ "```diff"
      assert text =~ "-one"
      assert text =~ "+two"
    end

    test "a clean working tree contributes no diff block", %{base: base} do
      init_repo(base)
      File.write!(Path.join(base, "f.txt"), "stable\n")
      git!(base, ["add", "."])
      git!(base, ["commit", "-m", "c1"])

      rendered =
        in_dir(base, fn ->
          "review" |> Prompt.new() |> Prompt.git_diff(nil) |> Prompt.render()
        end)

      # No changes -> base only, no fence.
      assert {:ok, "review"} = rendered
    end

    test "a non-repo directory is a :git_failed error", %{base: base} do
      # base is a plain dir, not a git repo.
      rendered =
        in_dir(base, fn ->
          "review" |> Prompt.new() |> Prompt.git_diff(nil) |> Prompt.render()
        end)

      assert {:error, %Error{kind: :git_failed}} = rendered
    end
  end

  describe "render!/1" do
    test "returns the string on success" do
      assert "x" == "x" |> Prompt.new() |> Prompt.render!()
    end

    test "raises ClaudeWrapper.Error on failure", %{base: base} do
      glob = Path.join(base, "missing-*.none")

      assert_raise Error, fn ->
        "x" |> Prompt.new() |> Prompt.attach(glob) |> Prompt.render!()
      end
    end
  end

  # -- helpers -------------------------------------------------------

  defp index_of(haystack, needle) do
    {idx, _} = :binary.match(haystack, needle)
    idx
  end

  # Run `fun` with the process cwd set to `dir`, restoring it after. Used
  # for the git_diff tests, since render/1 operates on the process cwd.
  defp in_dir(dir, fun) do
    previous = File.cwd!()
    File.cd!(dir)

    try do
      fun.()
    after
      File.cd!(previous)
    end
  end

  defp init_repo(dir) do
    git!(dir, ["init", "-q"])
    git!(dir, ["config", "user.name", "t"])
    git!(dir, ["config", "user.email", "t@example.com"])
  end

  defp git!(dir, args) do
    {out, status} =
      System.cmd("git", ["-C", dir | args],
        stderr_to_stdout: true,
        env: [
          {"GIT_AUTHOR_NAME", "t"},
          {"GIT_AUTHOR_EMAIL", "t@example.com"},
          {"GIT_COMMITTER_NAME", "t"},
          {"GIT_COMMITTER_EMAIL", "t@example.com"}
        ]
      )

    assert status == 0, "git #{Enum.join(args, " ")} failed: #{out}"
    out
  end
end
