defmodule ClaudeWrapper.EnvUnsetTest do
  @moduledoc """
  `Config.env` entries with `nil` or `false` remove an inherited variable on
  every spawn path (#309). The VM sets `PROBE_UNSET=parent`, so the module is
  not async.
  """
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, DuplexSession, Query, StreamEvent}
  alias ClaudeWrapper.DuplexSession.Adapter

  @moduletag :tmp_dir

  setup do
    System.put_env("PROBE_UNSET", "parent")
    on_exit(fn -> System.delete_env("PROBE_UNSET") end)
  end

  # Prints a result whose text is what the child saw, and appends it to
  # $ENV_LOG when that is set (for duplex sessions, which then wait).
  defp fake(dir) do
    path = Path.join(dir, "fake_claude")

    File.write!(path, """
    #!/bin/sh
    v="${PROBE_UNSET-<unset>}"
    [ -n "$ENV_LOG" ] && { echo "$v" > "$ENV_LOG"; exec cat >/dev/null; }
    printf '{"type":"result","subtype":"success","is_error":false,"session_id":"s","result":"%s"}\\n' "$v"
    """)

    File.chmod!(path, 0o755)
    path
  end

  defp config(dir, unset, extra \\ []),
    do: Config.new([binary: fake(dir), env: [{"PROBE_UNSET", unset}]] ++ extra)

  defp execute(config, opts \\ []) do
    {:ok, %{result: result}} = Query.execute(Query.new("p"), config, opts)
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

  for unset <- [nil, false] do
    describe "#{inspect(unset)} unsets" do
      test "Query.execute and Query.stream on Runner.Port", %{tmp_dir: dir} do
        assert execute(config(dir, unquote(unset))) == "<unset>"
        assert stream(config(dir, unquote(unset))) == "<unset>"
      end

      test "Config.exec/2", %{tmp_dir: dir} do
        {out, 0} = Config.exec(config(dir, unquote(unset)), [])
        assert out =~ ~s("result":"<unset>")
      end

      test "DuplexSession on Adapter.Port", %{tmp_dir: dir} do
        assert duplex(dir, config(dir, unquote(unset)), Adapter.Port) == "<unset>"
      end

      @tag :forcola_evidence
      test "every Runner.Forcola path", %{tmp_dir: dir} do
        config = config(dir, unquote(unset), runner: ClaudeWrapper.Runner.Forcola)

        assert execute(config) == "<unset>"
        assert stream(config) == "<unset>"
        assert execute(config, session_observer: {self(), make_ref()}) == "<unset>"
        assert execute(config, execution_observer: {self(), make_ref()}) == "<unset>"
      end

      @tag :forcola_evidence
      test "DuplexSession on Adapter.Forcola", %{tmp_dir: dir} do
        assert duplex(dir, config(dir, unquote(unset)), Adapter.Forcola) == "<unset>"
      end
    end
  end

  test "a set value still reaches the child, and false is normalized to nil", %{tmp_dir: dir} do
    config = Config.new(binary: fake(dir), env: [{"PROBE_UNSET", "mine"}, {"OTHER", false}])
    assert config.env == [{"PROBE_UNSET", "mine"}, {"OTHER", nil}]
    assert execute(config) == "mine"
  end

  test "invalid entries raise" do
    for env <- [[{"", "x"}], [{"A=B", "x"}], [{:atom, "x"}], [{"A", 1}], ["A=1"], :nope] do
      assert_raise ArgumentError, fn -> Config.new(env: env) end
    end
  end
end
