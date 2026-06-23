defmodule ClaudeWrapper.ResultTest do
  use ExUnit.Case, async: true

  doctest ClaudeWrapper.Result

  alias ClaudeWrapper.Result

  defp result(extra), do: %Result{result: "", extra: extra}

  describe "usage/1" do
    test "normalizes a full usage map; total excludes cache reads" do
      r =
        result(%{
          "usage" => %{
            "input_tokens" => 10,
            "output_tokens" => 5,
            "cache_creation_input_tokens" => 3,
            "cache_read_input_tokens" => 100
          }
        })

      assert Result.usage(r) == %{
               input: 10,
               output: 5,
               cache_creation: 3,
               cache_read: 100,
               total: 18
             }
    end

    test "missing / non-integer fields count as zero" do
      assert Result.usage(result(%{"usage" => %{"output_tokens" => 7}})) == %{
               input: 0,
               output: 7,
               cache_creation: 0,
               cache_read: 0,
               total: 7
             }
    end

    test "returns nil when there is no usage map" do
      assert Result.usage(result(%{})) == nil
      assert Result.usage(result(%{"usage" => "nope"})) == nil
    end
  end

  describe "stop_reason/1" do
    test "returns the reason string" do
      assert Result.stop_reason(result(%{"stop_reason" => "end_turn"})) == "end_turn"
      assert Result.stop_reason(result(%{"stop_reason" => "max_tokens"})) == "max_tokens"
    end

    test "returns nil when absent or non-string" do
      assert Result.stop_reason(result(%{})) == nil
      assert Result.stop_reason(result(%{"stop_reason" => nil})) == nil
    end
  end

  describe "structured_output/1" do
    test "returns a JSON object" do
      assert Result.structured_output(result(%{"structured_output" => %{"a" => 1}})) ==
               %{"a" => 1}
    end

    test "returns a JSON array" do
      assert Result.structured_output(result(%{"structured_output" => [1, 2]})) == [1, 2]
    end

    test "returns nil when absent" do
      assert Result.structured_output(result(%{})) == nil
    end
  end

  describe "from_json/1 routes the extras these accessors read" do
    test "usage / stop_reason / structured_output survive into extra" do
      r =
        Result.from_json(%{
          "result" => "hi",
          "session_id" => "s1",
          "usage" => %{"input_tokens" => 1, "output_tokens" => 2},
          "stop_reason" => "end_turn",
          "structured_output" => %{"ok" => true}
        })

      assert r.result == "hi"
      assert Result.stop_reason(r) == "end_turn"
      assert Result.structured_output(r) == %{"ok" => true}
      assert Result.usage(r).total == 3
    end
  end
end
