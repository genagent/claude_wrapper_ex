defmodule ClaudeWrapper.RetryTest do
  @moduledoc "A retry must not repeat a turn that may have run tools (#317)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Error, Query, Retry, Runner}

  @moduletag :tmp_dir

  @fixture Path.expand("../fixtures/fake_claude", __DIR__)
  @fast [base_delay_ms: 1, jitter: false]
  @always [retry_on: &__MODULE__.always/1]

  def always(_error), do: true

  # A fake claude that records "start" per attempt, runs `body`, and records
  # "side-effect" if it gets that far.
  defp fake(dir, body) do
    path = Path.join(dir, "fake_claude")
    marks = Path.join(dir, "marks")

    File.write!(path, """
    #!/bin/sh
    echo start >> '#{marks}'
    #{body}
    echo side-effect >> '#{marks}'
    """)

    File.chmod!(path, 0o755)
    {path, marks}
  end

  defp marks(path) do
    case File.read(path) do
      {:ok, text} -> String.split(text, "\n", trim: true)
      {:error, :enoent} -> []
    end
  end

  test "a nonzero exit is not retried by default", %{tmp_dir: dir} do
    {binary, marks} = fake(dir, "echo boom >&2; exit 1")

    assert {:error, %Error{kind: :command_failed}} =
             Retry.execute(Query.new("p"), Config.new(binary: binary), @fast)

    assert marks(marks) == ["start"]
  end

  test "a caller retry_on can opt in to retrying a nonzero exit", %{tmp_dir: dir} do
    {binary, marks} = fake(dir, "exit 1")

    assert {:error, %Error{kind: :command_failed}} =
             Retry.execute(Query.new("p"), Config.new(binary: binary), @fast ++ @always)

    assert Enum.count(marks(marks), &(&1 == "start")) == 4
  end

  test "a timeout under Runner.Port is not retried even when retry_on allows it",
       %{tmp_dir: dir} do
    {binary, marks} = fake(dir, "sleep 2")
    config = Config.new(binary: binary, timeout: 300, runner: Runner.Port)

    assert {:error, %Error{kind: :timeout}} =
             Retry.execute(Query.new("p"), config, @fast ++ @always)

    assert marks(marks) == ["start"]
  end

  test "a query with a pinned --session-id is not retried", %{tmp_dir: dir} do
    calls = Path.join(dir, "calls")

    config =
      Config.new(
        binary: @fixture,
        env: [{"FAKE_CLAUDE_SCENARIO", "api_429"}, {"FAKE_CLAUDE_CALLS", calls}]
      )

    query = "p" |> Query.new() |> Query.session_id("44444444-4444-4444-8444-444444444444")

    assert {:error, %Error{kind: :api_error}} = Retry.execute(query, config, @fast ++ @always)
    assert calls |> File.read!() |> String.split("\n", trim: true) |> length() == 1
  end

  @tag :forcola_evidence
  test "with Runner.Forcola, an opted-in timeout is retried after the group was killed",
       %{tmp_dir: dir} do
    {binary, marks} = fake(dir, "sleep 2")

    config =
      Config.new(binary: binary, timeout: 300, runner: Runner.Forcola, runner_options: [])

    assert {:error, %Error{kind: :timeout}} =
             Retry.execute(Query.new("p"), config, [max_retries: 1] ++ @fast ++ @always)

    # Each attempt was killed at its deadline before the next one started, so
    # neither reached its side effect.
    Process.sleep(2_500)
    assert marks(marks) == ["start", "start"]
  end
end
