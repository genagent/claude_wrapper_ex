defmodule ClaudeWrapper.Jobs.Summary do
  @moduledoc """
  Cheap metadata view of one background job, returned by
  `ClaudeWrapper.Jobs.list/1`. Stripped of the timeline.

  See `ClaudeWrapper.Jobs` for how these are produced and where each
  field comes from in the on-disk `state.json`.
  """

  @enforce_keys [:short_id, :state]
  defstruct [
    :short_id,
    :state,
    :daemon_short,
    :backend,
    :name,
    :detail,
    :intent,
    :session_id,
    :session_path,
    :cwd,
    :origin_cwd,
    :created_at,
    :updated_at,
    :first_terminal_at,
    :cli_version,
    :state_mtime_secs
  ]

  @type t :: %__MODULE__{
          short_id: String.t(),
          state: String.t(),
          daemon_short: String.t() | nil,
          backend: String.t() | nil,
          name: String.t() | nil,
          detail: String.t() | nil,
          intent: String.t() | nil,
          session_id: String.t() | nil,
          session_path: String.t() | nil,
          cwd: String.t() | nil,
          origin_cwd: String.t() | nil,
          created_at: String.t() | nil,
          updated_at: String.t() | nil,
          first_terminal_at: String.t() | nil,
          cli_version: String.t() | nil,
          state_mtime_secs: non_neg_integer() | nil
        }
end

defmodule ClaudeWrapper.Jobs.Event do
  @moduledoc """
  One timeline event from a job's `timeline.jsonl`.

  All typed fields are optional because the daemon may emit partial
  events (e.g. without `text`); `extra` carries the verbatim decoded
  line so future daemon fields survive without a wrapper update. See
  `ClaudeWrapper.Jobs`.
  """

  @enforce_keys [:extra]
  defstruct [:at, :state, :detail, :text, :extra]

  @type t :: %__MODULE__{
          at: String.t() | nil,
          state: String.t() | nil,
          detail: String.t() | nil,
          text: String.t() | nil,
          extra: map()
        }
end

defmodule ClaudeWrapper.Jobs.Job do
  @moduledoc """
  Full job record returned by `ClaudeWrapper.Jobs.get/2`.

  Carries the summary, the parsed timeline, and the raw `state.json`
  map for callers that want to drill into fields this module does not
  type explicitly (e.g. `inFlight`, `respawnFlags`, `tempo`). See
  `ClaudeWrapper.Jobs`.
  """

  alias ClaudeWrapper.Jobs.{Event, Summary}

  @enforce_keys [:summary, :timeline, :raw_state]
  defstruct [:summary, :timeline, :raw_state]

  @type t :: %__MODULE__{
          summary: Summary.t(),
          timeline: [Event.t()],
          raw_state: map()
        }
end

defmodule ClaudeWrapper.Jobs do
  @moduledoc """
  Read-side access to Claude Code's on-disk **background-job** state.

  Claude Code ships a supervisor daemon (`claude daemon run`) that
  orchestrates background agent tasks launched via the `claude agents`
  TUI. Per-task state lives under `~/.claude/jobs/<short_id>/`:

    * `state.json` -- current snapshot: state, intent (original
      prompt), session id, link to the session JSONL, timestamps,
      auto-generated name, etc.
    * `timeline.jsonl` -- append-only event log: at each state
      transition the daemon writes a line carrying timestamp, new
      state, a one-line detail, and (often) the full text body.

  The session content itself is a normal
  `~/.claude/projects/<slug>/<session_id>.jsonl` -- the same format
  `ClaudeWrapper.History` parses. Each summary's `session_path` points
  at it for direct cross-linking.

  This module is read-only on purpose. The dispatch protocol (how the
  TUI launches new tasks) is undocumented and version-sensitive;
  mirroring it would defeat the drift defenses the wrapper relies on.

  ## Liberal parsing

  Like `ClaudeWrapper.History`, parsing is forgiving. `list/1` skips
  entries that are not directories (e.g. the daemon's `pins.json`),
  that carry no `state.json` (a spare worker dir), or whose
  `state.json` fails to parse -- malformed jobs are dropped rather
  than failing the whole listing. The timeline parser skips blank and
  malformed lines.

  ## Example

      {:ok, root} = ClaudeWrapper.Jobs.home()
      {:ok, summaries} = ClaudeWrapper.Jobs.list(root)

      for s <- summaries do
        IO.puts("\#{s.short_id}  [\#{s.state}]  \#{s.intent}")
      end

      {:ok, job} = ClaudeWrapper.Jobs.get(root, "90c961c7")

      for event <- job.timeline do
        IO.puts("\#{event.at}  \#{event.state}")
      end
  """

  alias ClaudeWrapper.Jobs.{Event, Job, Summary}

  @enforce_keys [:root]
  defstruct [:root]

  @type t :: %__MODULE__{root: String.t()}

  @doc """
  Resolve the default jobs root, `~/.claude/jobs`.

  Returns `{:error, :no_home}` when the user home cannot be determined.
  """
  @spec home() :: {:ok, t()} | {:error, :no_home}
  def home do
    case System.user_home() do
      nil -> {:error, :no_home}
      home -> {:ok, %__MODULE__{root: Path.join([home, ".claude", "jobs"])}}
    end
  end

  @doc """
  Use a specific path as the jobs root. Useful for tests (point at a
  temp dir) and non-default installs.
  """
  @spec at(String.t()) :: t()
  def at(path) when is_binary(path), do: %__MODULE__{root: path}

  @doc "The configured root directory."
  @spec root(t()) :: String.t()
  def root(%__MODULE__{root: root}), do: root

  @doc """
  List every job directory at the root, sorted by `short_id`.

  Returns `{:ok, []}` when the root directory does not exist (no
  background agents have been launched on this machine yet). Skips
  entries that are not directories, that carry no `state.json`, or
  whose `state.json` fails to parse.
  """
  @spec list(t()) :: {:ok, [Summary.t()]} | {:error, term()}
  def list(%__MODULE__{} = jobs) do
    case File.ls(jobs.root) do
      {:ok, names} ->
        summaries =
          names
          |> Enum.map(&summarize(jobs, &1))
          |> Enum.reject(&is_nil/1)
          |> Enum.sort_by(& &1.short_id)

        {:ok, summaries}

      {:error, :enoent} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @doc """
  Read one job by short id (its `~/.claude/jobs/<short_id>/` directory
  name) into a full `ClaudeWrapper.Jobs.Job`, including the parsed
  `timeline.jsonl` and the raw `state.json` map.

  Returns `{:error, :not_found}` when no such directory exists or its
  `state.json` is missing.
  """
  @spec get(t(), String.t()) :: {:ok, Job.t()} | {:error, :not_found | term()}
  def get(%__MODULE__{} = jobs, short_id) when is_binary(short_id) do
    dir = Path.join(jobs.root, short_id)
    state_path = Path.join(dir, "state.json")

    case File.read(state_path) do
      {:ok, raw} -> read_job(state_path, raw, dir, short_id)
      {:error, :enoent} -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # -- read helpers --------------------------------------------------

  defp read_job(state_path, raw, dir, short_id) do
    case decode_state(raw) do
      {:ok, map} ->
        {:ok,
         %Job{
           summary: build_summary(map, short_id, state_mtime_secs(state_path)),
           timeline: parse_timeline(Path.join(dir, "timeline.jsonl")),
           raw_state: map
         }}

      :error ->
        {:error, :not_found}
    end
  end

  # Summarize one top-level entry. Returns nil when the entry is not a
  # directory, carries no state.json, or its state.json fails to parse.
  defp summarize(%__MODULE__{} = jobs, short_id) do
    dir = Path.join(jobs.root, short_id)

    if File.dir?(dir) do
      summarize_dir(dir, short_id)
    end
  end

  defp summarize_dir(dir, short_id) do
    state_path = Path.join(dir, "state.json")

    case File.read(state_path) do
      {:ok, raw} -> summary_from_state(state_path, raw, short_id)
      {:error, _} -> nil
    end
  end

  defp summary_from_state(state_path, raw, short_id) do
    case decode_state(raw) do
      {:ok, map} -> build_summary(map, short_id, state_mtime_secs(state_path))
      :error -> nil
    end
  end

  defp build_summary(map, short_id, state_mtime_secs) do
    %Summary{
      short_id: short_id,
      state: str(map, "state") || "unknown",
      daemon_short: str(map, "daemonShort"),
      backend: str(map, "backend"),
      name: str(map, "name"),
      detail: str(map, "detail"),
      intent: str(map, "intent"),
      session_id: str(map, "sessionId"),
      session_path: str(map, "linkScanPath"),
      cwd: str(map, "cwd"),
      origin_cwd: str(map, "originCwd"),
      created_at: str(map, "createdAt"),
      updated_at: str(map, "updatedAt"),
      first_terminal_at: str(map, "firstTerminalAt"),
      cli_version: str(map, "cliVersion"),
      state_mtime_secs: state_mtime_secs
    }
  end

  defp parse_timeline(path) do
    case File.read(path) do
      {:ok, raw} ->
        raw
        |> String.split("\n")
        |> Enum.flat_map(&parse_timeline_line/1)

      {:error, _} ->
        []
    end
  end

  defp parse_timeline_line(line) do
    case decode_line(line) do
      {:ok, map} -> [build_event(map)]
      :error -> []
    end
  end

  defp build_event(map) do
    %Event{
      at: str(map, "at"),
      state: str(map, "state"),
      detail: str(map, "detail"),
      text: str(map, "text"),
      extra: map
    }
  end

  # -- io / decode helpers -------------------------------------------

  defp decode_state(raw) do
    case Jason.decode(raw) do
      {:ok, map} when is_map(map) -> {:ok, map}
      _ -> :error
    end
  end

  defp decode_line(line) do
    case String.trim(line) do
      "" -> :error
      trimmed -> trimmed |> Jason.decode() |> normalize_decode()
    end
  end

  defp normalize_decode({:ok, map}) when is_map(map), do: {:ok, map}
  defp normalize_decode(_), do: :error

  # Read a string-valued field, returning nil for missing or non-string
  # values (mirrors the Rust `Value::as_str` accessors).
  defp str(map, key) do
    case Map.get(map, key) do
      value when is_binary(value) -> value
      _ -> nil
    end
  end

  defp state_mtime_secs(path) do
    case File.stat(path, time: :posix) do
      {:ok, %File.Stat{mtime: mtime}} when is_integer(mtime) and mtime >= 0 -> mtime
      _ -> nil
    end
  end
end
