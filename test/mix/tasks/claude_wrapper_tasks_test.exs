defmodule Mix.Tasks.ClaudeWrapperTasksTest do
  # Not async: shares the on-disk `Bundled.path()` fixture across tests.
  use ExUnit.Case, async: false

  import ExUnit.CaptureIO

  alias ClaudeWrapper.Bundled
  alias Mix.Tasks.ClaudeWrapper.Install
  alias Mix.Tasks.ClaudeWrapper.Path, as: PathTask
  alias Mix.Tasks.ClaudeWrapper.Uninstall

  setup do
    on_exit(fn -> Bundled.uninstall() end)
    :ok
  end

  defp write_fake_binary(version_output) do
    path = Bundled.path()
    File.mkdir_p!(Path.dirname(path))
    File.write!(path, "#!/bin/sh\necho \"#{version_output}\"\n")
    File.chmod!(path, 0o755)
    path
  end

  describe "claude_wrapper.uninstall" do
    test "reports removal and deletes the binary when one is present" do
      path = write_fake_binary("1.2.3 (Claude Code)")

      output =
        capture_io(fn ->
          Uninstall.run([])
        end)

      assert output =~ "removed bundled claude at #{path}"
      refute Bundled.installed?()
    end

    test "reports nothing to remove when absent" do
      refute Bundled.installed?()

      output =
        capture_io(fn ->
          Uninstall.run([])
        end)

      assert output =~ "no bundled claude to remove (#{Bundled.path()})"
    end
  end

  describe "claude_wrapper.path" do
    test "reports not installed when absent" do
      refute Bundled.installed?()

      output =
        capture_io(fn ->
          PathTask.run([])
        end)

      assert output =~ Bundled.path()
      assert output =~ "[not installed]"
    end

    test "reports the parsed version when installed" do
      write_fake_binary("9.9.9 (Claude Code)")

      output =
        capture_io(fn ->
          PathTask.run([])
        end)

      assert output =~ "[installed (9.9.9)]"
    end

    test "reports version unknown when the binary's --version can't be parsed" do
      write_fake_binary("not a version")

      output =
        capture_io(fn ->
          PathTask.run([])
        end)

      assert output =~ "[installed (version unknown)]"
    end
  end

  describe "claude_wrapper.install" do
    @tag :integration
    test "installs the pinned binary over the network" do
      output =
        capture_io(fn ->
          Install.run([])
        end)

      assert output =~ Bundled.pinned_version()
      assert Bundled.installed?()
    end
  end
end
