defmodule ClaudeWrapper.HistoryTest do
  use ExUnit.Case, async: true

  doctest ClaudeWrapper.History, import: true

  alias ClaudeWrapper.History
  alias ClaudeWrapper.History.{ProjectSummary, SessionLog, SessionSummary}

  setup do
    root = Path.join(System.tmp_dir!(), "cwx_hist_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  defp write_session(dir, id, lines) do
    File.mkdir_p!(dir)
    path = Path.join(dir, id <> ".jsonl")
    File.write!(path, Enum.join(lines, "\n") <> "\n")
    path
  end

  defp user(ts, content, extra \\ "") do
    ~s({"type":"user","uuid":"u","timestamp":"#{ts}"#{extra},"message":{"role":"user","content":"#{content}"}})
  end

  defp assistant(ts, content) do
    ~s({"type":"assistant","uuid":"a","timestamp":"#{ts}","message":{"role":"assistant","content":"#{content}"}})
  end

  describe "list_projects/2" do
    test "returns directories sorted by slug, counting sessions", %{root: root} do
      a = Path.join(root, "-Users-josh-Code-projA")
      write_session(a, "session-aaa", [user("2026-01-01T00:00:00Z", "hello")])
      write_session(a, "session-bbb", [user("2026-01-02T00:00:00Z", "second")])
      b = Path.join(root, "-private-tmp-projB")
      write_session(b, "session-ccc", [user("2026-02-01T00:00:00Z", "x")])

      {:ok, projects} = History.list_projects(History.at(root))

      assert Enum.map(projects, & &1.slug) == ["-Users-josh-Code-projA", "-private-tmp-projB"]
      assert %ProjectSummary{session_count: 2} = Enum.find(projects, &(&1.slug =~ "projA"))
      assert %ProjectSummary{session_count: 1} = Enum.find(projects, &(&1.slug =~ "projB"))
    end

    test "returns empty when the root does not exist" do
      {:ok, projects} = History.list_projects(History.at("/no/such/history/root"))
      assert projects == []
    end

    test "decoded_path falls back to naive slash decode when unverified", %{root: root} do
      File.mkdir_p!(Path.join(root, "-Users-nobody-Code-projX"))

      {:ok, [p]} = History.list_projects(History.at(root))

      assert p.decoded_path == "/Users/nobody/Code/projX"
      refute p.decode_verified?
    end

    test "decoded_path keeps a hyphenated leaf by anchoring on the filesystem", %{root: root} do
      real = Path.join([root, "rust", "claude-wrapper"])
      File.mkdir_p!(real)
      slug = String.replace(real, ["/", "."], "-")
      File.mkdir_p!(Path.join(root, slug))

      {:ok, projects} = History.list_projects(History.at(root))
      p = Enum.find(projects, &(&1.slug == slug))

      assert p.decoded_path == real
      assert p.decode_verified?
    end

    test "include_empty: false drops projects with no sessions", %{root: root} do
      File.mkdir_p!(Path.join(root, "-empty"))
      write_session(Path.join(root, "-full"), "s", [user("2026-01-01T00:00:00Z", "x")])

      {:ok, projects} = History.list_projects(History.at(root), include_empty: false)
      assert Enum.map(projects, & &1.slug) == ["-full"]
    end

    test "limit and offset paginate (name_asc)", %{root: root} do
      for slug <- ~w(-a -b -c -d -e), do: File.mkdir_p!(Path.join(root, slug))

      {:ok, projects} = History.list_projects(History.at(root), offset: 1, limit: 2)
      assert Enum.map(projects, & &1.slug) == ["-b", "-c"]
    end

    test "recency_desc sorts by newest session mtime, nil at tail", %{root: root} do
      old = write_session(Path.join(root, "-old"), "s", [user("2026-01-01T00:00:00Z", "x")])
      new = write_session(Path.join(root, "-new"), "s", [user("2026-01-01T00:00:00Z", "x")])
      File.mkdir_p!(Path.join(root, "-empty"))
      File.touch!(old, {{2026, 1, 1}, {0, 0, 0}})
      File.touch!(new, {{2026, 6, 1}, {0, 0, 0}})

      {:ok, projects} = History.list_projects(History.at(root), sort: :recency_desc)
      assert Enum.map(projects, & &1.slug) == ["-new", "-old", "-empty"]
    end
  end

  describe "list_sessions/2" do
    setup %{root: root} do
      a = Path.join(root, "-projA")

      write_session(a, "session-aaa", [
        user("2026-01-01T00:00:00Z", "hello"),
        assistant("2026-01-01T00:00:01Z", "hi"),
        ~s({"type":"queue-operation","operation":"enqueue","timestamp":"2026-01-01T00:00:02Z"}),
        ~s({"type":"ai-title","aiTitle":"hello world"})
      ])

      write_session(a, "session-bbb", [user("2026-01-02T00:00:00Z", "second")])
      write_session(Path.join(root, "-projB"), "session-ccc", [user("2026-02-01T00:00:00Z", "x")])
      :ok
    end

    test "filtered by slug", %{root: root} do
      {:ok, sessions} = History.list_sessions(History.at(root), slug: "-projA")
      assert Enum.map(sessions, & &1.session_id) == ["session-aaa", "session-bbb"]
      assert Enum.all?(sessions, &(&1.project_slug == "-projA"))
    end

    test "unfiltered returns the union across projects", %{root: root} do
      {:ok, sessions} = History.list_sessions(History.at(root))
      assert length(sessions) == 3
    end

    test "summary counts only user/assistant; title and first_timestamp parsed", %{root: root} do
      {:ok, sessions} = History.list_sessions(History.at(root), slug: "-projA")
      aaa = Enum.find(sessions, &(&1.session_id == "session-aaa"))

      assert %SessionSummary{message_count: 2, title: "hello world"} = aaa
      assert aaa.first_timestamp == "2026-01-01T00:00:00Z"
      assert aaa.first_user_preview == "hello"
      assert aaa.size_bytes > 0
    end
  end

  describe "summary details" do
    test "ai-title accepts camelCase and legacy title; sums throughput tokens (excludes cache reads)",
         %{root: root} do
      dir = Path.join(root, "-p")

      write_session(dir, "camel", [
        user("2026-05-01T00:00:00Z", "x"),
        ~s({"type":"ai-title","aiTitle":"Camel Title"})
      ])

      write_session(dir, "legacy", [
        user("2026-05-01T00:00:00Z", "x"),
        ~s({"type":"ai-title","title":"Legacy Title"})
      ])

      write_session(dir, "tokens", [
        ~s({"type":"assistant","timestamp":"2026-05-01T00:00:00Z","message":{"usage":{"input_tokens":10,"output_tokens":5,"cache_creation_input_tokens":3,"cache_read_input_tokens":2}}})
      ])

      {:ok, sessions} = History.list_sessions(History.at(root), slug: "-p")
      by_id = Map.new(sessions, &{&1.session_id, &1})

      assert by_id["camel"].title == "Camel Title"
      assert by_id["legacy"].title == "Legacy Title"
      # input 10 + output 5 + cache_creation 3 = 18; cache_read (2) excluded
      assert by_id["tokens"].total_tokens == 18
      assert by_id["tokens"].total_cost_usd == nil
    end

    test "include_empty: false drops zero-message orphan sessions", %{root: root} do
      dir = Path.join(root, "-p")
      write_session(dir, "real", [user("2026-05-01T00:00:00Z", "x")])
      write_session(dir, "orphan", [~s({"type":"queue-operation","operation":"enqueue"})])

      {:ok, sessions} = History.list_sessions(History.at(root), slug: "-p", include_empty: false)
      assert Enum.map(sessions, & &1.session_id) == ["real"]
    end

    test "recency_desc sorts sessions by last_timestamp", %{root: root} do
      dir = Path.join(root, "-p")
      write_session(dir, "old", [user("2026-01-01T00:00:00Z", "x")])
      write_session(dir, "new", [user("2026-12-01T00:00:00Z", "x")])
      write_session(dir, "mid", [user("2026-06-01T00:00:00Z", "x")])

      {:ok, sessions} = History.list_sessions(History.at(root), slug: "-p", sort: :recency_desc)
      assert Enum.map(sessions, & &1.session_id) == ["new", "mid", "old"]
    end
  end

  describe "read_session/2 and find_session/2" do
    test "returns typed entries and skips malformed lines", %{root: root} do
      dir = Path.join(root, "-projB")

      write_session(dir, "session-ccc", [
        user("2026-02-01T00:00:00Z", "x", ~s(,"cwd":"/work","gitBranch":"main")),
        "NOT VALID JSON",
        assistant("2026-02-01T00:00:01Z", "y")
      ])

      {:ok, log} = History.read_session(History.at(root), "session-ccc")

      assert %SessionLog{session_id: "session-ccc", project_slug: "-projB"} = log
      assert length(log.entries) == 2
      assert [{:user, u}, {:assistant, a}] = log.entries
      assert u.cwd == "/work"
      assert u.git_branch == "main"
      assert a.uuid == "a"
    end

    test "preserves type_tag and raw for unknown entry types", %{root: root} do
      dir = Path.join(root, "-p")

      write_session(dir, "s", [
        user("2026-01-01T00:00:00Z", "x"),
        ~s({"type":"queue-operation","operation":"enqueue"})
      ])

      {:ok, log} = History.read_session(History.at(root), "s")
      other = Enum.find(log.entries, &match?({:other, "queue-operation", _}, &1))

      assert {:other, "queue-operation", raw} = other
      assert raw["operation"] == "enqueue"
    end

    test "read_session unknown id returns a :not_found error", %{root: root} do
      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "nope"}} =
               History.read_session(History.at(root), "nope")
    end

    test "find_session locates a real session and rejects unknown ids", %{root: root} do
      dir = Path.join(root, "-projB")
      write_session(dir, "session-ccc", [user("2026-02-01T00:00:00Z", "x")])
      h = History.at(root)

      assert {:ok, {path, "-projB"}} = History.find_session(h, "session-ccc")
      assert String.ends_with?(path, "session-ccc.jsonl")

      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "missing"}} =
               History.find_session(h, "missing")
    end
  end

  describe "project_slug/1 and sessions_for_path/3" do
    test "encodes '/', '.', and '_' as '-' (matching the CLI)" do
      tmp = Path.join(System.tmp_dir!(), "cwx_slug_#{System.unique_integer([:positive])}")
      # Mix all three separators the CLI collapses to '-': a dotted dir and
      # an underscored dir. Regression for the slug missing '_' (which made
      # sessions_for_path silently miss any underscored project dir).
      cwd = Path.join([tmp, "my.proj", "claude_wrapper_ex"])
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(tmp) end)

      slug = History.project_slug(cwd)
      assert slug =~ "my-proj"
      assert slug =~ "claude-wrapper-ex"
      refute slug =~ "."
      refute slug =~ "/"
      refute slug =~ "_"
    end

    test "encodes every non-alphanumeric character as '-'" do
      assert History.project_slug("/Users/josh/Code/foo_bar") == "-Users-josh-Code-foo-bar"
    end

    test "sessions_for_path derives the slug and finds sessions", %{root: root} do
      cwd = Path.join(System.tmp_dir!(), "cwx_cwd_#{System.unique_integer([:positive])}")
      File.mkdir_p!(cwd)
      on_exit(fn -> File.rm_rf!(cwd) end)

      slug = History.project_slug(cwd)
      write_session(Path.join(root, slug), "sess-x", [user("2026-01-01T00:00:00Z", "hi")])

      {:ok, sessions} = History.sessions_for_path(History.at(root), cwd)
      assert Enum.map(sessions, & &1.session_id) == ["sess-x"]
    end
  end
end
