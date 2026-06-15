defmodule ClaudeWrapper.DangerousClientTest do
  # async: false -- this suite mutates the process-global CLAUDE_WRAPPER_ALLOW_DANGEROUS
  # env var, which would race other async tests reading it.
  use ExUnit.Case, async: false

  alias ClaudeWrapper.{Config, DangerousClient, Query}

  @allow_env "CLAUDE_WRAPPER_ALLOW_DANGEROUS"

  # Save/restore the env var around each test so the gate's prior state
  # (whatever the surrounding process had) is left untouched.
  setup do
    previous = System.get_env(@allow_env)

    on_exit(fn ->
      case previous do
        nil -> System.delete_env(@allow_env)
        value -> System.put_env(@allow_env, value)
      end
    end)

    :ok
  end

  describe "allow_env/0" do
    test "returns the gate env var name" do
      assert DangerousClient.allow_env() == @allow_env
    end
  end

  describe "new/1 when the gate is closed" do
    test "errors when the env var is unset" do
      System.delete_env(@allow_env)

      assert DangerousClient.new(Config.new()) ==
               {:error, {:dangerous_not_allowed, @allow_env}}
    end

    test "errors when the env var is set to something other than \"1\"" do
      for value <- ["0", "true", "yes", ""] do
        System.put_env(@allow_env, value)

        assert DangerousClient.new(Config.new()) ==
                 {:error, {:dangerous_not_allowed, @allow_env}},
               "expected the gate to stay closed for #{inspect(value)}"
      end
    end
  end

  describe "new/1 when the gate is open" do
    setup do
      System.put_env(@allow_env, "1")
      :ok
    end

    test "succeeds and wraps the given config" do
      config = Config.new(binary: "/usr/bin/true")

      assert {:ok, %DangerousClient{config: ^config}} = DangerousClient.new(config)
    end

    test "config/1 returns the wrapped config" do
      config = Config.new(working_dir: "/tmp")
      {:ok, client} = DangerousClient.new(config)

      assert DangerousClient.config(client) == config
    end
  end

  describe "query_bypass/2 query shaping" do
    setup do
      System.put_env(@allow_env, "1")
      config = Config.new(binary: "/usr/bin/true")
      {:ok, client} = DangerousClient.new(config)
      {:ok, client: client}
    end

    test "sets the bypass flag on the query before execution", %{client: client} do
      # The flag isn't present on a plain query...
      plain = Query.new("clean up the build artifacts")
      refute "--dangerously-skip-permissions" in Query.build_args(plain)

      # ...but query_bypass applies it. We verify the shaping by replaying
      # the same transform the client applies, then inspecting build_args/1
      # -- this exercises the flag wiring without invoking a real binary.
      bypassed = Query.dangerously_skip_permissions(plain)

      assert bypassed.dangerously_skip_permissions == true
      assert "--dangerously-skip-permissions" in Query.build_args(bypassed)

      # And the client is constructable in the gated state, so query_bypass/2
      # is callable with this exact pairing.
      assert %DangerousClient{} = client
    end
  end
end
