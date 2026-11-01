defmodule ClaudeWrapper.SessionSelectorTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, Session}

  @fake Path.expand("../fixtures/fake_claude", __DIR__)
  @uuid "44444444-4444-4444-8444-444444444444"

  # Two turns against the fake CLI; returns each turn's argv.
  defp two_turns(session_opts) do
    calls = Path.join(System.tmp_dir!(), "session-sel-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(calls) end)

    config =
      Config.new(
        binary: @fake,
        env: [{"FAKE_CLAUDE_SCENARIO", "object"}, {"FAKE_CLAUDE_CALLS", calls}]
      )

    session = Session.new(config, session_opts)
    {:ok, session, _} = Session.send(session, "turn 1")
    {:ok, _session, _} = Session.send(session, "turn 2")

    calls |> File.read!() |> String.split("\n", trim: true)
  end

  for {label, opts} <- [
        {"session_id", [session_id: @uuid]},
        {"continue_session", [continue_session: true]},
        {"resume", [resume: "older-session"]}
      ] do
    test "a session started with #{label} sends only --resume after the first turn" do
      [_turn1, turn2] = two_turns(unquote(opts))

      assert turn2 =~ "--resume fake-session"
      refute turn2 =~ "--session-id"
      refute turn2 =~ "--continue"
      refute turn2 =~ "older-session"
    end
  end

  test "the first turn still uses the starting selector" do
    [turn1, _] = two_turns(session_id: @uuid)
    assert turn1 =~ "--session-id #{@uuid}"
    refute turn1 =~ "--resume"
  end

  # Two turns where the second passes per-call options; returns each argv.
  defp two_turns_with(session_opts, turn2_opts) do
    calls = Path.join(System.tmp_dir!(), "session-snap-#{System.unique_integer([:positive])}")
    on_exit(fn -> File.rm(calls) end)

    config =
      Config.new(
        binary: @fake,
        env: [{"FAKE_CLAUDE_SCENARIO", "object"}, {"FAKE_CLAUDE_CALLS", calls}]
      )

    session = Session.new(config, session_opts)
    {:ok, session, _} = Session.send(session, "turn 1")
    {:ok, _session, _} = Session.send(session, "turn 2", turn2_opts)

    calls |> File.read!() |> String.split("\n", trim: true)
  end

  # Argv regression only: the fake CLI cannot show which system prompt the
  # real CLI sends to the API (#328).
  describe "changing the system prompt on a resumed turn (#328)" do
    test "turn two carries --resume, the new prompt and --system-prompt-snapshot off" do
      [turn1, turn2] =
        two_turns_with([system_prompt: "first-prompt"],
          system_prompt: "second-prompt",
          system_prompt_snapshot: :off
        )

      assert turn1 =~ "--system-prompt first-prompt"
      refute turn1 =~ "--system-prompt-snapshot"

      assert turn2 =~ "--resume fake-session"
      assert turn2 =~ "--system-prompt second-prompt"
      refute turn2 =~ "first-prompt"
      assert turn2 =~ "--system-prompt-snapshot off"
    end

    test "a per-call snapshot value overrides the session's" do
      [turn1, turn2] = two_turns_with([system_prompt_snapshot: :on], system_prompt_snapshot: :off)

      assert turn1 =~ "--system-prompt-snapshot on"
      assert turn2 =~ "--system-prompt-snapshot off"
      refute turn2 =~ "--system-prompt-snapshot on"
    end

    test "a session-level :off applies to every turn, and unset emits nothing" do
      [turn1, turn2] = two_turns_with([system_prompt_snapshot: :off], [])
      assert turn1 =~ "--system-prompt-snapshot off"
      assert turn2 =~ "--system-prompt-snapshot off"

      [turn1, turn2] = two_turns_with([], system_prompt: "changed")
      refute turn1 =~ "--system-prompt-snapshot"
      refute turn2 =~ "--system-prompt-snapshot"
    end
  end
end
