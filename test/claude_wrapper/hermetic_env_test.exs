defmodule ClaudeWrapper.HermeticEnvTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Query, StreamEvent}

  @fake Path.expand("fixtures/fake_claude", __DIR__ |> Path.dirname())

  defmodule EnvCaptureAdapter do
    @moduledoc false
    @behaviour ClaudeWrapper.DuplexSession.Adapter

    @impl true
    def open(opts) do
      send(Keyword.fetch!(opts, :test_pid), {:spawn_env, Keyword.fetch!(opts, :config).env})
      {:ok, make_ref()}
    end

    @impl true
    def command(_handle, _iodata), do: :ok

    @impl true
    def close(_handle), do: :ok
  end

  defp config(env \\ []),
    do: Config.new(binary: @fake, env: [{"FAKE_CLAUDE_SCENARIO", "env_probe"} | env])

  defp run(opts, env \\ []) do
    {:ok, result} = "p" |> Query.new() |> Query.apply_opts(opts) |> Query.execute(config(env))
    result.result
  end

  describe "execute/2" do
    test "both hermetic scopes turn auto-memory off" do
      assert run(hermetic: :full) == "auto_memory_off=1"
      assert run(hermetic: :project) == "auto_memory_off=1"
    end

    test "a non-hermetic query leaves the environment alone" do
      assert run([]) == "auto_memory_off=<unset>"
    end

    test "a caller's own Config.env value wins" do
      assert run([hermetic: :full], [{"CLAUDE_CODE_DISABLE_AUTO_MEMORY", "0"}]) ==
               "auto_memory_off=0"
    end
  end

  # Observed execution needs a runner that supports it.
  @tag :forcola_evidence
  test "execute/3 sets it too" do
    query = "p" |> Query.new() |> Query.hermetic(:full)
    config = %{config() | runner: ClaudeWrapper.Runner.Forcola}

    assert {:ok, %{result: "auto_memory_off=1"}} =
             Query.execute(query, config, session_observer: {self(), make_ref()})
  end

  test "stream/2 sets it" do
    events =
      "p" |> Query.new() |> Query.hermetic(:full) |> Query.stream(config()) |> Enum.to_list()

    assert %StreamEvent{data: %{"result" => "auto_memory_off=1"}} =
             Enum.find(events, &StreamEvent.result?/1)
  end

  test "a DuplexSession started with a hermetic query sets it" do
    query = "" |> Query.new() |> Query.hermetic(:full)

    {:ok, _pid} =
      DuplexSession.start_link(
        config: Config.new(binary: @fake),
        query: query,
        adapter: EnvCaptureAdapter,
        adapter_opts: [test_pid: self()]
      )

    assert_receive {:spawn_env, [{"CLAUDE_CODE_DISABLE_AUTO_MEMORY", "1"}]}
  end
end
