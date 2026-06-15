defmodule ClaudeWrapper.Commands.UpdateTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.Update

  # These tests exercise only arg composition via the @doc false builder.
  # They never invoke the real `claude update`, which mutates the system.

  describe "module surface" do
    test "is loaded and exposes the expected functions" do
      Code.ensure_loaded!(Update)
      funcs = Update.__info__(:functions)

      assert {:update, 1} in funcs
      assert {:update_args, 0} in funcs
    end
  end

  describe "update_args/0" do
    test "emits the bare subcommand with no options" do
      assert Update.update_args() == ["update"]
    end
  end
end
