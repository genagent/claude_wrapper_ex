defmodule ClaudeWrapper.PortSignalTest do
  @moduledoc """
  The default Port paths stop claude when their run ends early (#303): a
  one-shot timeout, a stream timeout or consumer halt, `DuplexSession.close/1`,
  the session owner's death, and the BEAM's death.

  The fake CLI is a Perl script: it records its pid, logs INT and TERM to a
  file, ignores stdin, and would otherwise run for 30 s. Perl is used because
  its signal handler replaces an ignored SIGINT, as Node's does, while a
  shell cannot trap a signal ignored at entry (a background job of a
  non-interactive shell starts with SIGINT ignored).
  """
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Query}
  alias ClaudeWrapper.DuplexSession.Adapter

  @moduletag :tmp_dir

  defp fake(dir) do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/usr/bin/perl
    $| = 1;
    my $log = $ENV{SIGNAL_LOG};
    sub note { open(my $fh, '>>', $log); print $fh "$_[0]\\n"; close($fh); }
    $SIG{INT} = sub { note("INT"); exit 0 };
    $SIG{TERM} = sub { note("TERM"); exit 0 };
    $SIG{PIPE} = 'IGNORE';
    note("start $$");
    print qq({"type":"system","subtype":"init","session_id":"s"}\\n);
    sleep 30;
    note("timeout");
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp config(dir, opts \\ []) do
    log = Path.join(dir, "signals.log")

    {Config.new([binary: fake(dir), env: [{"SIGNAL_LOG", log}]] ++ opts), log}
  end

  # Wait until the log has a line matching `pattern`; return the log.
  defp await_log(log, pattern, deadline_ms \\ 6_000) do
    deadline = System.monotonic_time(:millisecond) + deadline_ms
    do_await_log(log, pattern, deadline)
  end

  defp do_await_log(log, pattern, deadline) do
    contents =
      case File.read(log) do
        {:ok, contents} -> contents
        {:error, _} -> ""
      end

    cond do
      contents =~ pattern ->
        contents

      System.monotonic_time(:millisecond) > deadline ->
        flunk("#{inspect(pattern)} not logged; log: #{inspect(contents)}")

      true ->
        Process.sleep(25)
        do_await_log(log, pattern, deadline)
    end
  end

  test "a one-shot timeout sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 300)

    assert {:error, %ClaudeWrapper.Error{kind: :timeout}} = Query.execute(Query.new("p"), config)
    assert await_log(log, "INT") =~ "start"
  end

  test "a stream timeout sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 300)

    events = Query.new("p") |> Query.stream(config) |> Enum.to_list()
    assert List.last(events).data["error"] == "stream_truncated"
    await_log(log, "INT")
  end

  test "halting a stream early sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 10_000)

    assert [%{type: "system"}] = Query.new("p") |> Query.stream(config) |> Enum.take(1)
    await_log(log, "INT")
  end

  test "DuplexSession.close/1 on Adapter.Port signals a claude that ignores stdin EOF", %{
    tmp_dir: dir
  } do
    {config, log} = config(dir)

    {:ok, pid} =
      DuplexSession.start_link(config: config, adapter: Adapter.Port, args_override: [])

    await_log(log, "start")

    :ok = DuplexSession.close(pid)
    await_log(log, "INT")
  end

  test "an open DuplexSession on Adapter.Port is not signalled", %{tmp_dir: dir} do
    # Past the lifeline's close grace and INT step: nothing may arrive while
    # the session is open.
    {config, log} = config(dir)

    {:ok, pid} =
      DuplexSession.start_link(config: config, adapter: Adapter.Port, args_override: [])

    await_log(log, "start")

    Process.sleep(3_500)
    refute File.read!(log) =~ "INT"
    refute File.read!(log) =~ "TERM"
    assert DuplexSession.alive?(pid)

    DuplexSession.close(pid)
  end

  test "the session owner's death signals claude", %{tmp_dir: dir} do
    {config, log} = config(dir)
    owner = spawn(fn -> Process.sleep(:infinity) end)

    {:ok, _pid} =
      GenServer.start(DuplexSession,
        config: config,
        adapter: Adapter.Port,
        args_override: [],
        owner: owner
      )

    await_log(log, "start")
    Process.exit(owner, :kill)
    await_log(log, "INT")
  end

  test "quick one-shot exits keep stdout and exit status", %{tmp_dir: dir} do
    # A target that exits at once must not race the watchdog
    # (genagent/codex_wrapper_ex#134).
    quick = Path.join(dir, "quick")
    File.write!(quick, "#!/bin/sh\necho out\nexit 4\n")
    File.chmod!(quick, 0o755)

    for _ <- 1..50 do
      assert {:ok, {"out\n", 4}} = ClaudeWrapper.Runner.Port.run(quick, [], [], 5_000)
    end
  end

  describe "BEAM death" do
    # A disposable BEAM runs the wrapper against the fake and is SIGKILLed
    # once the fake has started; the shell supervisor (one-shot) or the
    # lifeline (duplex) outlives it and signals claude.
    defp run_in_doomed_beam(dir, code) do
      {config, log} = config(dir)
      paths = Path.wildcard(Path.join(Mix.Project.build_path(), "lib/*/ebin"))
      pa = Enum.flat_map(paths, &["-pa", &1])

      script = """
      config = ClaudeWrapper.Config.new(binary: #{inspect(config.binary)}, env: #{inspect(config.env)}, timeout: 60_000)
      #{code}
      Process.sleep(:infinity)
      """

      beam =
        Port.open({:spawn_executable, System.find_executable("elixir")}, [
          :binary,
          :exit_status,
          args: pa ++ ["-e", script]
        ])

      {:os_pid, beam_pid} = Port.info(beam, :os_pid)
      await_log(log, "start", 20_000)
      System.cmd("kill", ["-KILL", Integer.to_string(beam_pid)])
      log
    end

    @tag timeout: 60_000
    test "the one-shot supervisor signals claude", %{tmp_dir: dir} do
      log =
        run_in_doomed_beam(
          dir,
          "ClaudeWrapper.Query.execute(ClaudeWrapper.Query.new(\"p\"), config)"
        )

      await_log(log, "INT")
    end

    @tag timeout: 60_000
    test "the duplex lifeline signals claude", %{tmp_dir: dir} do
      log =
        run_in_doomed_beam(dir, """
        {:ok, _} = GenServer.start(ClaudeWrapper.DuplexSession, config: config,
          adapter: ClaudeWrapper.DuplexSession.Adapter.Port, args_override: [])
        """)

      await_log(log, "INT")
    end
  end
end
