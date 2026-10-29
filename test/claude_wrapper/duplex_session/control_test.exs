defmodule ClaudeWrapper.DuplexSession.ControlTest.WireAdapter do
  @moduledoc false
  # A transport that hands every written line to the test process as
  # decoded JSON, and lets the test feed lines back as the CLI's output.
  @behaviour ClaudeWrapper.DuplexSession.Adapter

  @impl true
  def open(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    handle = {:wire, make_ref(), test_pid}
    send(test_pid, {:wire_open, handle, Keyword.fetch!(opts, :args)})
    {:ok, handle}
  end

  @impl true
  def command({:wire, _ref, test_pid}, iodata) do
    for line <- String.split(IO.iodata_to_binary(iodata), "\n", trim: true) do
      send(test_pid, {:wire_out, Jason.decode!(line)})
    end

    :ok
  end

  @impl true
  def close(_handle), do: :ok
end

defmodule ClaudeWrapper.DuplexSession.ControlTest do
  use ExUnit.Case, async: true

  alias ClaudeWrapper.{Config, DuplexSession, Error}
  alias ClaudeWrapper.DuplexSession.ControlTest.WireAdapter

  defp start(opts \\ []) do
    {:ok, pid} =
      DuplexSession.start_link(
        opts ++
          [
            config: Config.new(binary: "unused"),
            adapter: WireAdapter,
            adapter_opts: [test_pid: self()]
          ]
      )

    assert_receive {:wire_open, handle, _args}
    {pid, handle}
  end

  # Feed one line of CLI output to the session and wait until it is handled.
  defp cli_says(pid, handle, msg) do
    send(pid, {handle, {:data, Jason.encode!(msg) <> "\n"}})
    :sys.get_state(pid)
  end

  defp control_async(pid, request) do
    parent = self()
    spawn_link(fn -> send(parent, {:control_result, DuplexSession.control(pid, request)}) end)
    assert_receive {:wire_out, %{"type" => "control_request"} = out}
    out
  end

  defp inbound(id, request), do: %{type: "control_request", request_id: id, request: request}

  describe "control/3" do
    test "sends the request and returns the CLI's response body" do
      {pid, handle} = start()

      out = control_async(pid, %{subtype: "set_model", model: "sonnet"})

      assert %{"request_id" => id, "request" => %{"subtype" => "set_model", "model" => "sonnet"}} =
               out

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{subtype: "success", request_id: id, response: %{model: "claude-sonnet"}}
      })

      assert_receive {:control_result, {:ok, %{"model" => "claude-sonnet"}}}
    end

    test "accepts string keys and returns an empty map when the CLI sends no body" do
      {pid, handle} = start()

      %{"request_id" => id} = control_async(pid, %{"subtype" => "mcp_status"})

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{subtype: "success", request_id: id}
      })

      assert_receive {:control_result, {:ok, %{}}}
    end

    test "an error response is :duplex_control_failed with the CLI's message" do
      {pid, handle} = start()

      %{"request_id" => id} = control_async(pid, %{subtype: "no_such_request"})

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{
          subtype: "error",
          request_id: id,
          error: "Unsupported control request subtype: no_such_request"
        }
      })

      assert_receive {:control_result,
                      {:error,
                       %Error{
                         kind: :duplex_control_failed,
                         reason: "Unsupported control request subtype: no_such_request"
                       }}}
    end

    test "a closed transport is :duplex_closed" do
      {pid, _handle} = start()
      :sys.replace_state(pid, &%{&1 | port: nil})

      assert {:error, %Error{kind: :duplex_closed}} =
               DuplexSession.control(pid, %{subtype: "mcp_status"})
    end

    test "a request without a string subtype raises" do
      {pid, _handle} = start()

      assert_raise ArgumentError, fn -> DuplexSession.control(pid, %{model: "x"}) end
      assert_raise ArgumentError, fn -> DuplexSession.control(pid, %{subtype: :atom}) end
    end

    test "interrupt/2 is a control request and keeps its :ok contract" do
      {pid, handle} = start()
      parent = self()
      spawn_link(fn -> send(parent, {:interrupted, DuplexSession.interrupt(pid)}) end)

      assert_receive {:wire_out,
                      %{"type" => "control_request", "request_id" => id, "request" => req}}

      assert req == %{"subtype" => "interrupt"}

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{subtype: "success", request_id: id}
      })

      assert_receive {:interrupted, :ok}
    end
  end

  describe "inbound control requests" do
    test "without a handler, the request is answered with an error" do
      {pid, handle} = start()

      cli_says(pid, handle, inbound("in-1", %{subtype: "hook_callback", callback_id: "h"}))

      assert_receive {:wire_out,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "subtype" => "error",
                          "request_id" => "in-1",
                          "error" => "Unsupported control request subtype: hook_callback"
                        }
                      }}
    end

    test "the handler sees subtype, request and id, and its {:ok, map} is sent" do
      parent = self()

      handler = fn subtype, request, id ->
        send(parent, {:handled, subtype, request, id})
        {:ok, %{continue: true}}
      end

      {pid, handle} = start(on_control_request: handler)

      cli_says(pid, handle, inbound("in-2", %{subtype: "hook_callback", callback_id: "h1"}))

      assert_receive {:handled, "hook_callback",
                      %{"subtype" => "hook_callback", "callback_id" => "h1"}, "in-2"}

      assert_receive {:wire_out,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "subtype" => "success",
                          "request_id" => "in-2",
                          "response" => %{"continue" => true}
                        }
                      }}
    end

    test "{:error, message} from the handler is sent as an error response" do
      {pid, handle} = start(on_control_request: fn _, _, _ -> {:error, "nope"} end)

      cli_says(pid, handle, inbound("in-3", %{subtype: "mcp_message"}))

      assert_receive {:wire_out, %{"response" => %{"subtype" => "error", "error" => "nope"}}}
    end

    test "a raising handler is answered with an error and the session keeps running" do
      {pid, handle} = start(on_control_request: fn _, _, _ -> raise "boom" end)

      ExUnit.CaptureLog.capture_log(fn ->
        cli_says(pid, handle, inbound("in-4", %{subtype: "mcp_message"}))
      end)

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "subtype" => "error",
                          "request_id" => "in-4",
                          "error" => "control handler raised: boom"
                        }
                      }}

      assert Process.alive?(pid)
    end

    test "an invalid handler return is answered with an error" do
      {pid, handle} = start(on_control_request: fn _, _, _ -> :whatever end)

      ExUnit.CaptureLog.capture_log(fn ->
        cli_says(pid, handle, inbound("in-5", %{subtype: "mcp_message"}))
      end)

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "subtype" => "error",
                          "error" => "control handler returned an invalid reply"
                        }
                      }}
    end

    test "can_use_tool still goes to on_permission" do
      parent = self()

      {pid, handle} =
        start(
          on_permission: fn tool, _input ->
            send(parent, {:perm, tool})
            :allow
          end,
          on_control_request: fn _, _, _ -> flunk("control handler called") end
        )

      cli_says(
        pid,
        handle,
        inbound("p-1", %{subtype: "can_use_tool", tool_name: "Read", input: %{}})
      )

      assert_receive {:perm, "Read"}

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "request_id" => "p-1",
                          "response" => %{"behavior" => "allow"}
                        }
                      }}
    end

    test "a non-3-arity handler is rejected at start" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               DuplexSession.start_link(
                 config: Config.new(binary: "unused"),
                 adapter: WireAdapter,
                 adapter_opts: [test_pid: self()],
                 on_control_request: fn _ -> :defer end
               )
    end
  end

  describe "deferred inbound requests" do
    test "respond_to_control/3 answers once; later answers are no-ops" do
      {pid, handle} = start(on_control_request: fn _, _, _ -> :defer end)

      cli_says(pid, handle, inbound("d-1", %{subtype: "mcp_message"}))
      refute_received {:wire_out, _}

      assert :ok = DuplexSession.respond_to_control(pid, "d-1", {:ok, %{done: 1}})

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "subtype" => "success",
                          "request_id" => "d-1",
                          "response" => %{"done" => 1}
                        }
                      }}

      assert :ok = DuplexSession.respond_to_control(pid, "d-1", {:error, "late"})
      :sys.get_state(pid)
      refute_received {:wire_out, _}
    end

    test "an unknown request id is a no-op" do
      {pid, _handle} = start()

      assert :ok = DuplexSession.respond_to_control(pid, "never-seen", {:ok, %{}})
      :sys.get_state(pid)
      refute_received {:wire_out, _}
    end

    test "deferring again and invalid replies are rejected" do
      {pid, _handle} = start()

      assert {:error, %Error{kind: :cannot_defer_again}} =
               DuplexSession.respond_to_control(pid, "d-2", :defer)

      assert_raise ArgumentError, fn ->
        DuplexSession.respond_to_control(pid, "d-2", {:ok, "not a map"})
      end
    end

    test "control_cancel_request drops the deferral and notifies subscribers" do
      {pid, handle} = start(on_control_request: fn _, _, _ -> :defer end)
      :ok = DuplexSession.subscribe(pid)

      cli_says(pid, handle, inbound("c-1", %{subtype: "mcp_message"}))
      cli_says(pid, handle, %{type: "control_cancel_request", request_id: "c-1"})

      assert_receive {:claude, {:control_cancel, "c-1"}}

      assert :ok = DuplexSession.respond_to_control(pid, "c-1", {:ok, %{}})
      :sys.get_state(pid)
      refute_received {:wire_out, _}
    end
  end

  describe "initialize" do
    test "is not sent by default" do
      {pid, _handle} = start()

      refute_received {:wire_out, _}

      assert {:error, %Error{kind: :not_found, reason: :initialize_not_requested}} =
               DuplexSession.initialize_response(pid)
    end

    test "sends the given fields and holds the response for waiters" do
      {pid, handle} = start(initialize: %{promptSuggestions: true})

      assert_receive {:wire_out,
                      %{
                        "type" => "control_request",
                        "request_id" => id,
                        "request" =>
                          %{"subtype" => "initialize", "promptSuggestions" => true} = req
                      }}

      refute Map.has_key?(req, "sdkMcpServers")

      parent = self()
      spawn_link(fn -> send(parent, {:init, DuplexSession.initialize_response(pid)}) end)
      refute_receive {:init, _}, 50

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{subtype: "success", request_id: id, response: %{models: [], pid: 1}}
      })

      assert_receive {:init, {:ok, %{"models" => [], "pid" => 1}}}
      assert {:ok, %{"pid" => 1}} = DuplexSession.initialize_response(pid)
    end

    test "an error response is returned to waiters" do
      {pid, handle} = start(initialize: true)
      assert_receive {:wire_out, %{"request_id" => id, "request" => %{"subtype" => "initialize"}}}

      cli_says(pid, handle, %{
        type: "control_response",
        response: %{subtype: "error", request_id: id, error: "bad init"}
      })

      assert {:error, %Error{kind: :duplex_control_failed, reason: "bad init"}} =
               DuplexSession.initialize_response(pid)
    end

    test "a transport exit while pending fails waiters" do
      Process.flag(:trap_exit, true)
      {pid, handle} = start(initialize: true)
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      parent = self()
      spawn(fn -> send(parent, {:init, DuplexSession.initialize_response(pid)}) end)
      :sys.get_state(pid)
      send(pid, {handle, {:exit_status, 1}})

      assert_receive {:init, {:error, %Error{kind: :terminated}}}
    end

    test "a non-boolean, non-map value raises at start" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               DuplexSession.start_link(
                 config: Config.new(binary: "unused"),
                 adapter: WireAdapter,
                 adapter_opts: [test_pid: self()],
                 initialize: "yes"
               )
    end
  end

  describe "sdk_mcp_servers" do
    defp mcp_request(id, server, message),
      do: inbound(id, %{subtype: "mcp_message", server_name: server, message: message})

    test "declares the servers in --mcp-config and initialize" do
      {:ok, _pid} =
        DuplexSession.start_link(
          config: Config.new(binary: "unused"),
          adapter: WireAdapter,
          adapter_opts: [test_pid: self()],
          initialize: %{sdkMcpServers: ["other"]},
          sdk_mcp_servers: %{"app" => fn _ -> nil end}
        )

      assert_receive {:wire_open, _handle, args}
      [config_json] = for {"--mcp-config", json} <- Enum.zip(args, tl(args) ++ [nil]), do: json

      assert Jason.decode!(config_json) == %{
               "mcpServers" => %{"app" => %{"type" => "sdk", "name" => "app"}}
             }

      assert_receive {:wire_out,
                      %{"request" => %{"subtype" => "initialize", "sdkMcpServers" => names}}}

      assert Enum.sort(names) == ["app", "other"]
    end

    test "routes a message to its handler in another process and writes the reply" do
      parent = self()

      handler = fn message ->
        send(parent, {:handler_ran, self(), message})
        %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{"tools" => []}}
      end

      {pid, handle} = start(sdk_mcp_servers: %{"app" => handler})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(
        pid,
        handle,
        mcp_request("m-1", "app", %{jsonrpc: "2.0", id: 1, method: "tools/list"})
      )

      assert_receive {:handler_ran, handler_pid, %{"method" => "tools/list", "id" => 1}}
      refute handler_pid == pid

      assert_receive {:wire_out,
                      %{
                        "type" => "control_response",
                        "response" => %{
                          "subtype" => "success",
                          "request_id" => "m-1",
                          "response" => %{
                            "mcp_response" => %{"id" => 1, "result" => %{"tools" => []}}
                          }
                        }
                      }}
    end

    test "a blocked handler does not block the session" do
      parent = self()

      handler = fn message ->
        send(parent, {:blocked, self()})

        receive do
          :go -> %{"jsonrpc" => "2.0", "id" => message["id"], "result" => %{}}
        end
      end

      {pid, handle} = start(sdk_mcp_servers: %{"app" => handler})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(
        pid,
        handle,
        mcp_request("m-2", "app", %{jsonrpc: "2.0", id: 2, method: "tools/call"})
      )

      assert_receive {:blocked, handler_pid}

      # The session still answers other traffic while the handler waits.
      cli_says(pid, handle, inbound("x-1", %{subtype: "hook_callback"}))
      assert_receive {:wire_out, %{"response" => %{"request_id" => "x-1", "subtype" => "error"}}}

      send(handler_pid, :go)

      assert_receive {:wire_out,
                      %{"response" => %{"request_id" => "m-2", "subtype" => "success"}}}
    end

    test "a raising handler becomes a JSON-RPC error with the request id" do
      {pid, handle} = start(sdk_mcp_servers: %{"app" => fn _ -> raise "kaput" end})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(pid, handle, mcp_request("m-3", "app", %{jsonrpc: "2.0", id: 7, method: "x"}))

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "request_id" => "m-3",
                          "response" => %{
                            "mcp_response" => %{
                              "id" => 7,
                              "error" => %{"code" => -32_603, "message" => "kaput"}
                            }
                          }
                        }
                      }}
    end

    test "a nil reply to a notification is acknowledged" do
      {pid, handle} = start(sdk_mcp_servers: %{"app" => fn _ -> nil end})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(
        pid,
        handle,
        mcp_request("m-4", "app", %{jsonrpc: "2.0", method: "notifications/initialized"})
      )

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "request_id" => "m-4",
                          "response" => %{"mcp_response" => %{"result" => %{}}}
                        }
                      }}
    end

    test "a message for an unknown server goes to on_control_request" do
      {pid, handle} = start(sdk_mcp_servers: %{"app" => fn _ -> nil end})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(pid, handle, mcp_request("m-5", "nope", %{jsonrpc: "2.0", id: 1, method: "ping"}))

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "request_id" => "m-5",
                          "subtype" => "error",
                          "error" => "Unsupported control request subtype: mcp_message"
                        }
                      }}
    end

    test "a killed handler is answered with an error" do
      parent = self()

      handler = fn _ ->
        send(parent, {:blocked, self()})
        Process.sleep(:infinity)
      end

      {pid, handle} = start(sdk_mcp_servers: %{"app" => handler})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(pid, handle, mcp_request("m-6", "app", %{jsonrpc: "2.0", id: 1, method: "x"}))
      assert_receive {:blocked, handler_pid}
      Process.exit(handler_pid, :kill)

      assert_receive {:wire_out,
                      %{
                        "response" => %{
                          "request_id" => "m-6",
                          "subtype" => "error",
                          "error" => "MCP handler exited: :killed"
                        }
                      }}
    end

    test "stopping the session kills handlers still running" do
      parent = self()

      handler = fn _ ->
        send(parent, {:blocked, self()})
        Process.sleep(:infinity)
      end

      {pid, handle} = start(sdk_mcp_servers: %{"app" => handler})
      assert_receive {:wire_out, %{"request" => %{"subtype" => "initialize"}}}

      cli_says(pid, handle, mcp_request("m-7", "app", %{jsonrpc: "2.0", id: 1, method: "x"}))
      assert_receive {:blocked, handler_pid}
      ref = Process.monitor(handler_pid)

      DuplexSession.stop(pid)
      assert_receive {:DOWN, ^ref, :process, ^handler_pid, :killed}
    end

    test "invalid server maps raise at start" do
      Process.flag(:trap_exit, true)

      assert {:error, {%ArgumentError{}, _}} =
               DuplexSession.start_link(
                 config: Config.new(binary: "unused"),
                 adapter: WireAdapter,
                 adapter_opts: [test_pid: self()],
                 sdk_mcp_servers: %{"app" => fn _, _ -> nil end}
               )
    end
  end
end
