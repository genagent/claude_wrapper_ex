defmodule ClaudeWrapper.Agents.Summary do
  @moduledoc """
  Lightweight metadata for one agent definition, returned by
  `ClaudeWrapper.Agents.list/1`.

  Strips the prompt body and extra frontmatter to keep listings cheap.
  See `ClaudeWrapper.Agents` for how these are produced.
  """

  @enforce_keys [:file_stem, :name, :tools, :file_path, :size_bytes]
  defstruct [:file_stem, :name, :description, :tools, :model, :file_path, :size_bytes]

  @type t :: %__MODULE__{
          file_stem: String.t(),
          name: String.t(),
          description: String.t() | nil,
          tools: [String.t()],
          model: String.t() | nil,
          file_path: String.t(),
          size_bytes: non_neg_integer()
        }
end

defmodule ClaudeWrapper.Agents.Definition do
  @moduledoc """
  Full agent definition returned by `ClaudeWrapper.Agents.get/2`.

  Carries the summary fields plus the prompt `body` and any unknown
  frontmatter keys in `extra`. See `ClaudeWrapper.Agents`.
  """

  @enforce_keys [:file_stem, :name, :tools, :file_path, :size_bytes, :body, :extra]
  defstruct [
    :file_stem,
    :name,
    :description,
    :tools,
    :model,
    :file_path,
    :size_bytes,
    :body,
    :extra
  ]

  @type t :: %__MODULE__{
          file_stem: String.t(),
          name: String.t(),
          description: String.t() | nil,
          tools: [String.t()],
          model: String.t() | nil,
          file_path: String.t(),
          size_bytes: non_neg_integer(),
          body: String.t(),
          extra: %{optional(String.t()) => String.t()}
        }
end

defmodule ClaudeWrapper.Agents do
  @moduledoc """
  File-backed read/write access to Claude Code's on-disk **agent**
  definitions.

  Claude Code resolves user-level agents from
  `~/.claude/agents/<stem>.md`. Each file is plain markdown with a
  YAML-style frontmatter block delimited by `---` lines. The
  frontmatter carries the agent's metadata (name, description, optional
  tool allow-list, optional model); the body is the agent's system
  prompt.

  This is distinct from `ClaudeWrapper.Commands.Agents`, which shells
  out to `claude agents`. This module reads and writes the files
  directly.

  Two levels of granularity for reads:

    * `list/1` -- enumerate every agent at the root with summary
      metadata (name, description, tools, model, file path).
    * `get/2` -- read one agent's full record including the prompt body
      and unknown frontmatter keys.

  Plus `write/3`, `write_new/3`, and `delete/2` for mutations.

  ## Frontmatter format

  Real-world agents look like:

      ---
      name: auditor
      description: Multi-line folded description...
      tools: Read, Glob, Grep, Bash
      model: sonnet
      ---

      You are an auditor. ...

  The parser is permissive: only `name`, `description`, `tools`, and
  `model` are typed. `tools` is a comma-separated list. Any other
  `key: value` pairs land in `Definition.extra` so unknown future keys
  survive a round trip. Frontmatter is optional -- a body-only file
  parses fine, with `name` defaulting to the file stem.

  List-valued and folded frontmatter keys (anything this parser cannot
  reduce to a single inline scalar) are tolerated by capturing their
  raw inline value into `extra` rather than failing the parse.

  ## File stem vs name

  By convention an agent's `name` matches its filename stem:
  `auditor.md` carries `name: auditor`. The two can diverge -- the
  parser keeps both. Lookup, write, and delete all key on the file
  stem (that's what the filesystem indexes), not the frontmatter
  `name`.

  ## Example

      {:ok, root} = ClaudeWrapper.Agents.home()
      {:ok, summaries} = ClaudeWrapper.Agents.list(root)

      for s <- summaries do
        IO.puts("\#{s.file_stem}: \#{s.description}")
      end

      {:ok, agent} = ClaudeWrapper.Agents.get(root, "auditor")
      IO.puts(agent.body)
  """

  alias ClaudeWrapper.Agents.{Definition, Summary}
  alias ClaudeWrapper.Error

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @typedoc """
  Attributes for `write/3` and `write_new/3`.

  A keyword list or map. All keys are optional:

    * `:name` -- frontmatter `name`; defaults to the file stem
    * `:description` -- frontmatter `description`
    * `:tools` -- list of tool names, rendered comma-joined
    * `:model` -- frontmatter `model`
    * `:body` -- the agent prompt body
    * `:extra` -- map of additional frontmatter `key => string` pairs,
      rendered in sorted order after the typed keys
  """
  @type attrs :: Enumerable.t()

  @doc """
  Resolve the default agents root, `~/.claude/agents`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :no_home}}` when the user
  home cannot be determined.
  """
  @spec home() :: {:ok, t()} | {:error, Error.t()}
  def home do
    case System.user_home() do
      nil -> {:error, Error.new(:no_home)}
      home -> {:ok, %__MODULE__{root: Path.join([home, ".claude", "agents"])}}
    end
  end

  @doc """
  Use a specific path as the agents root. Useful for tests (point at a
  temp dir) and non-default installs.
  """
  @spec at(String.t()) :: t()
  def at(path) when is_binary(path), do: %__MODULE__{root: path}

  @doc "The configured root directory."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc """
  List every `*.md` agent at the root, sorted by file stem.

  Returns `{:ok, []}` when the root directory does not exist (a fresh
  install with no user agents). Files that fail to parse are skipped
  rather than failing the whole listing.
  """
  @spec list(t()) :: {:ok, [Summary.t()]} | {:error, Error.t()}
  def list(%__MODULE__{} = a) do
    case File.ls(a.root) do
      {:ok, names} ->
        summaries =
          names
          |> Enum.filter(&String.ends_with?(&1, ".md"))
          |> Enum.map(&summarize(a, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.file_stem)

        {:ok, summaries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end

  @doc """
  Read one agent by file stem (the basename of `<stem>.md` under the
  root) into a full `Definition`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :not_found}}` when no such
  file exists.
  """
  @spec get(t(), String.t()) :: {:ok, Definition.t()} | {:error, Error.t()}
  def get(%__MODULE__{} = a, file_stem) when is_binary(file_stem) do
    path = agent_path(a, file_stem)

    case File.read(path) do
      {:ok, raw} -> {:ok, parse_agent(raw, file_stem, path)}
      {:error, :enoent} -> {:error, Error.new(:not_found, reason: file_stem)}
      {:error, reason} -> {:error, Error.io(reason)}
    end
  end

  @doc """
  Write (create or overwrite) an agent at `<file_stem>.md`.

  Creates the agents root directory if it does not exist. See `t:attrs/0`
  for the accepted attributes. To fail when the agent already exists
  instead of overwriting, use `write_new/3`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :invalid_stem}}` (with the
  stem in `:reason`) for empty, `.`, `..`, or stems containing slashes
  or NUL bytes.
  """
  @spec write(t(), String.t(), attrs()) :: :ok | {:error, Error.t()}
  def write(%__MODULE__{} = a, file_stem, attrs) when is_binary(file_stem) do
    write_inner(a, file_stem, attrs, true)
  end

  @doc """
  Like `write/3` but returns `{:error, %ClaudeWrapper.Error{kind:
  :already_exists}}` when the agent already exists. Useful for
  create-only flows where overwriting would be a bug.
  """
  @spec write_new(t(), String.t(), attrs()) :: :ok | {:error, Error.t()}
  def write_new(%__MODULE__{} = a, file_stem, attrs) when is_binary(file_stem) do
    write_inner(a, file_stem, attrs, false)
  end

  @doc """
  Remove the `<file_stem>.md` agent.

  Returns `{:error, %ClaudeWrapper.Error{kind: :not_found}}` when no such
  file exists.
  """
  @spec delete(t(), String.t()) :: :ok | {:error, Error.t()}
  def delete(%__MODULE__{} = a, file_stem) when is_binary(file_stem) do
    with :ok <- validate_stem(file_stem) do
      case File.rm(agent_path(a, file_stem)) do
        :ok -> :ok
        {:error, :enoent} -> {:error, Error.new(:not_found, reason: file_stem)}
        {:error, reason} -> {:error, Error.io(reason)}
      end
    end
  end

  # -- write helpers -------------------------------------------------

  defp write_inner(%__MODULE__{} = a, file_stem, attrs, allow_overwrite) do
    fields = normalize_attrs(attrs)

    with :ok <- validate_stem(file_stem),
         path = agent_path(a, file_stem),
         :ok <- guard_overwrite(path, file_stem, allow_overwrite),
         :ok <- mkdir_p(a.root) do
      write_file(path, render_markdown(file_stem, fields))
    end
  end

  defp guard_overwrite(_path, _stem, true), do: :ok

  defp guard_overwrite(path, stem, false) do
    if File.exists?(path), do: {:error, Error.new(:already_exists, reason: stem)}, else: :ok
  end

  defp mkdir_p(root) do
    case File.mkdir_p(root) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.io(reason)}
    end
  end

  defp write_file(path, contents) do
    case File.write(path, contents) do
      :ok -> :ok
      {:error, reason} -> {:error, Error.io(reason)}
    end
  end

  defp normalize_attrs(attrs) do
    map = Map.new(attrs)

    %{
      name: get_attr(map, :name),
      description: get_attr(map, :description),
      tools: Map.get(map, :tools) || [],
      model: get_attr(map, :model),
      body: get_attr(map, :body) || "",
      extra: Map.get(map, :extra) || %{}
    }
  end

  # Look up an attr by atom or string key, normalizing "" to nil.
  defp get_attr(map, key) do
    case Map.get(map, key) || Map.get(map, Atom.to_string(key)) do
      "" -> nil
      value -> value
    end
  end

  defp render_markdown(file_stem, fields) do
    name = fields.name || file_stem

    frontmatter =
      ["name: #{name}"]
      |> append_scalar("description", fields.description)
      |> append_tools(fields.tools)
      |> append_scalar("model", fields.model)
      |> append_extra(fields.extra)

    header = "---\n" <> Enum.join(frontmatter, "\n") <> "\n---\n\n"
    header <> String.trim(fields.body) <> "\n"
  end

  defp append_scalar(lines, _key, nil), do: lines
  defp append_scalar(lines, key, value), do: lines ++ ["#{key}: #{value}"]

  defp append_tools(lines, []), do: lines
  defp append_tools(lines, tools), do: lines ++ ["tools: #{Enum.join(tools, ", ")}"]

  defp append_extra(lines, extra) do
    extra
    |> Enum.sort_by(fn {k, _v} -> to_string(k) end)
    |> Enum.reduce(lines, fn {k, v}, acc -> acc ++ ["#{k}: #{v}"] end)
  end

  # -- read helpers --------------------------------------------------

  defp summarize(%__MODULE__{} = a, name) do
    file_stem = Path.basename(name, ".md")
    path = agent_path(a, file_stem)

    case File.read(path) do
      {:ok, raw} -> to_summary(parse_agent(raw, file_stem, path))
      {:error, _} -> nil
    end
  end

  defp to_summary(%Definition{} = d) do
    %Summary{
      file_stem: d.file_stem,
      name: d.name,
      description: d.description,
      tools: d.tools,
      model: d.model,
      file_path: d.file_path,
      size_bytes: d.size_bytes
    }
  end

  defp parse_agent(raw, file_stem, path) do
    {frontmatter, body} = split_frontmatter(raw)
    fields = parse_frontmatter(frontmatter, file_stem)

    %Definition{
      file_stem: file_stem,
      name: fields.name,
      description: fields.description,
      tools: fields.tools,
      model: fields.model,
      file_path: path,
      size_bytes: byte_size(raw),
      body: String.trim(body),
      extra: fields.extra
    }
  end

  defp parse_frontmatter(nil, file_stem), do: empty_fields(file_stem)

  defp parse_frontmatter(frontmatter, file_stem) do
    frontmatter
    |> String.split("\n")
    |> Enum.reduce(empty_fields(file_stem), &apply_frontmatter_line/2)
  end

  defp empty_fields(file_stem) do
    %{name: file_stem, description: nil, tools: [], model: nil, extra: %{}}
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
  defp apply_kv(fields, "tools", value), do: %{fields | tools: parse_tools(value)}
  defp apply_kv(fields, "model", value), do: %{fields | model: value}

  defp apply_kv(fields, key, value) do
    %{fields | extra: Map.put(fields.extra, key, value)}
  end

  defp parse_tools(value) do
    value
    |> String.split(",")
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
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

  defp agent_path(%__MODULE__{root: root}, file_stem) do
    Path.join(root, file_stem <> ".md")
  end

  defp validate_stem(stem) when stem in ["", ".", ".."],
    do: {:error, Error.new(:invalid_stem, reason: stem)}

  defp validate_stem(stem) do
    if String.contains?(stem, ["/", "\\", "\0"]) do
      {:error, Error.new(:invalid_stem, reason: stem)}
    else
      :ok
    end
  end
end
