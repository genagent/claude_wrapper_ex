defmodule ClaudeWrapper.DuplexSession.ControlTest.WireAdapter do
  @moduledoc false
  # A transport that hands every written line to the test process as
  # decoded JSON, and lets the test feed lines back as the CLI's output.
  @behaviour ClaudeWrapper.DuplexSession.Adapter

  @impl true
  def open(opts) do
    test_pid = Keyword.fetch!(opts, :test_pid)
    handle = {:wire, make_ref(), test_pid}
    send(test_pid, {:wire_open, handle})
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

    assert_receive {:wire_open, handle}
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
end
