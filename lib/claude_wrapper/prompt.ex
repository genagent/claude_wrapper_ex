defmodule ClaudeWrapper.Prompt do
  @moduledoc """
  Composable prompt builder with deferred file / git expansion.

  A `Prompt` is a pure value: the builders (`new/1`, `prepend/2`,
  `append/2`, `attach/2`, `git_diff/2`, `git_log/2`, `git_status/1`,
  `vars/2`) only record intent. All IO -- reading attached files, shelling
  out to git -- happens in `render/1`, which assembles the final string in
  a **fixed order**:

      prepends -> base -> context (attach / git) -> appends

  Each section is separated from the next by a blank line, and within the
  context section the attach/git blocks appear in the order their builder
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

  ## Context blocks

  Attached files and git output are emitted as fenced blocks, each headed
  by a `# <source>` comment line:

    * `attach/2` -- one `# <path>` block per matched text file. Globs are
      expanded with `Path.wildcard/1` and sorted; a glob matching nothing
      is an error. Files that are not valid UTF-8, or exceed
      #{div(262_144, 1024)} KB, are skipped.
    * `git_diff/2` -- `# git diff` (working tree) or `# git diff <ref>`,
      inside a ```` ```diff ```` fence.
    * `git_log/2` -- `# git log --oneline -n N` (default 5).
    * `git_status/1` -- `# git status --short`.

  A git block whose output is empty (clean tree, no commits, no changes)
  contributes nothing rather than an empty fence.

  ## Template variables

  `vars/2` records `{{key}}` substitutions applied to the **authored** text
  (base / prepends / appends) at render time; captured context blocks are
  left verbatim. Unknown `{{...}}` slots are left untouched.

      iex> ClaudeWrapper.Prompt.new("Summarize {{file}} for a {{who}} reader")
      ...> |> ClaudeWrapper.Prompt.vars(file: "config.ex", who: "beginner")
      ...> |> ClaudeWrapper.Prompt.render()
      {:ok, "Summarize config.ex for a beginner reader"}
  """

  alias ClaudeWrapper.Error

  @typedoc """
  A recorded context item, expanded at render time in call order.

    * `{:attach, glob}` -- a path or glob; each matched text file becomes
      a fenced, path-headed block.
    * `{:diff, ref}` -- a `git diff`; `nil` is the working tree, a binary
      is a ref/commit to diff against.
    * `{:log, n}` -- a `git log --oneline -n n` block.
    * `:status` -- a `git status --short` block.
  """
  @type context_item ::
          {:attach, String.t()}
          | {:diff, String.t() | nil}
          | {:log, pos_integer()}
          | :status

  @type t :: %__MODULE__{
          base: String.t(),
          prepends: [String.t()],
          appends: [String.t()],
          context: [context_item()],
          vars: %{optional(String.t()) => String.t()}
        }

  @enforce_keys [:base]
  defstruct base: "", prepends: [], appends: [], context: [], vars: %{}

  # Files larger than this are skipped during attach expansion. 256 KB is
  # generous for source files while keeping a single prompt from ballooning
  # on an accidentally-matched binary or build artifact.
  @max_attach_bytes 262_144

  # Default commit count for git_log/2.
  @default_log_count 5

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
  path-headed code block. Recorded in call order relative to the other
  context builders.
  """
  @spec attach(t(), String.t()) :: t()
  def attach(%__MODULE__{} = prompt, glob) when is_binary(glob) do
    %{prompt | context: prompt.context ++ [{:attach, glob}]}
  end

  @doc """
  Record a git diff to include.

  `ref` is `nil` for the working tree, or a ref/commit string to diff
  against (`git diff <ref>`). Produced at `render/1` time under a
  `# git diff` header inside a ```` ```diff ```` fence. Recorded in call
  order relative to the other context builders.
  """
  @spec git_diff(t(), String.t() | nil) :: t()
  def git_diff(%__MODULE__{} = prompt, ref) when is_binary(ref) or is_nil(ref) do
    %{prompt | context: prompt.context ++ [{:diff, ref}]}
  end

  @doc """
  Record a `git log --oneline -n N` block (default N = #{@default_log_count}).

  Options:

    * `:n` -- number of commits (default #{@default_log_count}).

  Produced at `render/1` time under a `# git log` header. Recorded in call
  order relative to the other context builders.
  """
  @spec git_log(t(), keyword()) :: t()
  def git_log(%__MODULE__{} = prompt, opts \\ []) when is_list(opts) do
    n = Keyword.get(opts, :n, @default_log_count)
    %{prompt | context: prompt.context ++ [{:log, n}]}
  end

  @doc """
  Record a `git status --short` block.

  Produced at `render/1` time under a `# git status` header. A clean
  working tree contributes no block. Recorded in call order relative to
  the other context builders.
  """
  @spec git_status(t()) :: t()
  def git_status(%__MODULE__{} = prompt) do
    %{prompt | context: prompt.context ++ [:status]}
  end

  @doc """
  Record `{{key}}` template substitutions.

  Applied at `render/1` time to the authored text (base, prepends,
  appends) only -- captured context blocks (`attach`/`git_*`) are left
  verbatim. Accepts a map or keyword list; keys and values are stringified.
  Unknown `{{...}}` placeholders are left untouched. Repeatable (later
  calls merge, last wins).

      iex> ClaudeWrapper.Prompt.new("hi {{name}}").vars
      %{}
  """
  @spec vars(t(), map() | keyword()) :: t()
  def vars(%__MODULE__{} = prompt, vars) when is_map(vars) or is_list(vars) do
    normalized = Map.new(vars, fn {k, v} -> {to_string(k), to_string(v)} end)
    %{prompt | vars: Map.merge(prompt.vars, normalized)}
  end

  @doc """
  Render the prompt to its final string.

  Performs all deferred IO -- reads attached files, runs git -- substitutes
  template vars in the authored text, and joins the sections (prepends,
  base, context, appends) with blank lines.

  Returns `{:error, %ClaudeWrapper.Error{}}` if a glob matches no files
  (`:not_found`), or if a git command fails (`:git_failed`) or `git` is
  unavailable (`:git_unavailable`). The working directory for file globs
  and git is the current process cwd.
  """
  @spec render(t()) :: {:ok, String.t()} | {:error, Error.t()}
  def render(%__MODULE__{} = prompt) do
    with {:ok, context} <- render_context(prompt.context) do
      prepends = Enum.map(prompt.prepends, &substitute(&1, prompt.vars))
      base = substitute(prompt.base, prompt.vars)
      appends = Enum.map(prompt.appends, &substitute(&1, prompt.vars))

      rendered =
        (prepends ++ [base] ++ context ++ appends)
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

  # -- template substitution -----------------------------------------

  # Single-pass `{{key}}` substitution over authored text. Unknown keys are
  # left verbatim and substituted values are never re-scanned. A prompt
  # with no vars is returned untouched.
  defp substitute(text, vars) when map_size(vars) == 0, do: text

  defp substitute(text, vars) do
    Regex.replace(~r/\{\{(\w+)\}\}/, text, fn whole, key -> Map.get(vars, key, whole) end)
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

  # Each item yields `{:ok, [block]}` (attach can be many; git is at most
  # one) or `{:error, _}`.
  defp render_item({:attach, glob}), do: render_attach(glob)
  defp render_item({:diff, ref}), do: render_diff(ref)
  defp render_item({:log, n}), do: render_log(n)
  defp render_item(:status), do: render_status()

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

  # -- git -----------------------------------------------------------

  defp render_diff(ref) do
    header = if ref, do: "# git diff #{ref}", else: "# git diff"
    args = ["diff"] ++ if(ref, do: [ref], else: [])
    run_git_block(args, header, "diff")
  end

  defp render_log(n) do
    run_git_block(["log", "--oneline", "-n", to_string(n)], "# git log --oneline -n #{n}", "")
  end

  defp render_status do
    run_git_block(["status", "--short"], "# git status --short", "")
  end

  # Run a git command and wrap its stdout in a headed, fenced block. Empty
  # output (clean tree, no commits, no changes) contributes no block rather
  # than an empty fence. A non-zero exit is a tagged `:git_failed` error.
  defp run_git_block(args, header, fence) do
    case safe_git(args) do
      {:ok, {output, 0}} -> {:ok, context_block(header, fence, output)}
      {:ok, {output, status}} -> {:error, git_failed(status, output)}
      {:error, _} = error -> error
    end
  end

  defp context_block(header, fence, output) do
    case String.trim(output) do
      "" -> []
      trimmed -> ["#{header}\n```#{fence}\n#{trimmed}\n```"]
    end
  end

  # Wrap System.cmd so a missing `git` binary becomes a tagged error
  # instead of an ErlangError escaping the module. Mirrors
  # ClaudeWrapper.Worktrees. Git (like the attach globs) runs relative to
  # the current process cwd, passed explicitly via `:cd` so the working
  # directory is unambiguous.
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
