defmodule ClaudeWrapper.History.ProjectSummary do
  @moduledoc """
  Summary of one project directory under the history root.

  See `ClaudeWrapper.History` for how these are produced.
  """

  @enforce_keys [:slug, :decoded_path, :decode_verified?, :session_count, :last_modified]
  defstruct [:slug, :decoded_path, :decode_verified?, :session_count, :last_modified]

  @type t :: %__MODULE__{
          slug: String.t(),
          decoded_path: String.t(),
          decode_verified?: boolean(),
          session_count: non_neg_integer(),
          last_modified: DateTime.t() | nil
        }
end

defmodule ClaudeWrapper.History.SessionSummary do
  @moduledoc """
  Summary of one session `.jsonl` file.

  See `ClaudeWrapper.History` for how these are produced.
  """

  @enforce_keys [:session_id, :project_slug, :message_count, :size_bytes]
  defstruct [
    :session_id,
    :project_slug,
    :message_count,
    :first_timestamp,
    :last_timestamp,
    :title,
    :first_user_preview,
    :total_cost_usd,
    :total_tokens,
    :size_bytes
  ]

  @type t :: %__MODULE__{
          session_id: String.t(),
          project_slug: String.t(),
          message_count: non_neg_integer(),
          first_timestamp: String.t() | nil,
          last_timestamp: String.t() | nil,
          title: String.t() | nil,
          first_user_preview: String.t() | nil,
          total_cost_usd: float() | nil,
          total_tokens: non_neg_integer() | nil,
          size_bytes: non_neg_integer()
        }
end

defmodule ClaudeWrapper.History.SessionLog do
  @moduledoc """
  A fully parsed session: an ordered list of `t:ClaudeWrapper.History.entry/0`.
  """

  @enforce_keys [:session_id, :project_slug, :entries]
  defstruct [:session_id, :project_slug, :entries]

  @type t :: %__MODULE__{
          session_id: String.t(),
          project_slug: String.t(),
          entries: [ClaudeWrapper.History.entry()]
        }
end

defmodule ClaudeWrapper.History do
  @moduledoc """
  Read-side access to Claude Code's on-disk session history.

  Claude Code stores per-project session logs as line-delimited JSON
  under `~/.claude/projects/<slug>/<session_id>.jsonl`, one JSON object
  per line. This module gives a typed Elixir API over those logs
  without prescribing a representation for the conversation -- callers
  render however they want.

  Three levels of granularity:

    * `list_projects/2` -- enumerate project directories with summary
      metadata (session count, latest activity).
    * `list_sessions/2` -- enumerate session files (all projects, or one
      via the `:slug` option) with summary metadata.
    * `read_session/2` -- parse a session into typed
      `t:entry/0` values.

  ## Liberal parsing

  Each line is parsed independently; malformed lines are skipped rather
  than failing the whole session. Unknown entry types come through as
  `{:other, type_tag, raw}` so callers can inspect them. Only `user` and
  `assistant` get typed variants; `queue-operation`, `attachment`,
  `ai-title`, `last-prompt`, and future types land in `:other`.

  ## Slug encoding

  Project directory names are filesystem-safe encodings of an absolute
  path: every `/` and `.` becomes `-` (so `/Users/josh/Code/foo` becomes
  `-Users-josh-Code-foo`). `project_slug/1` is the forward derivation
  (canonicalize + encode); `ProjectSummary.decoded_path` is a best-effort
  inverse that anchors on the real filesystem to disambiguate literal
  hyphens in directory names.

  ## Example

      {:ok, root} = ClaudeWrapper.History.home()
      {:ok, projects} = ClaudeWrapper.History.list_projects(root)

      for p <- projects do
        {:ok, sessions} = ClaudeWrapper.History.list_sessions(root, slug: p.slug)
        IO.puts("\#{p.slug}: \#{length(sessions)} sessions")
      end
  """

  alias ClaudeWrapper.Error
  alias ClaudeWrapper.History.{ProjectSummary, SessionLog, SessionSummary}

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @typedoc "Sort order for the listing functions."
  @type sort :: :name_asc | :recency_desc

  @typedoc """
  Options for the listing functions.

    * `:limit` -- max items after sorting + offset (`nil` = no cap)
    * `:offset` -- skip the first N items (default `0`)
    * `:include_empty` -- keep projects/sessions with no activity
      (default `true`)
    * `:sort` -- `:name_asc` (default) or `:recency_desc`
    * `:slug` -- (sessions only) restrict to one project
  """
  @type list_opt ::
          {:limit, non_neg_integer() | nil}
          | {:offset, non_neg_integer()}
          | {:include_empty, boolean()}
          | {:sort, sort()}
          | {:slug, String.t() | nil}

  @typedoc "A `user` entry's fields."
  @type user_entry :: %{
          uuid: String.t() | nil,
          timestamp: String.t() | nil,
          cwd: String.t() | nil,
          git_branch: String.t() | nil,
          message: term()
        }

  @typedoc "An `assistant` entry's fields."
  @type assistant_entry :: %{
          uuid: String.t() | nil,
          timestamp: String.t() | nil,
          message: term()
        }

  @typedoc """
  One parsed line from a session `.jsonl`.

  `:user` and `:assistant` carry typed fields; every other entry type
  is `{:other, type_tag, raw}` with the raw decoded JSON map.
  """
  @type entry ::
          {:user, user_entry()}
          | {:assistant, assistant_entry()}
          | {:other, String.t(), map()}

  @max_link_hops 64
  @preview_chars 160

  @doc """
  Resolve the default history root, `~/.claude/projects`.

  Returns `{:error, %ClaudeWrapper.Error{kind: :no_home}}` when the user
  home cannot be determined.
  """
  @spec home() :: {:ok, t()} | {:error, Error.t()}
  def home do
    case System.user_home() do
      nil -> {:error, Error.new(:no_home)}
      home -> {:ok, %__MODULE__{root: Path.join([home, ".claude", "projects"])}}
    end
  end

  @doc """
  Use a specific path as the projects root. Useful for tests (point at a
  temp dir) and non-default installs.
  """
  @spec at(String.t()) :: t()
  def at(path) when is_binary(path), do: %__MODULE__{root: path}

  @doc "The configured root directory."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc """
  List project directories with optional filter / sort / pagination.

  Returns `{:ok, []}` when the root directory does not exist. See
  `t:list_opt/0` for options.
  """
  @spec list_projects(t(), [list_opt()]) :: {:ok, [ProjectSummary.t()]} | {:error, Error.t()}
  def list_projects(%__MODULE__{} = h, opts \\ []) do
    case File.ls(h.root) do
      {:ok, names} ->
        projects =
          names
          |> Enum.map(fn name -> {name, Path.join(h.root, name)} end)
          |> Enum.filter(fn {_n, path} -> File.dir?(path) end)
          |> Enum.map(fn {name, path} -> summarize_project(path, name) end)
          |> maybe_drop_empty(Keyword.get(opts, :include_empty, true), & &1.session_count)
          |> sort_projects(Keyword.get(opts, :sort, :name_asc))
          |> paginate(opts)

        {:ok, projects}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, Error.io(reason)}
    end
  end

  @doc """
  List sessions, optionally restricted to one project via the `:slug`
  option, with filter / sort / pagination.

  When no `:slug` is given, every project directory is unioned.
  """
  @spec list_sessions(t(), [list_opt()]) :: {:ok, [SessionSummary.t()]} | {:error, Error.t()}
  def list_sessions(%__MODULE__{} = h, opts \\ []) do
    with {:ok, dirs} <- session_dirs(h, Keyword.get(opts, :slug)) do
      sessions =
        dirs
        |> Enum.flat_map(&sessions_in_dir/1)
        |> maybe_drop_empty(Keyword.get(opts, :include_empty, true), & &1.message_count)
        |> sort_sessions(Keyword.get(opts, :sort, :name_asc))
        |> paginate(opts)

      {:ok, sessions}
    end
  end

  @doc """
  List sessions for a working directory, deriving its project slug via
  `project_slug/1`. Convenience over `list_sessions(h, slug: ...)`.
  """
  @spec sessions_for_path(t(), String.t(), [list_opt()]) ::
          {:ok, [SessionSummary.t()]} | {:error, Error.t()}
  def sessions_for_path(%__MODULE__{} = h, cwd, opts \\ []) when is_binary(cwd) do
    list_sessions(h, Keyword.put(opts, :slug, project_slug(cwd)))
  end

  @doc """
  Read one session's full entry log, searching every project directory
  for `<session_id>.jsonl`. Malformed lines are skipped.

  Returns `{:error, %ClaudeWrapper.Error{kind: :not_found}}` when no
  session file matches.
  """
  @spec read_session(t(), String.t()) :: {:ok, SessionLog.t()} | {:error, Error.t()}
  def read_session(%__MODULE__{} = h, session_id) when is_binary(session_id) do
    case find_session(h, session_id) do
      {:ok, {path, slug}} -> {:ok, parse_session(path, session_id, slug)}
      {:error, _} = err -> err
    end
  end

  @doc """
  Locate the on-disk path and project slug for a session id, searching
  every project directory.

  Returns `{:ok, {path, slug}}` or `{:error, %ClaudeWrapper.Error{kind:
  :not_found}}`.
  """
  @spec find_session(t(), String.t()) ::
          {:ok, {String.t(), String.t()}} | {:error, Error.t()}
  def find_session(%__MODULE__{} = h, session_id) when is_binary(session_id) do
    with {:ok, projects} <- list_projects(h) do
      Enum.find_value(
        projects,
        {:error, Error.new(:not_found, reason: session_id)},
        &session_in_project(h, &1, session_id)
      )
    end
  end

  defp session_in_project(%__MODULE__{} = h, project, session_id) do
    candidate = Path.join([h.root, project.slug, session_id <> ".jsonl"])
    if File.regular?(candidate), do: {:ok, {candidate, project.slug}}
  end

  @doc """
  Derive Claude Code's project-directory slug for a filesystem path,
  matching the CLI: the path is canonicalized (best-effort symlink
  resolution) and then every `/` and `.` is encoded as `-`.

  This is the reliable way to locate the project directory for a working
  directory -- see `sessions_for_path/3`. Falls back to the expanded path
  when it cannot be canonicalized.
  """
  @spec project_slug(String.t()) :: String.t()
  def project_slug(path) when is_binary(path) do
    path |> canonical_path() |> encode_path_slug()
  end

  # -- project / session summaries -----------------------------------

  defp summarize_project(dir, slug) do
    {count, last_modified} =
      case File.ls(dir) do
        {:ok, names} ->
          names
          |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
          |> Enum.reduce({0, nil}, fn name, {n, latest} ->
            {n + 1, max_mtime(Path.join(dir, name), latest)}
          end)

        {:error, _} ->
          {0, nil}
      end

    {decoded_path, verified?} = decode_slug_anchored(slug)

    %ProjectSummary{
      slug: slug,
      decoded_path: decoded_path,
      decode_verified?: verified?,
      session_count: count,
      last_modified: last_modified
    }
  end

  defp sessions_in_dir(dir) do
    slug = Path.basename(dir)

    case File.ls(dir) do
      {:ok, names} ->
        names
        |> Enum.filter(&String.ends_with?(&1, ".jsonl"))
        |> Enum.map(fn name ->
          summarize_session(Path.join(dir, name), Path.basename(name, ".jsonl"), slug)
        end)
        |> Enum.reject(&is_nil/1)

      {:error, _} ->
        []
    end
  end

  defp summarize_session(path, session_id, slug) do
    case File.stat(path) do
      {:ok, %File.Stat{size: size}} ->
        acc =
          path
          |> stream_lines()
          |> Enum.reduce(empty_summary_acc(), &fold_summary_line/2)

        %SessionSummary{
          session_id: session_id,
          project_slug: slug,
          message_count: acc.message_count,
          first_timestamp: acc.first_timestamp,
          last_timestamp: acc.last_timestamp,
          title: acc.title,
          first_user_preview: acc.first_user_preview,
          total_cost_usd: acc.total_cost_usd,
          total_tokens: acc.total_tokens,
          size_bytes: size
        }

      {:error, _} ->
        nil
    end
  end

  defp empty_summary_acc do
    %{
      message_count: 0,
      first_timestamp: nil,
      last_timestamp: nil,
      title: nil,
      first_user_preview: nil,
      total_cost_usd: nil,
      total_tokens: nil
    }
  end

  defp fold_summary_line(line, acc) do
    case decode_line(line) do
      {:ok, map} -> acc |> apply_summary_type(map) |> track_timestamps(map)
      :error -> acc
    end
  end

  defp apply_summary_type(acc, %{"type" => "user"} = map) do
    acc = %{acc | message_count: acc.message_count + 1}

    if acc.first_user_preview == nil do
      %{acc | first_user_preview: user_text_preview(map)}
    else
      acc
    end
  end

  defp apply_summary_type(acc, %{"type" => "assistant"} = map) do
    usage = get_in(map, ["message", "usage"]) || %{}

    %{
      acc
      | message_count: acc.message_count + 1,
        total_cost_usd: add_cost(acc.total_cost_usd, usage),
        total_tokens: add_tokens(acc.total_tokens, usage)
    }
  end

  defp apply_summary_type(acc, %{"type" => "ai-title"} = map) do
    case map["aiTitle"] || map["title"] do
      t when is_binary(t) and t != "" -> %{acc | title: t}
      _ -> acc
    end
  end

  defp apply_summary_type(acc, _map), do: acc

  defp track_timestamps(acc, map) do
    case map["timestamp"] do
      ts when is_binary(ts) ->
        %{acc | first_timestamp: acc.first_timestamp || ts, last_timestamp: ts}

      _ ->
        acc
    end
  end

  defp add_cost(current, usage) do
    case usage["total_cost_usd"] do
      c when is_number(c) -> (current || 0.0) + c
      _ -> current
    end
  end

  defp add_tokens(current, usage) do
    sum =
      ["input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens"]
      |> Enum.reduce(0, fn k, t ->
        case usage[k] do
          n when is_integer(n) -> t + n
          _ -> t
        end
      end)

    if sum > 0, do: (current || 0) + sum, else: current
  end

  defp user_text_preview(%{"message" => %{"content" => content}}) do
    raw =
      cond do
        is_binary(content) ->
          content

        is_list(content) ->
          content |> Enum.map(&text_block/1) |> Enum.reject(&(&1 == "")) |> Enum.join(" ")

        true ->
          ""
      end

    one_line =
      raw
      |> String.split("\n")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.join(" ")

    cond do
      one_line == "" ->
        nil

      String.length(one_line) > @preview_chars ->
        String.slice(one_line, 0, @preview_chars) <> "..."

      true ->
        one_line
    end
  end

  defp user_text_preview(_), do: nil

  defp text_block(%{"type" => "text", "text" => t}) when is_binary(t), do: t
  defp text_block(_), do: ""

  # -- full session parse --------------------------------------------

  defp parse_session(path, session_id, slug) do
    entries =
      path
      |> stream_lines()
      |> Enum.map(&decode_line/1)
      |> Enum.flat_map(fn
        {:ok, map} -> [parse_entry(map)]
        :error -> []
      end)

    %SessionLog{session_id: session_id, project_slug: slug, entries: entries}
  end

  defp parse_entry(%{"type" => "user"} = map) do
    {:user,
     %{
       uuid: map["uuid"],
       timestamp: map["timestamp"],
       cwd: map["cwd"],
       git_branch: map["gitBranch"],
       message: Map.get(map, "message")
     }}
  end

  defp parse_entry(%{"type" => "assistant"} = map) do
    {:assistant,
     %{
       uuid: map["uuid"],
       timestamp: map["timestamp"],
       message: Map.get(map, "message")
     }}
  end

  defp parse_entry(map) do
    {:other, to_string(Map.get(map, "type", "")), map}
  end

  # -- slug encode / decode ------------------------------------------

  defp encode_path_slug(path), do: String.replace(path, ["/", "."], "-")

  # Decode a slug back to a path, anchoring on the real filesystem to
  # disambiguate literal hyphens in directory names. Returns
  # `{decoded_path, verified?}`.
  defp decode_slug_anchored(slug) do
    body = String.replace_prefix(slug, "-", "")

    case String.split(body, "-") do
      [first | rest] -> walk_segments(rest, "/", first, true)
      [] -> {"/", true}
    end
  end

  defp walk_segments([], built, current, verified?) do
    {Path.join(built, current), verified?}
  end

  defp walk_segments([next | rest], built, current, verified?) do
    hyphen = current <> "-" <> next

    if File.exists?(Path.join(built, hyphen)) do
      walk_segments(rest, built, hyphen, verified?)
    else
      verified? = verified? and File.exists?(Path.join(built, current))
      walk_segments(rest, Path.join(built, current), next, verified?)
    end
  end

  # Best-effort canonicalization: absolutize, then resolve symlinks
  # component by component (handles e.g. /var -> /private/var on macOS).
  defp canonical_path(path), do: path |> Path.expand() |> follow_links(0)

  defp follow_links(path, hops) when hops > @max_link_hops, do: path

  defp follow_links(path, hops) do
    path
    |> Path.split()
    |> Enum.reduce("/", fn seg, acc -> resolve_segment(seg, acc, hops) end)
  end

  defp resolve_segment("/", acc, _hops), do: acc

  defp resolve_segment(seg, acc, hops) do
    candidate = Path.join(acc, seg)

    case File.read_link(candidate) do
      {:ok, target} -> follow_links(Path.expand(resolve_target(target, acc)), hops + 1)
      _ -> candidate
    end
  end

  defp resolve_target(target, acc) do
    if Path.type(target) == :absolute, do: target, else: Path.join(acc, target)
  end

  # -- shared list helpers -------------------------------------------

  defp session_dirs(%__MODULE__{} = h, nil) do
    with {:ok, projects} <- list_projects(h, include_empty: true) do
      {:ok, Enum.map(projects, &Path.join(h.root, &1.slug))}
    end
  end

  defp session_dirs(%__MODULE__{} = h, slug) when is_binary(slug),
    do: {:ok, [Path.join(h.root, slug)]}

  defp maybe_drop_empty(items, true, _count_fun), do: items
  defp maybe_drop_empty(items, false, count_fun), do: Enum.reject(items, &(count_fun.(&1) == 0))

  defp sort_projects(items, :name_asc), do: Enum.sort_by(items, & &1.slug)

  defp sort_projects(items, :recency_desc) do
    Enum.sort(items, fn a, b -> recency_desc(a.last_modified, b.last_modified, a.slug, b.slug) end)
  end

  defp sort_sessions(items, :name_asc), do: Enum.sort_by(items, & &1.session_id)

  defp sort_sessions(items, :recency_desc) do
    Enum.sort(items, fn a, b ->
      recency_desc(a.last_timestamp, b.last_timestamp, a.session_id, b.session_id)
    end)
  end

  # `a` precedes `b` when it is more recent. nil sorts to the tail.
  defp recency_desc(nil, nil, a_tie, b_tie), do: a_tie <= b_tie
  defp recency_desc(nil, _b, _a_tie, _b_tie), do: false
  defp recency_desc(_a, nil, _a_tie, _b_tie), do: true

  defp recency_desc(a, b, a_tie, b_tie) do
    case compare_recency(a, b) do
      :gt -> true
      :lt -> false
      :eq -> a_tie <= b_tie
    end
  end

  defp compare_recency(%DateTime{} = a, %DateTime{} = b), do: DateTime.compare(a, b)

  defp compare_recency(a, b) when is_binary(a) and is_binary(b) do
    cond do
      a > b -> :gt
      a < b -> :lt
      true -> :eq
    end
  end

  defp paginate(items, opts) do
    items = Enum.drop(items, Keyword.get(opts, :offset, 0))

    case Keyword.get(opts, :limit) do
      nil -> items
      limit when is_integer(limit) -> Enum.take(items, limit)
    end
  end

  # -- io helpers ----------------------------------------------------

  defp stream_lines(path), do: File.stream!(path)

  defp decode_line(line) do
    case String.trim(line) do
      "" -> :error
      trimmed -> Jason.decode(trimmed) |> normalize_decode()
    end
  end

  defp normalize_decode({:ok, map}) when is_map(map), do: {:ok, map}
  defp normalize_decode(_), do: :error

  defp max_mtime(path, latest) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) ->
        dt = DateTime.from_unix!(mtime)
        if latest == nil or DateTime.compare(dt, latest) == :gt, do: dt, else: latest

      _ ->
        latest
    end
  end
end
