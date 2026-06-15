defmodule ClaudeWrapper.Commands.AutoModeTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.AutoMode

  describe "module surface" do
    test "is loaded and exposes the expected functions" do
      Code.ensure_loaded!(AutoMode)
      funcs = AutoMode.__info__(:functions)

      assert {:config, 1} in funcs
      assert {:defaults, 1} in funcs
      assert {:critique, 2} in funcs

      # @doc false builders are public for arg-composition testing.
      assert {:config_args, 0} in funcs
      assert {:defaults_args, 0} in funcs
      assert {:critique_args, 1} in funcs
    end
  end

  describe "config_args/0" do
    test "emits the bare subcommand" do
      assert AutoMode.config_args() == ["auto-mode", "config"]
    end
  end

  describe "defaults_args/0" do
    test "emits the bare subcommand" do
      assert AutoMode.defaults_args() == ["auto-mode", "defaults"]
    end
  end

  describe "critique_args/1" do
    test "defaults to the bare subcommand with no model" do
      assert AutoMode.critique_args([]) == ["auto-mode", "critique"]
    end

    test "emits --model when set" do
      assert AutoMode.critique_args(model: "opus") ==
               ["auto-mode", "critique", "--model", "opus"]
    end

    test "omits --model when nil" do
      refute "--model" in AutoMode.critique_args(model: nil)
    end
  end
end
