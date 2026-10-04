defmodule ClaudeWrapper.ObservedQueryTest do
  use ExUnit.Case, async: false

  @moduletag :forcola

  alias ClaudeWrapper.{Command, Config, Error, Query, Result, Runner, SessionObservation}

  setup do
    previous = Application.get_env(:claude_wrapper, :runner)
    Application.put_env(:claude_wrapper, :runner, Runner.Forcola)
    directory = Path.join(System.tmp_dir!(), "cw_observed_#{System.unique_integer([:positive])}")
    File.mkdir_p!(directory)

    on_exit(fn ->
      if previous,
        do: Application.put_env(:claude_wrapper, :runner, previous),
        else: Application.delete_env(:claude_wrapper, :runner)

      File.rm_rf!(directory)
    end)

    %{directory: directory, reference: make_ref()}
  end

  test "announces init before a blocked invocation completes", context do
    release = Path.join(context.directory, "release")

    script =
      emit(init()) <> "while [ ! -f \"$RELEASE\" ]; do sleep 0.01; done\n" <> emit(result())

    config = fixture(context, script, env: [{"RELEASE", release}])
    observer = {self(), context.reference}

    task =
      Task.async(fn -> Query.execute(Query.new("hello"), config, session_observer: observer) end)

    on_exit(fn -> Process.exit(task.pid, :kill) end)

    reference = context.reference

    assert_receive {^reference,
                    %SessionObservation{session_id: "native-session", source: :system_init}},
                   1_000

    assert Task.yield(task, 0) == nil
    File.write!(release, "continue")
    assert {:ok, %Result{result: "done", session_id: "native-session"}} = Task.await(task)
  end

  test "the execution caller sends the observation before its terminal reply", context do
    observer = self()
    reference = context.reference
    config = fixture(context, emit(init()) <> emit(result()))

    spawn(fn ->
      outcome = Query.execute(Query.new("hello"), config, session_observer: {observer, reference})
      send(observer, {reference, {:returned, outcome}})
    end)

    assert_receive {^reference, first}, 1_000
    assert %SessionObservation{} = first
    assert_receive {^reference, {:returned, {:ok, %Result{}}}}, 1_000
  end

  test "the runner invokes its trusted observer in the calling process", context do
    caller = self()
    reference = context.reference

    observer = fn line ->
      send(caller, {reference, self(), line})
      :observed
    end

    assert {:ok, {"one\ntwo\n", 0, ""}} =
             Runner.Forcola.run_observed("printf", ["one\ntwo\n"], [], 1_000, observer)

    assert_receive {^reference, ^caller, "one"}
    refute_receive {^reference, _pid, _line}, 20
  end

  test "accepts fragmented init and suppresses duplicate and conflicting later init", context do
    json = Jason.encode!(init())
    {first, rest} = String.split_at(json, 17)

    script =
      "printf '%s' #{Command.shell_escape(first)}\nsleep 0.01\n" <>
        "printf '%s\\n' #{Command.shell_escape(rest)}\n" <>
        emit(init()) <> emit(init("different-session")) <> emit(result())

    assert {:ok, %Result{}} = execute(context, script)
    reference = context.reference
    assert_receive {^reference, %SessionObservation{session_id: "native-session"}}
    refute_receive {^reference, _observation}, 20
  end

  test "ignores malformed, wrong-envelope and blank IDs until the first valid init", context do
    invalid = [
      %{"type" => "system", "subtype" => "init"},
      init(nil),
      init(12),
      init(""),
      init(" \t\n"),
      %{"type" => "assistant", "subtype" => "init", "session_id" => "wrong"},
      %{"type" => "system", "subtype" => "other", "session_id" => "wrong"},
      ["not an event"]
    ]

    script =
      "printf 'malformed\\n'\n" <>
        Enum.map_join(invalid, &emit/1) <>
        emit(init()) <> emit(result())

    assert {:ok, %Result{}} = execute(context, script)
    reference = context.reference
    assert_receive {^reference, %SessionObservation{session_id: "native-session"}}
    refute_receive {^reference, _observation}, 20
  end

  test "a successful result without init emits no identity", context do
    assert {:ok, %Result{}} = execute(context, emit(result()))
    reference = context.reference
    refute_receive {^reference, _observation}, 20
  end

  test "init-only zero exit is a typed missing-result error", context do
    assert {:error, %Error{kind: :json, reason: :missing_result}} = execute(context, emit(init()))
    reference = context.reference
    assert_receive {^reference, %SessionObservation{}}
  end

  test "stderr cannot supply a session identity or a terminal result", context do
    assert {:error, %Error{kind: :json, reason: :missing_result}} =
             execute(context, emit(init(), :stderr) <> emit(result(), :stderr))

    reference = context.reference
    refute_receive {^reference, _observation}, 20

    assert {:error, %Error{kind: :command_failed, exit_code: 7}} =
             execute(context, emit(result(), :stderr) <> "exit 7\n")
  end

  test "preserves every parsed Result field and ignores later unrelated JSON", context do
    data =
      Map.merge(result(), %{
        "total_cost_usd" => 0.0123,
        "duration_ms" => 15,
        "num_turns" => 3,
        "is_error" => false,
        "usage" => %{"input_tokens" => 42},
        "structured_output" => %{"answer" => 7}
      })

    assert {:ok, actual} =
             execute(context, emit(init()) <> emit(data) <> emit(%{"type" => "system"}))

    assert actual == Result.from_json(data)
  end

  test "non-rail error results preserve existing successful tuple semantics", context do
    data = Map.merge(result(), %{"subtype" => "error_during_execution", "is_error" => true})
    assert {:ok, %Result{is_error: true}} = execute(context, emit(data) <> "exit 1\n")
  end

  test "max-turn and budget rail stops retain cap, usage and session", context do
    for {subtype, message, kind, cap} <- [
          {"error_max_turns", "Reached maximum number of turns (3)", :max_turns_exceeded, 3},
          {"error_max_budget_usd", "Reached maximum budget ($0.50)", :max_budget_exceeded, 0.5}
        ] do
      data =
        Map.merge(result(), %{
          "subtype" => subtype,
          "result" => message,
          "total_cost_usd" => 0.75,
          "num_turns" => 3,
          "is_error" => true
        })

      assert {:error, %Error{kind: ^kind, exit_code: 1, reason: reason}} =
               execute(context, emit(init()) <> emit(data) <> "exit 1\n")

      assert reason == %{cap: cap, cost_usd: 0.75, num_turns: 3, session_id: "native-session"}
    end
  end

  test "classifies authentication on stderr and keeps ordinary failures separate", context do
    assert {:error, %Error{kind: :auth, exit_code: 1, stderr: stderr}} =
             execute(context, "printf 'Invalid API key\\n' >&2\nexit 1\n")

    assert stderr =~ "Invalid API key"

    assert {:error, %Error{kind: :command_failed, exit_code: 7, stdout: stdout, stderr: stderr}} =
             execute(
               context,
               "printf 'ordinary stdout\\n'\nprintf 'ordinary stderr\\n' >&2\nexit 7\n"
             )

    assert stdout == "ordinary stdout\n"
    assert stderr == "ordinary stderr\n"
  end

  test "signal after init is an IO error and cannot become success", context do
    assert {:error, %Error{kind: :io, reason: {:signal, _signal}}} =
             execute(context, emit(init()) <> emit(result()) <> "kill -TERM $$\n")

    reference = context.reference
    assert_receive {^reference, %SessionObservation{}}
  end

  test "missing binary preserves the Forcola spawn error", context do
    config = Config.new(binary: Path.join(context.directory, "missing"), timeout: 1_000)

    assert {:error, %Error{kind: :io, reason: {:spawn, _reason}}} =
             Query.execute(Query.new("hello"), config,
               session_observer: {self(), context.reference}
             )
  end

  test "whole-run timeout is not reset by continuing output", context do
    script = emit(init()) <> "while :; do printf 'still working\\n'; sleep 0.02; done\n"
    started = System.monotonic_time(:millisecond)
    assert {:error, %Error{kind: :timeout, reason: 150}} = execute(context, script, timeout: 150)
    assert System.monotonic_time(:millisecond) - started < 2_000
    reference = context.reference
    assert_receive {^reference, %SessionObservation{}}
  end

  test "a result before a stalled transport still ends in timeout", context do
    assert {:error, %Error{kind: :timeout}} =
             execute(context, emit(init()) <> emit(result()) <> "sleep 30\n", timeout: 150)

    reference = context.reference
    assert_receive {^reference, %SessionObservation{}}
  end

  test "dead observer does not affect completion", context do
    {observer, monitor} = spawn_monitor(fn -> :ok end)
    assert_receive {:DOWN, ^monitor, :process, ^observer, :normal}
    config = fixture(context, emit(init()) <> emit(result()))

    assert {:ok, %Result{}} =
             Query.execute(Query.new("hello"), config,
               session_observer: {observer, context.reference}
             )
  end

  test "invalid observer is rejected before a missing binary could spawn", context do
    config = Config.new(binary: Path.join(context.directory, "missing"))

    for opts <- [
          nil,
          [session_observer: self()],
          [session_observer: {self(), :not_reference}],
          [session_observer: {"not a pid", make_ref()}],
          [session_observer: {self(), make_ref()}, unknown: true]
        ] do
      assert {:error, %Error{kind: :invalid_session_observer}} =
               Query.execute(Query.new("hello"), config, opts)
    end
  end

  test "unsupported runner is rejected before spawning", context do
    Application.put_env(:claude_wrapper, :runner, Runner.Port)
    config = Config.new(binary: Path.join(context.directory, "missing"))

    assert {:error, %Error{kind: :observation_unsupported, reason: Runner.Port}} =
             Query.execute(Query.new("hello"), config,
               session_observer: {self(), context.reference}
             )
  end

  test "execute/2 and empty execute/3 retain the JSON path and CLI options", context do
    script = ~s(printf '%s\\n' "$@" > "$ARGV"\n) <> emit(result())
    argv = Path.join(context.directory, "argv")
    config = fixture(context, script, env: [{"ARGV", argv}])

    query =
      Query.new("hello")
      |> Query.max_turns(3)
      |> Query.max_budget_usd(0.5)
      |> Query.resume("prior")

    assert {:ok, expected} = Query.execute(query, config)
    assert {:ok, ^expected} = Query.execute(query, config, [])
    assert File.read!(argv) =~ "--output-format\njson\n"
    refute File.read!(argv) =~ "--verbose"

    assert {:ok, ^expected} =
             Query.execute(query, config, session_observer: {self(), context.reference})

    arguments = File.read!(argv)
    assert arguments =~ "--output-format\nstream-json\n"
    assert arguments =~ "--verbose"
    assert arguments =~ "--max-turns\n3\n"
    assert arguments =~ "--max-budget-usd\n0.5\n"
    assert arguments =~ "--resume\nprior\n"
  end

  test "query/2 routes execution, config and query options through the shared splitter",
       context do
    argv = Path.join(context.directory, "convenience-argv")
    cwd = Path.join(context.directory, "convenience-cwd")
    script = ~s(printf '%s\\n' "$@" > "$ARGV"\npwd > "$CWD"\n) <> emit(init()) <> emit(result())
    config = fixture(context, script)

    opts = [
      binary: config.binary,
      working_dir: context.directory,
      env: [{"ARGV", argv}, {"CWD", cwd}],
      timeout: 1_000,
      model: "sonnet",
      max_turns: 3,
      max_budget_usd: 0.5,
      resume: "prior",
      session_observer: {self(), context.reference}
    ]

    assert {:ok, %Result{}} = ClaudeWrapper.query("hello", opts)
    reference = context.reference
    assert_receive {^reference, %SessionObservation{session_id: "native-session"}}
    arguments = File.read!(argv)
    assert arguments =~ "--output-format\nstream-json\n"
    assert arguments =~ "--model\nsonnet\n"
    assert arguments =~ "--max-turns\n3\n"
    assert arguments =~ "--max-budget-usd\n0.5\n"
    assert arguments =~ "--resume\nprior\n"
    refute arguments =~ "session_observer"

    assert String.trim(File.read!(cwd)) ==
             System.cmd("pwd", [], cd: context.directory) |> elem(0) |> String.trim()

    assert {:ok, %Result{}} =
             ClaudeWrapper.query("hello", Keyword.delete(opts, :session_observer))

    assert File.read!(argv) =~ "--output-format\njson\n"
    refute_receive {^reference, _observation}, 20
  end

  test "query/2 preserves observed preflight errors and the configured deadline", context do
    config = fixture(context, emit(init()) <> "sleep 30\n")

    assert {:error, %Error{kind: :invalid_session_observer}} =
             ClaudeWrapper.query("hello", binary: config.binary, session_observer: :invalid)

    assert {:error, %Error{kind: :timeout, reason: 150}} =
             ClaudeWrapper.query("hello",
               binary: config.binary,
               timeout: 150,
               session_observer: {self(), context.reference}
             )

    Application.put_env(:claude_wrapper, :runner, Runner.Port)

    assert {:error, %Error{kind: :observation_unsupported}} =
             ClaudeWrapper.query("hello",
               binary: config.binary,
               session_observer: {self(), context.reference}
             )
  end

  test "timeout kills the child and descendant after observing init", context do
    pidfile = Path.join(context.directory, "pids")
    script = ~s(sleep 30 &\nprintf '%s %s' "$$" "$!" > "$PIDS"\n) <> emit(init()) <> "wait\n"

    assert {:error, %Error{kind: :timeout}} =
             execute(context, script, timeout: 200, env: [{"PIDS", pidfile}])

    assert_dead_pids(pidfile)
  end

  test "execution owner death kills the child and descendant", context do
    pidfile = Path.join(context.directory, "pids")
    script = ~s(sleep 30 &\nprintf '%s %s' "$$" "$!" > "$PIDS"\n) <> emit(init()) <> "wait\n"
    config = fixture(context, script, env: [{"PIDS", pidfile}])
    observer = {self(), context.reference}

    {owner, monitor} =
      spawn_monitor(fn ->
        Query.execute(Query.new("hello"), config, session_observer: observer)
      end)

    on_exit(fn -> Process.exit(owner, :kill) end)
    reference = context.reference
    assert_receive {^reference, %SessionObservation{}}, 1_000
    Process.exit(owner, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^owner, :killed}
    assert_dead_pids(pidfile)
  end

  test "stdin closes and a final non-newline result is parsed", context do
    script =
      "cat > /dev/null\n" <>
        emit(init()) <>
        "printf '%s' #{Command.shell_escape(Jason.encode!(result()))}\n"

    assert {:ok, %Result{}} = execute(context, script)
  end

  defp execute(context, script, opts \\ []) do
    Query.execute(Query.new("hello"), fixture(context, script, opts),
      session_observer: {self(), context.reference}
    )
  end

  defp fixture(context, script, opts \\ []) do
    binary = Path.join(context.directory, "fake claude #{System.unique_integer([:positive])}")
    File.write!(binary, "#!/bin/sh\n" <> script)
    File.chmod!(binary, 0o755)
    Config.new(Keyword.merge([binary: binary, timeout: 3_000], opts))
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

  defp emit(data, stream \\ :stdout) do
    redirect = if stream == :stderr, do: " >&2", else: ""
    "printf '%s\\n' #{Command.shell_escape(Jason.encode!(data))}#{redirect}\n"
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
