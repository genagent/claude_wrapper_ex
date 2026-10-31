defmodule ClaudeWrapper.ChildEnvTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.ChildEnv

  @release %{
    "RELEASE_ROOT" => "/opt/rel",
    "RELEASE_COOKIE" => "secret",
    "RELEASE_NODE" => "relprobe",
    "BINDIR" => "/opt/rel/erts-17.1.1/bin",
    "ROOTDIR" => "/opt/rel",
    "HOME" => "/home/u",
    "PATH" =>
      "/opt/rel/erts-17.1.1/bin:/opt/rel/bin/:/usr/local/bin:/opt/rel/bin-tools:/opt/rel/bin/extra:/usr/bin"
  }

  test "outside a release nothing changes" do
    parent = Map.drop(@release, ["RELEASE_ROOT"])
    assert ChildEnv.release_scrub(parent) == []
    assert ChildEnv.apply([{"A", "1"}], parent) == [{"A", "1"}]
  end

  test "inside a release, boot variables are unset and release PATH entries removed" do
    assert ChildEnv.release_scrub(@release) == [
             {"BINDIR", nil},
             {"RELEASE_COOKIE", nil},
             {"RELEASE_NODE", nil},
             {"RELEASE_ROOT", nil},
             {"ROOTDIR", nil},
             {"PATH", "/usr/local/bin:/opt/rel/bin-tools:/opt/rel/bin/extra:/usr/bin"}
           ]
  end

  test "only <root>/erts-<vsn>/bin itself is removed" do
    parent = %{
      @release
      | "PATH" => "/opt/rel/erts-1/bin/x:/opt/rel/erts-/bin:/opt/rel/erts-1/bin"
    }

    assert {"PATH", "/opt/rel/erts-1/bin/x:/opt/rel/erts-/bin"} in ChildEnv.release_scrub(parent)
  end

  test "Config.env applies on top: a scrubbed name can be set, and its PATH is cleaned" do
    env = ChildEnv.apply([{"RELEASE_NODE", "mine"}, {"PATH", "/opt/rel/bin:/bin"}], @release)

    assert {"RELEASE_NODE", "mine"} in env
    assert {"RELEASE_COOKIE", nil} in env
    assert {"PATH", "/bin"} in env
    assert Enum.count(env, &(elem(&1, 0) == "PATH")) == 1
  end

  test "boot_var?/1" do
    assert ChildEnv.boot_var?("RELEASE_VM_ARGS")
    assert ChildEnv.boot_var?("BINDIR")
    refute ChildEnv.boot_var?("RELEASED")
    refute ChildEnv.boot_var?("PATH")
  end
end

defmodule ClaudeWrapper.ChildEnvSpawnTest do
  @moduledoc """
  Every spawn path applies the release scrub (#310). The VM environment is
  changed to look like a release, so this module is not async.
  """
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, DuplexSession, Query, StreamEvent}
  alias ClaudeWrapper.DuplexSession.Adapter

  @moduletag :tmp_dir

  setup do
    saved = Map.take(System.get_env(), ["PATH"])
    path = System.get_env("PATH")

    System.put_env(%{
      "RELEASE_ROOT" => "/opt/fake-rel",
      "RELEASE_COOKIE" => "secret",
      "BINDIR" => "/opt/fake-rel/erts-1/bin",
      "PATH" => "/opt/fake-rel/erts-1/bin:/opt/fake-rel/bin:" <> path
    })

    on_exit(fn ->
      Enum.each(["RELEASE_ROOT", "RELEASE_COOKIE", "BINDIR"], &System.delete_env/1)
      System.put_env(saved)
    end)
  end

  defp fake(dir) do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/bin/sh
    v="root=${RELEASE_ROOT-unset} cookie=${RELEASE_COOKIE-unset} bindir=${BINDIR-unset} relpath=$(echo "$PATH" | grep -c fake-rel)"
    [ -n "$ENV_LOG" ] && { echo "$v" > "$ENV_LOG"; exec cat >/dev/null; }
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"%s"}\\n' "$v"
    """)

    File.chmod!(path, 0o755)
    path
  end

  @scrubbed "root=unset cookie=unset bindir=unset relpath=0"

  defp execute(config) do
    {:ok, %{result: result}} = Query.execute(Query.new("p"), config)
    result
  end

  defp stream(config) do
    Query.new("p")
    |> Query.stream(config)
    |> Enum.find_value(fn
      %StreamEvent{type: "result", data: d} -> d["result"]
      _ -> nil
    end)
  end

  defp duplex(dir, config, adapter) do
    log = Path.join(dir, "env.log")
    config = %{config | env: config.env ++ [{"ENV_LOG", log}]}
    {:ok, pid} = DuplexSession.start_link(config: config, adapter: adapter, args_override: [])
    value = wait_for_file(log)
    DuplexSession.close(pid)
    value
  end

  defp wait_for_file(path, attempts \\ 200) do
    case File.read(path) do
      {:ok, contents} when contents != "" -> String.trim(contents)
      _ when attempts > 0 -> Process.sleep(20) && wait_for_file(path, attempts - 1)
      _ -> flunk("#{path} was not written")
    end
  end

  test "Runner.Port, Config.exec and Adapter.Port scrub", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir))

    assert execute(config) == @scrubbed
    assert stream(config) == @scrubbed
    assert {out, 0} = Config.exec(config, [])
    assert out =~ @scrubbed
    assert duplex(dir, config, Adapter.Port) == @scrubbed
  end

  @tag :forcola_evidence
  test "Runner.Forcola and Adapter.Forcola scrub", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir), runner: ClaudeWrapper.Runner.Forcola)

    assert execute(config) == @scrubbed
    assert stream(config) == @scrubbed
    assert duplex(dir, config, Adapter.Forcola) == @scrubbed
  end

  test "release_env: :inherit passes the release environment through", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir), release_env: :inherit)

    assert execute(config) ==
             "root=/opt/fake-rel cookie=secret bindir=/opt/fake-rel/erts-1/bin relpath=1"
  end

  test "a Config.env value for a scrubbed name wins", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir), env: [{"RELEASE_COOKIE", "mine"}])
    assert execute(config) =~ "cookie=mine"
  end
end
