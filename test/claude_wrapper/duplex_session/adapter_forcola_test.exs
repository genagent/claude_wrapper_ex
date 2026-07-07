defmodule ClaudeWrapper.DuplexSession.Adapter.ForcolaTest do
  use ExUnit.Case, async: true

  # Drives the real forcola shim; skipped when it is not resolvable.
  @moduletag :forcola

  alias ClaudeWrapper.{Config, DuplexSession}
  alias ClaudeWrapper.DuplexSession.Adapter.Forcola

  describe "adapter callbacks" do
    test "forwards a stdout line to the owner as {handle, {:data, line}}" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())

      # cat echoes stdin; the session frames writes as [json, ?\n].
      :ok = Forcola.command(handle, [~s({"type":"user"}), ?\n])

      assert_receive {^handle, {:data, "{\"type\":\"user\"}\n"}}, 2_000

      :ok = Forcola.close(handle)
    end

    test "close/1 terminates the translator" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())

      assert Process.alive?(handle)
      :ok = Forcola.close(handle)
      refute Process.alive?(handle)
    end

    test "close/1 on an already-dead handle is idempotent" do
      config = Config.new(binary: System.find_executable("cat"))
      {:ok, handle} = Forcola.open(config: config, args: [], owner: self())
      :ok = Forcola.close(handle)
      assert :ok = Forcola.close(handle)
    end
  end

  describe "driving a DuplexSession through the adapter" do
    setup do
      # A minimal fake claude: for each stdin line, emit an assistant
      # message and a terminal result event.
      script = """
      #!/bin/sh
      while IFS= read -r line; do
        printf '{"type":"assistant","message":{"content":"ok"},"session_id":"s1"}\\n'
        printf '{"type":"result","subtype":"success","result":"done","is_error":false,"session_id":"s1"}\\n'
      done
      """

      path = Path.join(System.tmp_dir!(), "fake_claude_#{System.unique_integer([:positive])}.sh")
      File.write!(path, script)
      File.chmod!(path, 0o755)
      on_exit(fn -> File.rm(path) end)

      {:ok, binary: path}
    end

    test "completes turns and parses the result event", %{binary: binary} do
      config = Config.new(binary: binary)

      {:ok, pid} =
        DuplexSession.start_link(config: config, adapter: Forcola, args_override: [])

      assert {:ok, %ClaudeWrapper.Result{result: "done", session_id: "s1"}} =
               DuplexSession.send(pid, "hi", 5_000)

      assert {:ok, %ClaudeWrapper.Result{}} = DuplexSession.send(pid, "again", 5_000)

      :ok = DuplexSession.stop(pid)
    end
  end
end
