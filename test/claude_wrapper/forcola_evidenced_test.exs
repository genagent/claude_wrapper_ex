defmodule ClaudeWrapper.ForcolaEvidencedTest do
  # Required released-contract coverage: missing Forcola 0.7 or a matching
  # shim is a failure, never an implicit skip.
  use ExUnit.Case, async: false

  @moduletag :forcola_evidence

  alias ClaudeWrapper.{
    Command,
    Config,
    Error,
    ExecutionEvidence,
    Query,
    Result,
    Runner,
    SessionObservation
  }

  alias ClaudeWrapper.Runner.ForcolaEvidence

  setup_all do
    assert Application.spec(:forcola, :vsn) |> to_string() |> Version.match?("~> 0.7.0")
    assert ForcolaEvidence.supported?(Forcola.Result)
    assert {:ok, _path} = Forcola.Shim.path()
    :ok
  end

  setup do
    directory = Path.join(System.tmp_dir!(), "cw_evidenced_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)
    on_exit(fn -> File.rm_rf!(directory) end)
    %{directory: directory, reference: make_ref()}
  end

  test "clean completion: ID, then one record, then the reply", context do
    config = fixture(context, emit(init()) <> emit(result()))
    reference = context.reference
    observer = {self(), reference}
    test = self()

    spawn(fn ->
      reply =
        Query.execute(Query.new("hello"), config,
          session_observer: observer,
          execution_observer: observer
        )

      send(test, {reference, {:returned, reply}})
    end)

    assert %SessionObservation{session_id: "native-session"} = next(reference)
    assert %ExecutionEvidence{} = evidence = next(reference)
    assert {:returned, {:ok, %Result{result: "done"}} = reply} = next(reference)

    assert evidence.outcome == reply
    assert evidence.runner == Runner.Forcola
    assert evidence.execution == :started
    assert evidence.child_status == 0
    assert evidence.termination == :exit
    assert evidence.cleanup == :confirmed
    assert evidence.scope in [:process_group, :active_cgroup]
    assert evidence.guard_close == :ok
    assert evidence.output_truncated == false
  end

  test "fragmented init is announced once", context do
    json = Jason.encode!(init())
    {first, rest} = String.split_at(json, 17)

    script =
      "printf '%s' #{Command.shell_escape(first)}\nsleep 0.05\n" <>
        "printf '%s\\n' #{Command.shell_escape(rest)}\n" <> emit(init("other")) <> emit(result())

    {reply, evidence} = execute(context, script)
    reference = context.reference
    assert {:ok, %Result{}} = reply
    assert_received {^reference, %SessionObservation{session_id: "native-session"}}
    refute_received {^reference, %SessionObservation{}}
    assert evidence.session_id == "native-session"
  end

  test "an early result followed by a stall ends in timeout with the result retained",
       context do
    script = emit(init()) <> emit(result()) <> "sleep 30\n"
    {reply, evidence} = execute(context, script, timeout: 300)

    assert {:error, %Error{kind: :timeout, reason: 300}} = reply
    assert evidence.reason == :timeout
    assert %Result{result: "done"} = evidence.result
    assert evidence.session_id == "native-session"
    assert evidence.stdout =~ "native-session"
  end

  test "an early result followed by a nonzero exit keeps the raw child status", context do
    {_reply, evidence} = execute(context, emit(init()) <> emit(result()) <> "exit 7\n")
    assert evidence.child_status == 7
    assert %Result{} = evidence.result
  end

  test "idle timeout is independent of the whole-run timeout", context do
    script = emit(init()) <> "sleep 30\n"

    {reply, evidence} =
      execute(context, script, timeout: 10_000, runner_options: [idle_timeout_ms: 200])

    assert {:error, %Error{kind: :timeout, reason: 200}} = reply
    assert evidence.reason == :idle_timeout
  end

  test "combined output bound cancels with a bounded prefix", context do
    script = emit(init()) <> "while :; do printf 'xxxxxxxxxxxxxxxx\\n'; done\n"
    {reply, evidence} = execute(context, script, runner_options: [max_output_bytes: 4_096])

    assert {:error, %Error{kind: :output_limit, reason: %{limit: :max_output_bytes}}} = reply
    assert byte_size(evidence.stdout) + byte_size(evidence.stderr) <= 4_096
    assert evidence.output_truncated == true
  end

  test "an over-long line is withheld from observers and counted", context do
    long = String.duplicate("a", 5_000)
    script = "printf '%s\\n' #{long}\n" <> emit(init()) <> emit(result())
    {reply, evidence} = execute(context, script, runner_options: [max_line_bytes: 1_024])

    assert {:ok, %Result{}} = reply
    assert evidence.lines_dropped == 1
    assert evidence.session_id == "native-session"
  end

  test "env_mode :replace runs with only the configured environment", context do
    out = Path.join(context.directory, "env")
    script = "/usr/bin/env > \"$OUT\"\n" <> emit(result())

    {reply, _evidence} =
      execute(context, script, env: [{"OUT", out}], runner_options: [env_mode: :replace])

    assert {:ok, %Result{}} = reply
    lines = out |> File.read!() |> String.split("\n", trim: true)
    assert "OUT=#{out}" in lines
    refute Enum.any?(lines, &String.starts_with?(&1, "HOME="))
  end

  test "two simultaneous configs keep distinct cwd and environment", context do
    script = ~s(pwd > "$OUT"\nprintf '%s\\n' "$MARK" >> "$OUT"\nsleep 0.2\n) <> emit(result())

    tasks =
      for label <- ["a", "b"] do
        cwd = Path.join(context.directory, "cwd-#{label}")
        File.mkdir_p!(cwd)
        out = Path.join(context.directory, "out-#{label}")
        env = [{"OUT", out}, {"MARK", "mark-#{label}"}]
        config = fixture(context, script, working_dir: cwd, env: env)
        Task.async(fn -> {label, Query.execute(Query.new("hello"), config)} end)
      end

    for {label, reply} <- Task.await_many(tasks, 10_000) do
      assert {:ok, %Result{}} = reply
      out = Path.join(context.directory, "out-#{label}")
      [pwd, mark] = out |> File.read!() |> String.split()
      assert String.ends_with?(pwd, "cwd-#{label}")
      assert mark == "mark-#{label}"
    end
  end

  test "interrupt-first cleanup reaches a cooperative child", context do
    marker = Path.join(context.directory, "interrupted")

    trap = ~s(trap 'printf int > "$MARKER"; exit 0' INT\n)
    script = trap <> emit(init()) <> "sleep 30 &\nwait\n"

    {reply, _evidence} =
      execute(context, script,
        timeout: 300,
        env: [{"MARKER", marker}],
        runner_options: [interrupt_signal: :int, interrupt_grace_ms: 1_000]
      )

    assert {:error, %Error{kind: :timeout}} = reply
    assert File.read!(marker) == "int"
  end

  test "unknown runner options are rejected before the child runs", context do
    marker = Path.join(context.directory, "ran")
    script = ~s(touch "$MARKER"\n) <> emit(result())

    {reply, evidence} =
      execute(context, script, env: [{"MARKER", marker}], runner_options: [bogus: 1])

    assert {:error, %Error{kind: :invalid_runner_options, reason: {:unknown, :bogus}}} = reply
    assert evidence.execution == :not_started
    refute File.exists?(marker)
  end

  test "an older shim rejects HELLO before any SPAWN", context do
    python =
      System.find_executable("python3") || flunk("python3 is required for the shim fixture")

    shim = Path.join(context.directory, "older-shim")
    source = File.read!(Path.expand("../fixtures/incompatible_shim.py", __DIR__))
    File.write!(shim, "#!#{python}\n" <> source)
    File.chmod!(shim, 0o755)

    {reply, evidence} = execute(context, emit(result()), runner_options: [shim_path: shim])

    assert {:error, %Error{kind: :io, reason: {:spawn, :incompatible_shim}}} = reply
    assert File.read!(Path.join(context.directory, "shim-requests")) == "7\n"
    assert evidence.execution == :not_started
    assert evidence.termination == {:spawn, :incompatible_shim}
    assert evidence.child_status == nil
    assert evidence.child_signal == nil
    assert evidence.cleanup == :not_applicable
    assert evidence.guard_close == :not_applicable
    assert evidence.stdout == ""
    assert evidence.session_id == nil
    refute_received {_, %SessionObservation{}}
    refute_received {_, %ExecutionEvidence{}}
  end

  test "execution owner death ends the child process group", context do
    pidfile = Path.join(context.directory, "pids")
    script = ~s(sleep 30 &\nprintf '%s %s' "$$" "$!" > "$PIDS"\n) <> emit(init()) <> "wait\n"
    config = fixture(context, script, env: [{"PIDS", pidfile}])
    reference = context.reference

    {owner, monitor} =
      spawn_monitor(fn ->
        Query.execute(Query.new("hello"), config,
          session_observer: {self(), reference},
          execution_observer: {self(), reference}
        )
      end)

    await_file(pidfile, System.monotonic_time(:millisecond) + 2_000)
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert_dead_pids(pidfile)
  end

  defp execute(context, script, opts \\ []) do
    reference = context.reference
    config = fixture(context, script, opts)
    observer = {self(), reference}

    reply =
      Query.execute(Query.new("hello"), config,
        session_observer: observer,
        execution_observer: observer
      )

    assert_received {^reference, %ExecutionEvidence{} = evidence}
    assert evidence.outcome == reply
    {reply, evidence}
  end

  defp fixture(context, script, opts \\ []) do
    binary = Path.join(context.directory, "fake claude #{System.unique_integer([:positive])}")
    File.write!(binary, "#!/bin/sh\n" <> script)
    File.chmod!(binary, 0o755)

    [binary: binary, timeout: 3_000, runner: Runner.Forcola, runner_options: []]
    |> Keyword.merge(opts)
    |> Config.new()
  end

  defp next(reference) do
    receive do
      {^reference, message} -> message
    after
      5_000 -> flunk("no message for the reference")
    end
  end

  defp init(id \\ "native-session"),
    do: %{"type" => "system", "subtype" => "init", "session_id" => id}

  defp result,
    do: %{
      "type" => "result",
      "subtype" => "success",
      "result" => "done",
      "session_id" => "native-session"
    }

  defp emit(data), do: "printf '%s\\n' #{Command.shell_escape(Jason.encode!(data))}\n"

  defp await_file(path, deadline) do
    cond do
      File.exists?(path) and File.read!(path) != "" ->
        :ok

      System.monotonic_time(:millisecond) < deadline ->
        Process.sleep(10)
        await_file(path, deadline)

      true ->
        flunk("#{path} was not written")
    end
  end

  defp assert_dead_pids(pidfile) do
    pids = pidfile |> File.read!() |> String.split()
    assert length(pids) == 2
    Enum.each(pids, &await_dead(&1, System.monotonic_time(:millisecond) + 2_000))
  end

  defp await_dead(pid, deadline) do
    case System.cmd("kill", ["-0", pid], stderr_to_stdout: true) do
      {_output, 0} ->
        assert System.monotonic_time(:millisecond) < deadline, "process #{pid} survived cleanup"
        Process.sleep(10)
        await_dead(pid, deadline)

      {_output, _code} ->
        :ok
    end
  end
end
