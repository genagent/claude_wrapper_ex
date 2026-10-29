defmodule ClaudeWrapper.DuplexSession.AdapterPortTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession}
  alias ClaudeWrapper.DuplexSession.Adapter

  @moduletag :tmp_dir

  # A fake CLI that records two variables, then waits on stdin like claude.
  defp fake(dir) do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/bin/sh
    printf 'x=%s unset=%s\\n' "$PROBE_X" "${PROBE_UNSET-<unset>}" > "$ENV_LOG"
    exec cat >/dev/null
    """)

    File.chmod!(path, 0o755)
    path
  end

  test "Config.env string pairs reach the child, and false unsets", %{tmp_dir: dir} do
    log = Path.join(dir, "env.log")
    unset_name = "PROBE_UNSET"
    System.put_env(unset_name, "parent")
    on_exit(fn -> System.delete_env(unset_name) end)

    config =
      Config.new(
        binary: fake(dir),
        env: [{"PROBE_X", "1"}, {"ENV_LOG", log}, {unset_name, false}]
      )

    {:ok, pid} =
      DuplexSession.start_link(config: config, adapter: Adapter.Port, args_override: [])

    try do
      assert wait_for_file(log) == "x=1 unset=<unset>\n"
    after
      DuplexSession.stop(pid)
    end
  end

  defp wait_for_file(path, attempts \\ 100) do
    case File.read(path) do
      {:ok, contents} when contents != "" ->
        contents

      _ when attempts > 0 ->
        Process.sleep(20)
        wait_for_file(path, attempts - 1)

      _ ->
        flunk("#{path} was not written")
    end
  end
end
