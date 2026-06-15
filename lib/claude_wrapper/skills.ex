defmodule ClaudeWrapper.Skills.Summary do
  @moduledoc """
  Lightweight metadata for one skill, returned by
  `ClaudeWrapper.Skills.list/1`.

  Strips the body and extra frontmatter to keep listings cheap.
  See `ClaudeWrapper.Skills` for how these are produced.
  """

  @enforce_keys [:dir_stem, :name, :dir_path, :file_path, :size_bytes, :has_assets]
  defstruct [:dir_stem, :name, :description, :dir_path, :file_path, :size_bytes, :has_assets]

  @type t :: %__MODULE__{
          dir_stem: String.t(),
          name: String.t(),
          description: String.t() | nil,
          dir_path: String.t(),
          file_path: String.t(),
          size_bytes: non_neg_integer(),
          has_assets: boolean()
        }
end

defmodule ClaudeWrapper.Skills.Skill do
  @moduledoc """
  Full skill record returned by `ClaudeWrapper.Skills.get/2`.

  Carries the summary fields plus the instructions `body` and any
  unknown frontmatter keys in `extra`. See `ClaudeWrapper.Skills`.
  """

  @enforce_keys [
    :dir_stem,
    :name,
    :dir_path,
    :file_path,
    :size_bytes,
    :has_assets,
    :body,
    :extra
  ]
  defstruct [
    :dir_stem,
    :name,
    :description,
    :dir_path,
    :file_path,
    :size_bytes,
    :has_assets,
    :body,
    :extra
  ]

  @type t :: %__MODULE__{
          dir_stem: String.t(),
          name: String.t(),
          description: String.t() | nil,
          dir_path: String.t(),
          file_path: String.t(),
          size_bytes: non_neg_integer(),
          has_assets: boolean(),
          body: String.t(),
          extra: %{optional(String.t()) => String.t()}
        }
end

defmodule ClaudeWrapper.Skills do
  @moduledoc """
  Read-side access to Claude Code's on-disk **skill** definitions.

  Claude Code resolves user-level skills from
  `~/.claude/skills/<dir_stem>/SKILL.md`. Unlike agents (which are flat
  `.md` files), each skill is a *directory* containing a `SKILL.md`
  plus optional bundled assets (`scripts/`, `reference/`, etc.). The
  frontmatter on `SKILL.md` carries the skill's metadata (name,
  description); the body is the skill's instructions.

  This module is read-only on purpose -- mutations (create / update /
  delete) are deferred. Creating a skill is more involved than a file
  write because it implies directory layout and optional scaffold
  assets.

  Two levels of granularity:

    * `list/1` -- enumerate every skill at the root with summary
      metadata (name, description, dir path, has_assets).
    * `get/2` -- read one skill's full record including the
      instructions body.

  ## Frontmatter format

  Real-world skills look like:

      ---
      name: recall
      description: Search mente for memories by topic, text, tags, or ranked search
      ---

      # Search mente for memories
      ...

  The parser is permissive: only `name` and `description` are typed.
  Any other `key: value` pairs land in `Skill.extra` so unknown future
  keys survive a round trip. Frontmatter is optional -- a body-only
  `SKILL.md` parses fine, with `name` defaulting to the directory stem.

  ## Stem, name, directory

  By convention a skill's `name` matches its directory name:
  `~/.claude/skills/recall/SKILL.md` carries `name: recall`. The two
  can diverge -- the parser keeps both. `get/2` looks up by directory
  stem (because that's what the filesystem indexes), not by the
  frontmatter `name`.

  ## Pointing at a different root

  The default is `~/.claude/skills`. Pass an explicit path to `at/1`
  to point at a different directory -- a temp dir in tests, a
  non-default Claude Code install. The on-disk layout
  (`<root>/<dir_stem>/SKILL.md`) is the same regardless of root.

  ## Example

      {:ok, root} = ClaudeWrapper.Skills.home()
      {:ok, summaries} = ClaudeWrapper.Skills.list(root)

      for s <- summaries do
        IO.puts("\#{s.dir_stem}: \#{s.description}")
      end

      {:ok, skill} = ClaudeWrapper.Skills.get(root, "recall")
      IO.puts(skill.body)
  """

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.Skills.{Skill, Summary}

  @skill_file "SKILL.md"

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @doc """
  Resolve the default skills root, `~/.claude/skills`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :no_home}}` when the user
  home cannot be determined.
  """
  @spec home() :: {:ok, t()} | {:error, Error.t()}
  def home do
    case System.user_home() do
      nil -> {:error, Error.new(:no_home)}
      home -> {:ok, %__MODULE__{root: Path.join([home, ".claude", "skills"])}}
    end
  end

  @doc """
  Use a specific path as the skills root. Useful for tests (point at a
  temp dir) and non-default installs.
  """
  @spec at(String.t()) :: t()
  def at(path) when is_binary(path), do: %__MODULE__{root: path}

  @doc "The configured root directory."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc """
  List every skill at the root, sorted by directory stem.

  A "skill" is any direct child directory of the root that contains a
  `SKILL.md`. Directories without `SKILL.md` and non-directory entries
  are ignored. Returns `{:ok, []}` when the root directory does not
  exist (a fresh install with no user skills). Directories whose
  `SKILL.md` fails to read are skipped rather than failing the whole
  listing.
  """
  @spec list(t()) :: {:ok, [Summary.t()]} | {:error, Error.t()}
  def list(%__MODULE__{} = s) do
    case File.ls(s.root) do
      {:ok, names} ->
        summaries =
          names
          |> Enum.map(&summarize(s, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.dir_stem)

        {:ok, summaries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end

  @doc """
  Read one skill by directory stem (the basename of the `<dir_stem>/`
  directory under the root) into a full `Skill`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :not_found}}` when no such
  directory exists or it has no `SKILL.md`.
  """
  @spec get(t(), String.t()) :: {:ok, Skill.t()} | {:error, Error.t()}
  def get(%__MODULE__{} = s, dir_stem) when is_binary(dir_stem) do
    dir = Path.join(s.root, dir_stem)
    path = Path.join(dir, @skill_file)

    case File.read(path) do
      {:ok, raw} -> {:ok, parse_skill(raw, dir_stem, dir, path)}
      {:error, :enoent} -> {:error, Error.new(:not_found, reason: dir_stem)}
      {:error, reason} -> {:error, Error.io(reason)}
    end
  end

  # -- read helpers --------------------------------------------------

  defp summarize(%__MODULE__{} = s, name) do
    dir = Path.join(s.root, name)
    path = Path.join(dir, @skill_file)

    if File.dir?(dir) and File.regular?(path) do
      summarize_file(name, dir, path)
    end
  end

  defp summarize_file(name, dir, path) do
    case File.read(path) do
      {:ok, raw} -> to_summary(parse_skill(raw, name, dir, path))
      {:error, _} -> nil
    end
  end

  defp to_summary(%Skill{} = skill) do
    %Summary{
      dir_stem: skill.dir_stem,
      name: skill.name,
      description: skill.description,
      dir_path: skill.dir_path,
      file_path: skill.file_path,
      size_bytes: skill.size_bytes,
      has_assets: skill.has_assets
    }
  end

  defp parse_skill(raw, dir_stem, dir, path) do
    {frontmatter, body} = split_frontmatter(raw)
    fields = parse_frontmatter(frontmatter, dir_stem)

    %Skill{
      dir_stem: dir_stem,
      name: fields.name,
      description: fields.description,
      dir_path: dir,
      file_path: path,
      size_bytes: byte_size(raw),
      has_assets: directory_has_assets(dir),
      body: String.trim(body),
      extra: fields.extra
    }
  end

  defp parse_frontmatter(nil, dir_stem), do: empty_fields(dir_stem)

  defp parse_frontmatter(frontmatter, dir_stem) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(empty_fields(dir_stem), &apply_frontmatter_line/2)
  end

  defp empty_fields(dir_stem) do
    %{name: dir_stem, description: nil, extra: %{}}
  end

  defp apply_frontmatter_line(line, fields) do
    case parse_kv(line) do
      {key, value} -> apply_kv(fields, key, value)
      :skip -> fields
    end
  end

  # Split a "key: value" line. Skips blank lines, lines without a
  # colon, and lines whose key is empty.
  defp parse_kv(line) do
    trimmed = String.trim(line)

    case String.split(trimmed, ":", parts: 2) do
      [key, value] -> kv_or_skip(String.trim(key), String.trim(value))
      _ -> :skip
    end
  end

  defp kv_or_skip("", _value), do: :skip
  defp kv_or_skip(key, value), do: {key, value}

  defp apply_kv(fields, _key, ""), do: fields
  defp apply_kv(fields, "name", value), do: %{fields | name: value}
  defp apply_kv(fields, "description", value), do: %{fields | description: value}

  defp apply_kv(fields, key, value) do
    %{fields | extra: Map.put(fields.extra, key, value)}
  end

  # Split a markdown file into `{frontmatter_or_nil, body}`. Frontmatter
  # is delimited by a leading `---` line and a closing `---` line. An
  # opening `---` with no matching close is treated conservatively as
  # no frontmatter, returning `{nil, raw}`.
  defp split_frontmatter(raw) do
    case String.split(raw, "\n") do
      ["---" | rest] -> split_after_open(rest, raw)
      _ -> {nil, raw}
    end
  end

  defp split_after_open(lines, raw) do
    case Enum.split_while(lines, &(&1 != "---")) do
      {_fm, []} -> {nil, raw}
      {fm_lines, ["---" | body_lines]} -> {Enum.join(fm_lines, "\n"), Enum.join(body_lines, "\n")}
    end
  end

  # True when the skill directory holds any entry besides `SKILL.md`.
  defp directory_has_assets(dir) do
    case File.ls(dir) do
      {:ok, names} -> Enum.any?(names, &(&1 != @skill_file))
      {:error, _} -> false
    end
  end
end
