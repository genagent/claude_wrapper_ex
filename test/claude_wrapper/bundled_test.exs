defmodule ClaudeWrapper.BundledTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Bundled, Config}

  describe "path/0 and pinned_version/0 (pure)" do
    test "path is an absolute priv/bin/claude under the app" do
      path = Bundled.path()
      assert Path.type(path) == :absolute
      assert String.ends_with?(path, Path.join(["priv", "bin", "claude"]))
    end

    test "pinned_version is a concrete version string" do
      # The CLI reports the version as the first token of --version output.
      assert {:ok, _} =
               ClaudeWrapper.CliVersion.parse("#{Bundled.pinned_version()} (Claude Code)")
    end

    test "installed? is a boolean and installed_version is nil when absent" do
      # In a clean env the bundled binary is not present.
      refute Bundled.installed?()
      assert Bundled.installed_version() == nil
    end
  end

  describe "Config resolution" do
    test ":bundled resolves to the bundled path without touching the network" do
      assert Config.new(binary: :bundled).binary == Bundled.path()
    end

    test "an explicit path is used verbatim" do
      assert Config.new(binary: "/custom/claude").binary == "/custom/claude"
    end

    test "nil falls back to PATH/CLAUDE_CLI discovery" do
      assert Config.new(binary: nil).binary == Config.find_binary()
    end
  end

  describe "uninstall/0" do
    test "is idempotent when nothing is installed" do
      assert Bundled.uninstall() == :ok
      assert Bundled.uninstall() == :ok
      refute Bundled.installed?()
    end
  end

  describe "live install" do
    @tag :integration
    test "ensure!/0 installs the pinned binary and Config can drive it" do
      on_exit(fn -> Bundled.uninstall() end)

      path = Bundled.ensure!()
      assert File.exists?(path)

      assert ClaudeWrapper.CliVersion.to_string(Bundled.installed_version()) ==
               Bundled.pinned_version()
    end
  end
end
