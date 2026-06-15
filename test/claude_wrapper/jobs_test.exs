defmodule ClaudeWrapper.JobsTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Jobs
  alias ClaudeWrapper.Jobs.{Event, Job, Summary}

  setup do
    root = Path.join(System.tmp_dir!(), "cwx_jobs_#{System.unique_integer([:positive])}")
    File.mkdir_p!(root)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root}
  end

  # Write a job dir at <root>/<short_id>/ with the given state.json body
  # and optional timeline.jsonl lines.
  defp write_job(root, short_id, state_json, timeline_lines \\ []) do
    dir = Path.join(root, short_id)
    File.mkdir_p!(dir)
    File.write!(Path.join(dir, "state.json"), state_json)

    if timeline_lines != [] do
      File.write!(Path.join(dir, "timeline.jsonl"), Enum.join(timeline_lines, "\n") <> "\n")
    end

    dir
  end

  defp fixture(root) do
    # A done job with full state + timeline.
    write_job(
      root,
      "aaaaaaaa",
      ~s({"state":"done","detail":"42","intent":"meaning of life","sessionId":"sess-aaa","linkScanPath":"/p/sess-aaa.jsonl","cwd":"/work","createdAt":"2026-05-15T01:00:00Z","updatedAt":"2026-05-15T01:01:00Z","firstTerminalAt":"2026-05-15T01:00:55Z","name":"meaning of life","backend":"daemon","cliVersion":"2.1.143","daemonShort":"aaaaaaaa","originCwd":"/work"}),
      [
        ~s({"at":"2026-05-15T01:00:30Z","state":"running","detail":"thinking"}),
        ~s({"at":"2026-05-15T01:00:55Z","state":"done","detail":"42","text":"the answer is 42"})
      ]
    )

    # A still-running job.
    write_job(
      root,
      "bbbbbbbb",
      ~s({"state":"running","intent":"compute primes","sessionId":"sess-bbb"}),
      [~s({"at":"2026-05-15T02:00:00Z","state":"running","detail":"started"})]
    )

    # A job dir with no state.json (spare worker leftover); list/1 skips it.
    File.mkdir_p!(Path.join(root, "cccccccc"))

    # A non-directory top-level file (the daemon's pins.json); list/1 skips it.
    File.write!(Path.join(root, "pins.json"), "[]")

    # A job whose state.json is malformed; list/1 skips it.
    write_job(root, "deadbeef", "not valid json {{")
    :ok
  end

  describe "home/0, at/1, root/1" do
    test "at/1 wraps an explicit root and root/1 reads it back" do
      jobs = Jobs.at("/tmp/jobs")
      assert jobs.root == "/tmp/jobs"
      assert Jobs.root(jobs) == "/tmp/jobs"
    end

    test "home/0 resolves ~/.claude/jobs" do
      assert {:ok, %Jobs{root: root}} = Jobs.home()
      assert String.ends_with?(root, Path.join([".claude", "jobs"]))
    end
  end

  describe "list/1" do
    test "returns only well-formed jobs, sorted by short_id", %{root: root} do
      fixture(root)

      {:ok, jobs} = Jobs.list(Jobs.at(root))
      assert Enum.map(jobs, & &1.short_id) == ["aaaaaaaa", "bbbbbbbb"]
    end

    test "returns empty when the root does not exist" do
      {:ok, jobs} = Jobs.list(Jobs.at("/no/such/jobs/root"))
      assert jobs == []
    end

    test "summary carries typed fields", %{root: root} do
      fixture(root)

      {:ok, jobs} = Jobs.list(Jobs.at(root))
      s = Enum.find(jobs, &(&1.short_id == "aaaaaaaa"))

      assert %Summary{state: "done", intent: "meaning of life"} = s
      assert s.session_id == "sess-aaa"
      assert s.session_path == "/p/sess-aaa.jsonl"
      assert s.cwd == "/work"
      assert s.name == "meaning of life"
      assert s.backend == "daemon"
      assert s.cli_version == "2.1.143"
      assert s.daemon_short == "aaaaaaaa"
      assert s.origin_cwd == "/work"
      assert s.created_at == "2026-05-15T01:00:00Z"
      assert s.updated_at == "2026-05-15T01:01:00Z"
      assert s.first_terminal_at == "2026-05-15T01:00:55Z"
      assert is_integer(s.state_mtime_secs)
    end

    test "running job has no first_terminal_at", %{root: root} do
      fixture(root)

      {:ok, jobs} = Jobs.list(Jobs.at(root))
      s = Enum.find(jobs, &(&1.short_id == "bbbbbbbb"))

      assert s.state == "running"
      assert s.first_terminal_at == nil
    end

    test "missing state field defaults to unknown", %{root: root} do
      write_job(root, "nostate", ~s({"intent":"x"}))

      {:ok, [summary]} = Jobs.list(Jobs.at(root))
      assert summary.state == "unknown"
    end

    test "unknown state string passes through", %{root: root} do
      write_job(root, "weirdstate", ~s({"state":"some-future-state","intent":"x"}))

      {:ok, [summary]} = Jobs.list(Jobs.at(root))
      assert summary.state == "some-future-state"
    end
  end

  describe "get/2" do
    test "returns the full record with timeline", %{root: root} do
      fixture(root)

      {:ok, job} = Jobs.get(Jobs.at(root), "aaaaaaaa")

      assert %Job{} = job
      assert job.summary.state == "done"
      assert length(job.timeline) == 2

      assert [%Event{state: "running"}, %Event{state: "done", text: "the answer is 42"}] =
               job.timeline

      assert is_map(job.raw_state)
      assert job.raw_state["state"] == "done"
    end

    test "no timeline file yields an empty list", %{root: root} do
      write_job(root, "ffffffff", ~s({"state":"queued","intent":"x","sessionId":"y"}))

      {:ok, job} = Jobs.get(Jobs.at(root), "ffffffff")
      assert job.timeline == []
    end

    test "unknown id returns a :not_found error", %{root: root} do
      fixture(root)

      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "nope"}} =
               Jobs.get(Jobs.at(root), "nope")
    end

    test "dir present but state.json missing returns a :not_found error", %{root: root} do
      File.mkdir_p!(Path.join(root, "cccccccc"))

      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "cccccccc"}} =
               Jobs.get(Jobs.at(root), "cccccccc")
    end

    test "malformed state.json returns a :not_found error", %{root: root} do
      write_job(root, "deadbeef", "not valid json {{")

      assert {:error, %ClaudeWrapper.Error{kind: :not_found, reason: "deadbeef"}} =
               Jobs.get(Jobs.at(root), "deadbeef")
    end

    test "timeline skips blank and malformed lines without failing", %{root: root} do
      write_job(
        root,
        "mixed",
        ~s({"state":"done","intent":"x","sessionId":"y"}),
        [
          ~s({"at":"t1","state":"running"}),
          "NOT VALID JSON",
          "",
          ~s({"at":"t2","state":"done","text":"final"})
        ]
      )

      {:ok, job} = Jobs.get(Jobs.at(root), "mixed")

      assert length(job.timeline) == 2
      assert Enum.at(job.timeline, 0).at == "t1"
      assert Enum.at(job.timeline, 1).at == "t2"
      assert Enum.at(job.timeline, 1).text == "final"
    end

    test "event carries the verbatim decoded line in extra", %{root: root} do
      write_job(
        root,
        "extraline",
        ~s({"state":"done","intent":"x","sessionId":"y"}),
        [~s({"at":"t1","state":"running","customField":{"nested":7}})]
      )

      {:ok, job} = Jobs.get(Jobs.at(root), "extraline")
      [event] = job.timeline

      assert event.extra["customField"]["nested"] == 7
      assert event.extra["at"] == "t1"
    end

    test "raw_state preserves unknown fields", %{root: root} do
      write_job(
        root,
        "extras",
        ~s({"state":"done","intent":"x","sessionId":"y","futureField":{"nested":42},"tempo":"idle"})
      )

      {:ok, job} = Jobs.get(Jobs.at(root), "extras")

      assert job.raw_state["futureField"]["nested"] == 42
      assert job.raw_state["tempo"] == "idle"
    end
  end
end
