defmodule ClaudeWrapper.ForcolaSignalTest do
  @moduledoc """
  Every Forcola path sends SIGINT to claude's process group first, then
  SIGTERM after a 2 s grace (#307): one-shot, observed and evidenced
  timeouts, stream timeouts and early halts, and `DuplexSession.close/1` on
  `Adapter.Forcola`.

  The fake CLI is the Perl script from `ClaudeWrapper.PortSignalTest`: it
  logs INT and TERM to a file and would otherwise run for 30 s. With
  `IGNORE_INT` set it ignores SIGINT, standing in for a CLI with no handler.
  """
  use ExUnit.Case, async: true

  @moduletag :forcola
  @moduletag :tmp_dir

  alias ClaudeWrapper.{Config, DuplexSession, Error, Query, Runner}
  alias ClaudeWrapper.DuplexSession.Adapter

  defp fake(dir) do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/usr/bin/perl
    $| = 1;
    my $log = $ENV{SIGNAL_LOG};
    sub note { open(my $fh, '>>', $log); print $fh "$_[0]\\n"; close($fh); }
    if ($ENV{IGNORE_INT}) { $SIG{INT} = 'IGNORE'; } else { $SIG{INT} = sub { note("INT"); exit 0 }; }
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
    {env, opts} = Keyword.pop(opts, :env, [])

    config =
      Config.new(
        [binary: fake(dir), env: [{"SIGNAL_LOG", log} | env], runner: Runner.Forcola] ++ opts
      )

    {config, log}
  end

  defp await_log(log, pattern, deadline_ms \\ 8_000) do
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

    assert {:error, %Error{kind: :timeout}} = Query.execute(Query.new("p"), config)
    assert await_log(log, "INT") =~ "start"
    refute File.read!(log) =~ "TERM"
  end

  test "an observed one-shot timeout sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 300)

    assert {:error, %Error{kind: :timeout}} =
             Query.execute(Query.new("p"), config, session_observer: {self(), make_ref()})

    await_log(log, "INT")
  end

  test "an evidenced one-shot timeout sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 300)
    ref = make_ref()

    assert {:error, %Error{kind: :timeout}} =
             Query.execute(Query.new("p"), config, execution_observer: {self(), ref})

    assert_receive {^ref, %ClaudeWrapper.ExecutionEvidence{}}, 10_000
    await_log(log, "INT")
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

  test "DuplexSession.close/1 on Adapter.Forcola sends INT", %{tmp_dir: dir} do
    {config, log} = config(dir)

    {:ok, pid} =
      DuplexSession.start_link(config: config, adapter: Adapter.Forcola, args_override: [])

    await_log(log, "start")
    :ok = DuplexSession.close(pid)
    await_log(log, "INT")
  end

  test "a CLI that ignores INT is stopped by TERM after the grace", %{tmp_dir: dir} do
    {config, log} = config(dir, timeout: 300, env: [{"IGNORE_INT", "1"}])
    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :timeout}} = Query.execute(Query.new("p"), config)

    await_log(log, "TERM")
    assert System.monotonic_time(:millisecond) - started >= 2_000
  end

  test "a caller's interrupt pair replaces the default", %{tmp_dir: dir} do
    {config, log} =
      config(dir,
        timeout: 300,
        env: [{"IGNORE_INT", "1"}],
        runner_options: [interrupt_signal: :int, interrupt_grace_ms: 100]
      )

    started = System.monotonic_time(:millisecond)

    assert {:error, %Error{kind: :timeout}} =
             Query.execute(Query.new("p"), config, execution_observer: {self(), make_ref()})

    await_log(log, "TERM")
    assert System.monotonic_time(:millisecond) - started < 2_000
  end
end
