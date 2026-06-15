defmodule ClaudeWrapper.WorktreesTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Worktrees
  alias ClaudeWrapper.Worktrees.Worktree

  setup do
    base = Path.join(System.tmp_dir!(), "cwx_worktrees_#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, base: base}
  end

  # Run git in `dir`, asserting success. Identity + an initial commit are
  # set inline so the suite does not depend on the developer's global
  # git config.
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

  # A fresh repo at <base>/repo with one empty commit on `main`.
  defp init_repo(base) do
    repo = Path.join(base, "repo")
    File.mkdir_p!(repo)
    git!(repo, ["init", "-q", "-b", "main"])
    git!(repo, ["commit", "-q", "--allow-empty", "-m", "init"])
    repo
  end

  defp find(worktrees, leaf) do
    Enum.find(worktrees, fn wt -> Path.basename(wt.path) == leaf end)
  end

  describe "for_repo/1 and path/1" do
    test "establishes a root for a real repo and path/1 reads it back", %{base: base} do
      repo = init_repo(base)

      assert {:ok, %Worktrees{} = root} = Worktrees.for_repo(repo)
      assert Worktrees.path(root) == repo
    end

    test "errors with {:not_a_git_repo, path} for a plain directory", %{base: base} do
      plain = Path.join(base, "plain")
      File.mkdir_p!(plain)

      assert {:error, {:not_a_git_repo, ^plain}} = Worktrees.for_repo(plain)
    end
  end

  describe "list/1 -- main worktree" do
    test "a single repo reports exactly the main worktree", %{base: base} do
      repo = init_repo(base)
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, [wt]} = Worktrees.list(root)

      assert %Worktree{is_main?: true, is_detached?: false, is_bare?: false} = wt
      assert wt.branch == "main"
      assert is_binary(wt.head) and wt.head != ""
      assert Path.basename(wt.path) == "repo"
      refute wt.is_locked?
      refute wt.is_prunable?
    end

    test "the main worktree is always first even with siblings added", %{base: base} do
      repo = init_repo(base)
      git!(repo, ["worktree", "add", "-q", Path.join(base, "wt-a"), "-b", "a"])
      git!(repo, ["worktree", "add", "-q", Path.join(base, "wt-b"), "-b", "b"])
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, [main | rest]} = Worktrees.list(root)

      assert main.is_main?
      assert Path.basename(main.path) == "repo"
      assert Enum.all?(rest, &(&1.is_main? == false))
    end
  end

  describe "list/1 -- added worktrees on a branch" do
    test "reports the branch name without the refs/heads/ prefix", %{base: base} do
      repo = init_repo(base)
      git!(repo, ["worktree", "add", "-q", Path.join(base, "wt-feature"), "-b", "feature"])
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      feature = find(worktrees, "wt-feature")

      assert %Worktree{branch: "feature", is_detached?: false} = feature
      refute feature.is_main?
    end

    test "preserves slashes in nested branch names", %{base: base} do
      repo = init_repo(base)

      git!(repo, [
        "worktree",
        "add",
        "-q",
        Path.join(base, "wt-nested"),
        "-b",
        "feature/long/path"
      ])

      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      assert find(worktrees, "wt-nested").branch == "feature/long/path"
    end
  end

  describe "list/1 -- detached HEAD" do
    test "flags a detached worktree with no branch", %{base: base} do
      repo = init_repo(base)
      head = String.trim(git!(repo, ["rev-parse", "HEAD"]))
      git!(repo, ["worktree", "add", "-q", "--detach", Path.join(base, "wt-detached"), head])
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      detached = find(worktrees, "wt-detached")

      assert %Worktree{is_detached?: true, branch: nil} = detached
      assert detached.head == head
    end
  end

  describe "list/1 -- locked worktrees" do
    test "captures the lock reason when one is given", %{base: base} do
      repo = init_repo(base)
      path = Path.join(base, "wt-locked")
      git!(repo, ["worktree", "add", "-q", path, "-b", "locked"])
      git!(repo, ["worktree", "lock", "--reason", "cutting v2", path])
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      locked = find(worktrees, "wt-locked")

      assert %Worktree{is_locked?: true, lock_reason: "cutting v2"} = locked
    end

    test "leaves lock_reason nil when locked without a reason", %{base: base} do
      repo = init_repo(base)
      path = Path.join(base, "wt-wedged")
      git!(repo, ["worktree", "add", "-q", path, "-b", "wedged"])
      git!(repo, ["worktree", "lock", path])
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      wedged = find(worktrees, "wt-wedged")

      assert %Worktree{is_locked?: true, lock_reason: nil} = wedged
    end
  end

  describe "list/1 -- bare and prunable" do
    test "flags a bare repository worktree with no head or branch", %{base: base} do
      bare = Path.join(base, "bare.git")
      git!(base, ["init", "-q", "--bare", "bare.git"])
      {:ok, root} = Worktrees.for_repo(bare)

      {:ok, [wt]} = Worktrees.list(root)

      assert %Worktree{is_bare?: true, is_main?: true, head: nil, branch: nil} = wt
    end

    test "flags a worktree as prunable once its directory is gone", %{base: base} do
      repo = init_repo(base)
      gone = Path.join(base, "wt-gone")
      git!(repo, ["worktree", "add", "-q", gone, "-b", "gone"])
      File.rm_rf!(gone)
      {:ok, root} = Worktrees.for_repo(repo)

      {:ok, worktrees} = Worktrees.list(root)
      prunable = find(worktrees, "wt-gone")

      assert %Worktree{is_prunable?: true} = prunable
      assert is_binary(prunable.prune_reason)
      assert prunable.prune_reason =~ "non-existent"
    end
  end

  describe "list/1 -- error path" do
    test "errors with {:not_a_git_repo, path} for a non-repo directory", %{base: base} do
      plain = Path.join(base, "plain")
      File.mkdir_p!(plain)
      root = %Worktrees{repo_path: plain}

      assert {:error, {:not_a_git_repo, ^plain}} = Worktrees.list(root)
    end
  end
end
