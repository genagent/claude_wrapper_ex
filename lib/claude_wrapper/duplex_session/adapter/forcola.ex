if Code.ensure_loaded?(Forcola) do
  defmodule ClaudeWrapper.DuplexSession.Adapter.Forcola do
    @moduledoc """
    Bounded duplex transport backed by `Forcola.Duplex`.

    The `DuplexSession` process owns the Forcola session directly, so its
    death closes the child's process group. A separate puller demands one
    stdout or stderr line at a time and waits for the session to acknowledge
    it before demanding another. Stderr is kept out of the NDJSON parser.

    Select this optional adapter with `adapter: __MODULE__` or set
    `config :claude_wrapper, duplex_adapter: __MODULE__`. It requires
    `forcola >= 0.4.0 and < 0.7.0` and a POSIX host.

    `:adapter_opts` accepts `:max_line_bytes`, `:max_output_bytes`, and
    `:max_pending_bytes` (defaults: 1 MiB, 64 MiB, and one line plus its
    newline), plus `:stderr_capture_bytes` for the wrapper's bounded stderr
    tail (default 16 KiB). `:terminal_recipient` can name an independent
    process that receives Forcola's terminal record even if the session
    owner dies. `:kill_grace_ms`, `:cgroup`, and `:shim_path` are passed
    through. Pull delivery and separate stderr are always enabled.
    """

    @behaviour ClaudeWrapper.DuplexSession.Adapter

    alias ClaudeWrapper.Config

    @default_max_line_bytes 1_048_576
    @default_max_output_bytes 64 * 1_048_576
    @allowed_opts [
      :max_line_bytes,
      :max_output_bytes,
      :max_pending_bytes,
      :stderr_capture_bytes,
      :terminal_recipient,
      :kill_grace_ms,
      :cgroup,
      :shim_path
    ]

    defmodule Handle do
      @moduledoc false
      @enforce_keys [:session, :puller, :monitor]
      defstruct [:session, :puller, :monitor]
    end

    @impl true
    def open(opts) do
      config = Keyword.fetch!(opts, :config)
      args = Keyword.fetch!(opts, :args)
      owner = Keyword.fetch!(opts, :owner)
      adapter_opts = Keyword.drop(opts, [:config, :args, :owner])
      validate_opts!(adapter_opts)

      case Forcola.Duplex.open([config.binary | args], duplex_opts(config, adapter_opts)) do
        {:ok, session} ->
          puller = spawn(fn -> await_start(owner) end)
          monitor = Process.monitor(puller)
          handle = %Handle{session: session, puller: puller, monitor: monitor}
          send(puller, {:start, session, owner, handle})
          {:ok, handle}

        {:error, reason} ->
          {:error, reason}
      end
    end

    @impl true
    def command(%Handle{session: session}, iodata) do
      # DuplexSession frames each write with a newline; Forcola adds one.
      line = iodata |> IO.iodata_to_binary() |> String.replace_suffix("\n", "")
      Forcola.Duplex.send_line(session, line)
    end

    @impl true
    def close(%Handle{session: session} = handle) do
      Forcola.Duplex.close(session)
      stop_puller(handle)
      :ok
    end

    @impl true
    @doc false
    def shutdown(%Handle{session: session} = handle) do
      result = Forcola.Duplex.shutdown(session)
      stop_puller(handle)
      result
    end

    @impl true
    @doc false
    def ack(%Handle{puller: puller}, ref) do
      send(puller, {:ack, ref})
      :ok
    end

    defp stop_puller(%Handle{puller: puller, monitor: monitor}) do
      Process.exit(puller, :kill)
      Process.demonitor(monitor, [:flush])
    end

    defp await_start(owner) do
      owner_ref = Process.monitor(owner)

      receive do
        {:start, session, owner, handle} ->
          pull(session, owner, owner_ref, handle)

        {:DOWN, ^owner_ref, :process, ^owner, _reason} ->
          :ok
      end
    end

    defp pull(session, owner, owner_ref, handle) do
      case Forcola.Duplex.recv(session) do
        {:ok, {stream, line}} when stream in [:stdout, :stderr] ->
          ref = make_ref()
          event = if stream == :stdout, do: {:data, line <> "\n", ref}, else: {:stderr, line, ref}
          send(owner, {handle, event})

          receive do
            {:ack, ^ref} -> pull(session, owner, owner_ref, handle)
            {:DOWN, ^owner_ref, :process, ^owner, _reason} -> :ok
          end

        {:done, terminal} ->
          send(owner, {handle, {:terminal, terminal}})

        {:error, {:output_limit, terminal}} ->
          send(owner, {handle, {:terminal, terminal}})

        {:error, reason} ->
          send(owner, {handle, {:transport_error, reason}})
      end
    end

    defp validate_opts!(opts) do
      case Keyword.keys(opts) -- @allowed_opts do
        [] ->
          capture = Keyword.get(opts, :stderr_capture_bytes, 16 * 1024)

          unless is_integer(capture) and capture >= 0 do
            raise ArgumentError, ":stderr_capture_bytes must be a non-negative integer"
          end

        unknown ->
          raise ArgumentError, "unsupported Forcola adapter options: #{inspect(unknown)}"
      end
    end

    defp duplex_opts(%Config{} = config, opts) do
      max_line = positive_option!(opts, :max_line_bytes, @default_max_line_bytes)
      max_output = positive_option!(opts, :max_output_bytes, @default_max_output_bytes)
      max_pending = positive_option!(opts, :max_pending_bytes, max_line + 1)

      [
        delivery: :pull,
        merge_stderr: false,
        max_line_bytes: max_line,
        max_output_bytes: max_output,
        max_pending_bytes: max_pending
      ]
      |> Keyword.merge(
        Keyword.take(opts, [:terminal_recipient, :kill_grace_ms, :cgroup, :shim_path])
      )
      |> put_cd(config)
      |> put_env(config)
    end

    defp positive_option!(opts, key, default) do
      case Keyword.get(opts, key, default) do
        value when is_integer(value) and value > 0 -> value
        _ -> raise ArgumentError, "#{inspect(key)} must be a positive integer"
      end
    end

    defp put_cd(opts, %Config{working_dir: nil}), do: opts
    defp put_cd(opts, %Config{working_dir: dir}), do: [{:cd, dir} | opts]

    defp put_env(opts, %Config{env: []}), do: opts
    defp put_env(opts, %Config{env: env}), do: [{:env, env} | opts]
  end
end
