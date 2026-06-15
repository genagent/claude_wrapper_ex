defmodule ClaudeWrapper.Commands.InstallTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.Commands.Install

  # These tests exercise only arg composition via the @doc false builder.
  # They never invoke the real `claude install`, which mutates the system.

  describe "module surface" do
    test "is loaded and exposes the expected functions" do
      Code.ensure_loaded!(Install)
      funcs = Install.__info__(:functions)

      assert {:install, 1} in funcs
      assert {:install, 2} in funcs
      assert {:install_args, 1} in funcs
    end
  end

  describe "install_args/1" do
    test "defaults to the bare subcommand" do
      assert Install.install_args([]) == ["install"]
    end

    test "passes target as a positional" do
      assert Install.install_args(target: "stable") == ["install", "stable"]
    end

    test "emits --force before the target positional" do
      assert Install.install_args(target: "latest", force: true) ==
               ["install", "--force", "latest"]
    end

    test "emits --force alone when no target is given" do
      assert Install.install_args(force: true) == ["install", "--force"]
    end

    test "omits --force when falsy" do
      assert Install.install_args(force: false) == ["install"]
    end
  end
end
