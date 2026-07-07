if Code.ensure_loaded?(Forcola) do
  defmodule ClaudeWrapper.DuplexSession.Adapter.Forcola do
    @moduledoc """
    Leak-free `ClaudeWrapper.DuplexSession` transport backed by
    `Forcola.Duplex`.

    Holds the long-lived `claude` subprocess in its own process group; on
    session close, owner death, or BEAM death the whole group is killed
    (SIGTERM then SIGKILL), reaping `claude` and every stdio MCP server it
    spawned. The default `ClaudeWrapper.DuplexSession.Adapter.Port` closes
    the port instead, which sends no signal (see #185).

    This module compiles only when `forcola` is a dependency. Select it
    per session with `adapter: ClaudeWrapper.DuplexSession.Adapter.Forcola`,
    or globally with
    `config :claude_wrapper, duplex_adapter: ClaudeWrapper.DuplexSession.Adapter.Forcola`.
    forcola is POSIX-only.

    ## How it fits the adapter seam

    A small translator `GenServer` owns the `Forcola.Duplex` session and
    forwards its owner messages into the three shapes
    `ClaudeWrapper.DuplexSession.Adapter` delivers. The translator's pid is
    the transport handle, so the session's `%{port: handle}` match works
    unchanged:

      * `{:forcola_line, _, line}` -> `{handle, {:data, line <> "\\n"}}`
        (forcola strips the trailing newline; the session's buffer splits
        on it, so it is re-added)
      * `{:forcola_exit, _, status}` -> `{handle, {:exit_status, code}}`,
        then the translator stops and its linked `{:EXIT, handle, reason}`
        reaches the session
      * `{:forcola_stderr, _, _}` is dropped, matching the `Port` adapter
        which does not fold stderr into the NDJSON stream
    """

    @behaviour ClaudeWrapper.DuplexSession.Adapter

    use GenServer

    alias ClaudeWrapper.Config

    @impl ClaudeWrapper.DuplexSession.Adapter
    def open(opts) do
      config = Keyword.fetch!(opts, :config)
      args = Keyword.fetch!(opts, :args)
      owner = Keyword.fetch!(opts, :owner)

      GenServer.start_link(__MODULE__, {config, args, owner})
    end

    @impl ClaudeWrapper.DuplexSession.Adapter
    def command(pid, iodata) do
      GenServer.cast(pid, {:send_line, IO.iodata_to_binary(iodata)})
    end

    @impl ClaudeWrapper.DuplexSession.Adapter
    def close(pid) do
      GenServer.stop(pid, :normal, :infinity)
    catch
      :exit, _ -> :ok
    end

    ## Translator GenServer

    @impl GenServer
    def init({config, args, owner}) do
      Process.flag(:trap_exit, true)

      case Forcola.Duplex.open([config.binary | args], duplex_opts(config)) do
        {:ok, session} -> {:ok, %{session: session, owner: owner}}
        {:error, reason} -> {:stop, reason}
      end
    end

    @impl GenServer
    def handle_cast({:send_line, line}, %{session: session} = state) do
      # The session frames each write as `[json, ?\n]`; Forcola.Duplex
      # appends its own newline, so strip the one trailing newline.
      Forcola.Duplex.send_line(session, String.replace_suffix(line, "\n", ""))
      {:noreply, state}
    end

    @impl GenServer
    def handle_info({:forcola_line, session, line}, %{session: session, owner: owner} = state) do
      send(owner, {self(), {:data, line <> "\n"}})
      {:noreply, state}
    end

    def handle_info({:forcola_stderr, session, _line}, %{session: session} = state) do
      {:noreply, state}
    end

    def handle_info({:forcola_exit, session, status}, %{session: session, owner: owner} = state) do
      send(owner, {self(), {:exit_status, exit_code(status)}})
      {:stop, :normal, state}
    end

    def handle_info(_other, state), do: {:noreply, state}

    @impl GenServer
    def terminate(_reason, %{session: session}) do
      Forcola.Duplex.close(session)
      :ok
    end

    def terminate(_reason, _state), do: :ok

    # Map a Forcola exit status onto the integer exit code the session
    # expects. A clean exit carries its code; a signal or abnormal
    # termination has no exit code, so surface a conventional non-zero one
    # (128 + signal) that the session records as {:failed, ...}.
    defp exit_code(status) when is_integer(status), do: status
    defp exit_code({:signal, n}) when is_integer(n), do: 128 + n
    defp exit_code(_other), do: 1

    defp duplex_opts(%Config{} = config) do
      []
      |> put_cd(config)
      |> put_env(config)
    end

    defp put_cd(opts, %Config{working_dir: nil}), do: opts
    defp put_cd(opts, %Config{working_dir: dir}), do: [{:cd, dir} | opts]

    defp put_env(opts, %Config{env: []}), do: opts
    defp put_env(opts, %Config{env: env}), do: [{:env, env} | opts]
  end
end
