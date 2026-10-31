defmodule ClaudeWrapper.DuplexSession.BroadcastTest do
  @moduledoc "Every stream-json frame reaches subscribers (#322)."
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{DuplexSession, RateLimitObservation}

  setup do
    {:ok, session, stub} = ClaudeWrapper.Test.start_session()
    :ok = DuplexSession.subscribe(session)
    {:ok, session: session, stub: stub}
  end

  test "system frames other than init arrive as {:system, subtype, msg}", %{stub: stub} do
    frames = [
      %{"type" => "system", "subtype" => "compact_boundary", "compact_metadata" => %{}},
      %{"type" => "system", "subtype" => "hook_response", "hook_name" => "h"},
      %{"type" => "system", "subtype" => "task_notification", "task_id" => "t"},
      %{"type" => "system", "subtype" => "status", "permissionMode" => "plan"}
    ]

    ClaudeWrapper.Test.emit(stub, frames)

    for %{"subtype" => subtype} = frame <- frames do
      assert_receive {:claude, {:system, ^subtype, ^frame}}
    end
  end

  test "init keeps its own event", %{stub: stub} do
    ClaudeWrapper.Test.emit(stub, [
      %{"type" => "system", "subtype" => "init", "session_id" => "s-9"}
    ])

    assert_receive {:claude, {:system_init, "s-9"}}
    refute_received {:claude, {:system, "init", _}}
  end

  test "a rate_limit_event arrives parsed as {:rate_limit, observation}", %{stub: stub} do
    ClaudeWrapper.Test.emit(stub, [
      %{
        "type" => "rate_limit_event",
        "rate_limit_info" => %{
          "status" => "allowed_warning",
          "rateLimitType" => "five_hour",
          "unifiedWindows" => %{"five_hour" => %{"utilization" => 0.9}}
        }
      }
    ])

    assert_receive {:claude,
                    {:rate_limit,
                     %RateLimitObservation{
                       status: "allowed_warning",
                       rate_limit_type: "five_hour",
                       unified_windows: %{"five_hour" => %{"utilization" => 0.9}}
                     }}}
  end

  test "an unparseable rate_limit_event and unknown types arrive as {:raw, msg}", %{stub: stub} do
    bad = %{"type" => "rate_limit_event", "rate_limit_info" => %{}}
    unknown = %{"type" => "command_lifecycle", "phase" => "start"}
    ClaudeWrapper.Test.emit(stub, [bad, unknown])

    assert_receive {:claude, {:raw, ^bad}}
    assert_receive {:claude, {:raw, ^unknown}}
  end

  test "frames arrive in order around an assistant message", %{stub: stub} do
    ClaudeWrapper.Test.emit(stub, [
      %{"type" => "system", "subtype" => "compact_boundary"},
      %{"type" => "assistant", "message" => %{"content" => []}}
    ])

    assert_receive {:claude, {:system, "compact_boundary", _}}
    assert_receive {:claude, {:assistant, _}}
  end
end
