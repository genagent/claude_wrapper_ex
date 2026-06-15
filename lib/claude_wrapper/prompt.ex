defmodule ClaudeWrapper.Prompt do
  @moduledoc """
  Composable prompt builder with deferred file / git-diff expansion.

  A `Prompt` is a pure value: the builders (`new/1`, `prepend/2`,
  `append/2`, `attach/2`, `git_diff/2`) only record intent. All IO --
  reading attached files, shelling out to `git diff` -- happens in
  `render/1`, which assembles the final string in a **fixed order**:

      prepends -> base -> attachments -> diffs -> appends

  Each section is separated from the next by a blank line, and within the
  context section attachments and diffs appear in the order their builder
  calls were made (interleaved exactly as you wrote them).

  This split keeps composition cheap and total -- you can build a prompt
  without touching the filesystem -- and concentrates every fallible
  operation in `render/1`, which returns a tagged tuple.

  ## Example

      iex> ClaudeWrapper.Prompt.new("Review this change")
      ...> |> ClaudeWrapper.Prompt.prepend("You are a careful reviewer.")
      ...> |> ClaudeWrapper.Prompt.append("Focus on correctness.")
      ...> |> ClaudeWrapper.Prompt.render()
      {:ok, "You are a careful reviewer.\\n\\nReview this change\\n\\nFocus on correctness."}

  Attached files are emitted as fenced code blocks, each headed by a
  `# <path>` comment line. Globs are expanded with `Path.wildcard/1` and
  sorted; a glob that matches nothing is an error. Files that are not
  valid UTF-8 text, or that exceed #{div(262_144, 1024)} KB, are skipped.

  Git diffs are emitted inside a ```` ```diff ```` fence. `git_diff(p,
  nil)` diffs the working tree; `git_diff(p, ref)` diffs against `ref`.
  """

  alias ClaudeWrapper.Error

  @typedoc """
  A recorded context item, expanded at render time in call order.

    * `{:attach, glob}` -- a path or glob; each matched text file becomes
      a fenced, path-headed block.
    * `{:diff, ref}` -- a `git diff`; `nil` is the working tree, a binary
      is a ref/commit to diff against.
  """
  @type context_item :: {:attach, String.t()} | {:diff, String.t() | nil}

  @type t :: %__MODULE__{
          base: String.t(),
          prepends: [String.t()],
          appends: [String.t()],
          context: [context_item()]
        }

  @enforce_keys [:base]
  defstruct base: "", prepends: [], appends: [], context: []

  # Files larger than this are skipped during attach expansion. 256 KB is
  # generous for source files while keeping a single prompt from ballooning
  # on an accidentally-matched binary or build artifact.
  @max_attach_bytes 262_144

  @doc """
  Start a new prompt from its base text.

      iex> ClaudeWrapper.Prompt.new("hello").base
      "hello"
  """
  @spec new(String.t()) :: t()
  def new(base) when is_binary(base), do: %__MODULE__{base: base}

  @doc """
  Add a block before the base text.

  Multiple prepends render in the order they were added, ahead of the
  base.
  """
  @spec prepend(t(), String.t()) :: t()
  def prepend(%__MODULE__{} = prompt, text) when is_binary(text) do
    %{prompt | prepends: prompt.prepends ++ [text]}
  end

  @doc """
  Add a block after everything else.

  Multiple appends render in the order they were added, after the
  context section.
  """
  @spec append(t(), String.t()) :: t()
  def append(%__MODULE__{} = prompt, text) when is_binary(text) do
    %{prompt | appends: prompt.appends ++ [text]}
  end

  @doc """
  Record a file path or glob to attach.

  Nothing is read now; the glob is expanded at `render/1` time with
  `Path.wildcard/1`, sorted, and each text file is emitted as a fenced,
  path-headed code block. Recorded in call order relative to
  `git_diff/2`.
  """
  @spec attach(t(), String.t()) :: t()
  def attach(%__MODULE__{} = prompt, glob) when is_binary(glob) do
    %{prompt | context: prompt.context ++ [{:attach, glob}]}
  end

  @doc """
  Record a git diff to include.

  `ref` is `nil` for the working tree, or a ref/commit string to diff
  against (`git diff <ref>`). The diff is produced at `render/1` time and
  emitted inside a ```` ```diff ```` fence. Recorded in call order
  relative to `attach/2`.
  """
  @spec git_diff(t(), String.t() | nil) :: t()
  def git_diff(%__MODULE__{} = prompt, ref) when is_binary(ref) or is_nil(ref) do
    %{prompt | context: prompt.context ++ [{:diff, ref}]}
  end

  @doc """
  Render the prompt to its final string.

  Performs all deferred IO -- reads attached files, runs `git diff` --
  and joins the sections (prepends, base, attachments, diffs, appends)
  with blank lines.

  Returns `{:error, %ClaudeWrapper.Error{}}` if a glob matches no files
  (`:not_found`), or if a git diff fails (`:git_failed`) or `git` is
  unavailable (`:git_unavailable`). The working directory for both file
  globs and git is the current process cwd.
  """
  @spec render(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(%__MODULE__{} = prompt) do
    with {:ok, context} <- render_context(prompt.context) do
      sections = prompt.prepends ++ [prompt.base] ++ context ++ prompt.appends

      rendered =
        sections
        |> Enum.reject(&(&1 == ""))
        |> Enum.join("\n\n")

      {:ok, rendered}
    end
  end

  @doc """
  Like `render/1` but returns the string directly, raising
  `ClaudeWrapper.Error` on failure.
  """
  @spec render!(t()) :: String.t()
  def render!(%__MODULE__{} = prompt) do
    case render(prompt) do
      {:ok, rendered} -> rendered
      {:error, error} -> raise error
    end
  end

  # -- context rendering ---------------------------------------------

  defp render_context(items) do
    items
    |> Enum.reduce_while({:ok, []}, &reduce_context_item/2)
    |> finalize_context()
  end

  defp reduce_context_item(item, {:ok, acc}) do
    case render_item(item) do
      {:ok, blocks} -> {:cont, {:ok, acc ++ blocks}}
      {:error, _} = error -> {:halt, error}
    end
  end

  defp finalize_context({:ok, blocks}), do: {:ok, blocks}
  defp finalize_context({:error, _} = error), do: error

  # An attach can yield several blocks (one per matched file); a diff
  # yields at most one. Both return `{:ok, [block]}` or `{:error, _}`.
  defp render_item({:attach, glob}), do: render_attach(glob)
  defp render_item({:diff, ref}), do: render_diff(ref)

  # -- attach --------------------------------------------------------

  defp render_attach(glob) do
    case glob |> Path.wildcard() |> Enum.sort() do
      [] -> {:error, Error.new(:not_found, reason: glob)}
      paths -> {:ok, paths |> Enum.map(&attach_block/1) |> Enum.reject(&is_nil/1)}
    end
  end

  # Read a single path into a fenced, path-headed block. Returns nil for
  # directories, oversized files, unreadable files, or non-UTF-8 content
  # so they are skipped rather than failing the whole render.
  defp attach_block(path) do
    with {:ok, %File.Stat{type: :regular, size: size}} when size <= @max_attach_bytes <-
           File.stat(path),
         {:ok, content} <- File.read(path),
         true <- String.valid?(content) do
      "# #{path}\n```\n#{trim_trailing_newline(content)}\n```"
    else
      _ -> nil
    end
  end

  defp trim_trailing_newline(content), do: String.trim_trailing(content, "\n")

  # -- git diff ------------------------------------------------------

  defp render_diff(ref) do
    args = ["diff"] ++ if(ref, do: [ref], else: [])

    case safe_git(args) do
      {:ok, {output, 0}} -> {:ok, diff_blocks(output)}
      {:ok, {output, status}} -> {:error, git_failed(status, output)}
      {:error, _} = error -> error
    end
  end

  # An empty diff (no changes) contributes no block.
  defp diff_blocks(output) do
    case String.trim(output) do
      "" -> []
      trimmed -> ["```diff\n#{trimmed}\n```"]
    end
  end

  # Wrap System.cmd so a missing `git` binary becomes a tagged error
  # instead of an ErlangError escaping the module. Mirrors
  # ClaudeWrapper.Worktrees. Git (like the attach globs) runs relative to
  # the current process cwd, passed explicitly via `:cd` so the working
  # directory the diff is taken in is unambiguous.
  defp safe_git(args) do
    {:ok, System.cmd("git", args, stderr_to_stdout: true, cd: File.cwd!())}
  rescue
    e in ErlangError -> {:error, Error.new(:git_unavailable, reason: e.original)}
  end

  defp git_failed(status, output) do
    stderr = String.trim(output)

    Error.new(:git_failed,
      reason: %{status: status, stderr: stderr},
      exit_code: status,
      stderr: stderr
    )
  end
end
