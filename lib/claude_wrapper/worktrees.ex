defmodule ClaudeWrapper.Worktrees.Worktree do
  @moduledoc """
  One git worktree as reported by `git worktree list --porcelain`.

  See `ClaudeWrapper.Worktrees` for how these are produced.
  """

  @enforce_keys [:path]
  defstruct [
    :path,
    :head,
    :branch,
    :lock_reason,
    :prune_reason,
    is_main?: false,
    is_detached?: false,
    is_bare?: false,
    is_locked?: false,
    is_prunable?: false
  ]

  @type t :: %__MODULE__{
          path: String.t(),
          head: String.t() | nil,
          branch: String.t() | nil,
          lock_reason: String.t() | nil,
          prune_reason: String.t() | nil,
          is_main?: boolean(),
          is_detached?: boolean(),
          is_bare?: boolean(),
          is_locked?: boolean(),
          is_prunable?: boolean()
        }
end

defmodule ClaudeWrapper.Worktrees do
  @moduledoc """
  Read-side introspection for git worktrees.

  Claude Code's `--worktree [name]` flag (and its `DuplexSession`
  equivalent) creates fresh git worktrees so an agent's writes can land
  somewhere other than the current working tree. Hosts that orchestrate
  worktree-isolated chats need a way to enumerate the worktrees that
  exist for a given repo, see what branches they're on, and notice when
  one is locked or prunable.

  This module is a thin Elixir API over `git worktree list --porcelain`.
  It is read-only on purpose; mutations (pruning, removing worktrees) are
  out of scope so consumers that only want to introspect don't opt into
  write semantics.

  ## Why shell out

  Reading `.git/worktrees/` directly is brittle: git tracks `locked`,
  `prunable`, detached-HEAD, and bare-repo state in ways that have
  evolved across releases. Asking git itself is the cheap, correct
  option, and `git` is already a transitive dependency of any
  worktree-using workflow.

  ## Example

      {:ok, root} = ClaudeWrapper.Worktrees.for_repo(".")
      {:ok, worktrees} = ClaudeWrapper.Worktrees.list(root)

      for wt <- worktrees do
        IO.puts("\#{wt.path}  \#{wt.branch || "(detached)"}")
      end
  """

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.Worktrees.Worktree

  @enforce_keys [:repo_path]
  defstruct [:repo_path]

  @type t :: %__MODULE__{repo_path: String.t()}

  @doc """
  Address worktrees for the repository containing `path`.

  `path` can be any directory inside the repo; git's `-C` handling
  resolves the `.git` itself. Runs `git worktree list --porcelain` once
  to validate that `path` is in fact inside a git repository.

  Returns `{:error, %ClaudeWrapper.Error{kind: :not_a_git_repo}}` when
  `path` is not inside a repository (the path is in `:reason`),
  `{:error, %ClaudeWrapper.Error{kind: :git_failed}}` for other non-zero
  git exits, and `{:error, %ClaudeWrapper.Error{kind: :git_unavailable}}`
  when the `git` binary cannot be spawned.
  """
  @spec for_repo(String.t()) :: {:ok, t()} | {:error, Error.t()}
  def for_repo(path) when is_binary(path) do
    root = %__MODULE__{repo_path: path}

    case run_porcelain(root) do
      {:ok, _stdout} -> {:ok, root}
      {:error, _reason} = err -> err
    end
  end

  @doc "The configured repository path."
  @spec path(t()) :: String.t()
  def path(%__MODULE__{repo_path: repo_path}), do: repo_path

  @doc """
  List every worktree git knows about for this repository.

  Spawns `git -C <repo_path> worktree list --porcelain` and parses the
  output. The first entry is the main worktree (`is_main? == true`).

  Returns the same error shapes as `for_repo/1`.
  """
  @spec list(t()) :: {:ok, [Worktree.t()]} | {:error, Error.t()}
  def list(%__MODULE__{} = root) do
    case run_porcelain(root) do
      {:ok, stdout} -> {:ok, parse_porcelain(stdout)}
      {:error, _reason} = err -> err
    end
  end

  # -- git invocation ------------------------------------------------

  defp run_porcelain(%__MODULE__{repo_path: repo_path}) do
    args = ["-C", repo_path, "worktree", "list", "--porcelain"]

    case safe_cmd(args) do
      {:ok, {output, 0}} -> {:ok, output}
      {:ok, {output, status}} -> {:error, classify_failure(repo_path, status, output)}
      {:error, _reason} = err -> err
    end
  end

  # Wrap System.cmd so a missing `git` binary becomes a tagged error
  # instead of an :enoent ErlangError escaping the module.
  defp safe_cmd(args) do
    {:ok, System.cmd("git", args, stderr_to_stdout: true)}
  rescue
    e in ErlangError -> {:error, Error.new(:git_unavailable, reason: e.original)}
  end

  defp classify_failure(repo_path, status, output) do
    if String.contains?(output, "not a git repository") do
      Error.new(:not_a_git_repo, reason: repo_path)
    else
      stderr = String.trim(output)

      Error.new(:git_failed,
        reason: %{status: status, stderr: stderr},
        exit_code: status,
        stderr: stderr
      )
    end
  end

  # -- porcelain parsing ---------------------------------------------

  defp parse_porcelain(input) do
    input
    |> split_paragraphs()
    |> Enum.map(&parse_paragraph/1)
    |> mark_first_as_main()
  end

  # Split on blank lines into paragraphs of non-empty lines, tolerating
  # CRLF and a trailing block with no closing blank line.
  defp split_paragraphs(input) do
    input
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing(&1, "\r"))
    |> Enum.chunk_by(&(&1 == ""))
    |> Enum.reject(&blank_chunk?/1)
  end

  defp blank_chunk?(lines), do: Enum.all?(lines, &(&1 == ""))

  defp parse_paragraph(lines) do
    Enum.reduce(lines, %Worktree{path: ""}, &apply_line/2)
  end

  defp apply_line(line, wt) do
    {key, value} = split_key_value(line)
    apply_field(wt, key, value)
  end

  # Each porcelain line is either `key value` or a bare `key` flag.
  defp split_key_value(line) do
    case String.split(line, " ", parts: 2) do
      [key, value] -> {key, value}
      [key] -> {key, nil}
    end
  end

  defp apply_field(wt, "worktree", value), do: %{wt | path: value || ""}
  defp apply_field(wt, "HEAD", value), do: %{wt | head: value}
  defp apply_field(wt, "branch", value), do: %{wt | branch: strip_branch_prefix(value)}
  defp apply_field(wt, "detached", _value), do: %{wt | is_detached?: true}
  defp apply_field(wt, "bare", _value), do: %{wt | is_bare?: true}

  defp apply_field(wt, "locked", value) do
    %{wt | is_locked?: true, lock_reason: present_or_nil(value)}
  end

  defp apply_field(wt, "prunable", value) do
    %{wt | is_prunable?: true, prune_reason: present_or_nil(value)}
  end

  # Unknown keys are ignored, keeping the parser forward-compatible with
  # future porcelain fields.
  defp apply_field(wt, _key, _value), do: wt

  defp mark_first_as_main([]), do: []
  defp mark_first_as_main([first | rest]), do: [%{first | is_main?: true} | rest]

  defp strip_branch_prefix(nil), do: nil

  defp strip_branch_prefix(branch) do
    String.replace_prefix(branch, "refs/heads/", "")
  end

  defp present_or_nil(nil), do: nil
  defp present_or_nil(""), do: nil
  defp present_or_nil(value), do: value
end
