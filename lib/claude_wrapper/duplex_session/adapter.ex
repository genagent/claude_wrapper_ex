defmodule ClaudeWrapper.DuplexSession.Adapter do
  @moduledoc """
  Transport seam for `ClaudeWrapper.DuplexSession`.

  A `DuplexSession` drives the `claude` subprocess through exactly three
  active operations -- open the transport, write a line to it, close it --
  and consumes three inbound message shapes delivered to its own process
  mailbox:

    * `{handle, {:data, chunk}}` -- raw stdout bytes
    * `{handle, {:exit_status, code}}` -- the subprocess exited
    * `{:EXIT, handle, reason}` -- the transport process exited

  where `handle` is the value the adapter's `open/1` returned (and which
  the session stores as its transport handle). An adapter implements the
  three operations; the inbound side is just a matter of sending those
  message shapes to the `:owner` given at `open/1`.

  Two implementations ship:

    * `ClaudeWrapper.DuplexSession.Adapter.Port` -- the default; a real
      `claude` subprocess over an Erlang port.
    * `ClaudeWrapper.DuplexSession.Adapter.Test` -- a controllable
      in-process double for network-free tests (see `ClaudeWrapper.Test`).
  """

  @typedoc "The opaque transport handle returned by `open/1`."
  @type handle :: term()

  @typedoc """
  Options passed to `open/1`. Always carries:

    * `:config` -- the `t:ClaudeWrapper.Config.t/0`
    * `:args` -- the resolved CLI argument list
    * `:owner` -- the session pid that inbound messages are sent to

  Adapter-specific keys (from the session's `:adapter_opts`) are merged in.
  """
  @type open_opts :: keyword()

  @doc "Start the transport. Returns an opaque handle the session stores."
  @callback open(open_opts()) :: {:ok, handle()} | {:error, term()}

  @doc "Write iodata (one NDJSON line, newline included) to the transport."
  @callback command(handle(), iodata()) :: :ok

  @doc "Shut the transport down. Idempotent; the handle may already be dead."
  @callback close(handle()) :: :ok
end
