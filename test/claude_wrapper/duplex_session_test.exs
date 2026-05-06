defmodule ClaudeWrapper.DuplexSessionTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.DuplexSession

  describe "split_lines/1" do
    test "empty buffer yields no complete lines" do
      assert {[], ""} = DuplexSession.split_lines("")
    end

    test "buffer with no newline is all trailing" do
      assert {[], "partial"} = DuplexSession.split_lines("partial")
    end

    test "single complete line, no trailing" do
      assert {["a"], ""} = DuplexSession.split_lines("a\n")
    end

    test "single complete line plus trailing partial" do
      assert {["a"], "b"} = DuplexSession.split_lines("a\nb")
    end

    test "multiple complete lines" do
      assert {["a", "b", "c"], ""} = DuplexSession.split_lines("a\nb\nc\n")
    end

    test "multiple complete lines plus trailing partial" do
      assert {["a", "b"], "partial"} = DuplexSession.split_lines("a\nb\npartial")
    end

    test "empty lines are preserved (handled by caller)" do
      assert {["", "a", ""], ""} = DuplexSession.split_lines("\na\n\n")
    end

    test "json payload with embedded special characters" do
      line = ~s({"type":"user","message":{"content":"line1\\nline2 with \\"quote\\""}})
      bin = line <> "\n"
      assert {[^line], ""} = DuplexSession.split_lines(bin)
    end
  end

  describe "build_args/1" do
    test "includes the duplex flag set" do
      args = DuplexSession.build_args([])

      assert "--input-format" in args
      assert "stream-json" in args
      assert "--output-format" in args
      assert "--include-partial-messages" in args
      assert "--verbose" in args
      assert "--print" in args
    end

    test "appends extra args after the base flags" do
      args = DuplexSession.build_args(["--max-turns", "1"])
      assert List.last(args) == "1"
      assert Enum.at(args, -2) == "--max-turns"
    end

    test "input-format and output-format are paired correctly" do
      args = DuplexSession.build_args([])
      input_idx = Enum.find_index(args, &(&1 == "--input-format"))
      output_idx = Enum.find_index(args, &(&1 == "--output-format"))

      assert Enum.at(args, input_idx + 1) == "stream-json"
      assert Enum.at(args, output_idx + 1) == "stream-json"
    end
  end
end
