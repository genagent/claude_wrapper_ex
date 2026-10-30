defmodule ClaudeWrapper.DuplexSession.Adapter.Port do
  @moduledoc """
  Default `ClaudeWrapper.DuplexSession.Adapter`: a real `claude`
  subprocess over an Erlang port.

  The port is opened by (and delivers its `{port, {:data, _}}` /
  `{port, {:exit_status, _}}` / `{:EXIT, port, _}` messages directly to)
  the session process, which calls `open/1` from its own `init/1`. The
  returned handle is the port itself.

  `claude` is started as `/bin/sh -c 'exec "$@" 2>>FILE'`: `exec` keeps
  its pid, and its stderr goes to a 0600 file instead of the VM's stderr
  (#311). The session reads the file's tail (`:stderr_capture_bytes` in
  `:adapter_opts`, default 16 KiB; `0` discards stderr) when the transport
  closes or `claude` exits, and the file is removed on `close/1`. The file
  itself is not size-bounded. Line and output bounds (`:max_line_bytes`,
  `:max_output_bytes`) are enforced by `ClaudeWrapper.DuplexSession`.
  """

  @behaviour ClaudeWrapper.DuplexSession.Adapter

  alias ClaudeWrapper.{Command, Config}

  @impl true
  def open(opts) do
    config = Keyword.fetch!(opts, :config)
    args = Keyword.fetch!(opts, :args)

    with {:ok, binary} <- Command.resolve_executable(config.binary) do
      start(config, binary, args, opts)
    end
  end

  defp start(config, binary, args, opts) do
    stderr_file = stderr_file(Keyword.get(opts, :stderr_capture_bytes, 16 * 1024))

    port_opts =
      [:binary, :exit_status, :use_stdio, {:args, stderr_args(stderr_file, binary, args)}] ++
        env_opts(config) ++
        cd_opts(config)

    port = Port.open({:spawn_executable, "/bin/sh"}, port_opts)
    Process.put({__MODULE__, :stderr, port}, stderr_file)
    open_lifeline(port)
    {:ok, port}
  end

  @impl true
  def stderr_tail(port, max_bytes) do
    case Process.get({__MODULE__, :stderr, port}) do
      path when is_binary(path) and max_bytes > 0 -> read_tail(path, max_bytes)
      _ -> ""
    end
  end

  defp read_tail(path, max_bytes) do
    with {:ok, %File.Stat{size: size}} <- File.stat(path),
         {:ok, file} <- File.open(path, [:read, :binary]) do
      offset = max(size - max_bytes, 0)

      try do
        case :file.pread(file, offset, size - offset) do
          {:ok, data} -> data
          _ -> ""
        end
      after
        File.close(file)
      end
    else
      _ -> ""
    end
  end

  # A 0600 file for claude's stderr, or nil to discard it.
  defp stderr_file(0), do: nil

  defp stderr_file(_bytes) do
    path =
      Path.join(
        System.tmp_dir!(),
        "claude-wrapper-stderr-#{System.unique_integer([:positive])}-#{:erlang.phash2(make_ref())}"
      )

    File.write!(path, "", [:exclusive])
    File.chmod!(path, 0o600)
    path
  end

  defp stderr_args(nil, binary, args),
    do: ["-c", ~S(exec "$@" 2>/dev/null), "claude-wrapper", binary | args]

  defp stderr_args(path, binary, args),
    do: ["-c", ~S(f=$1; shift; exec "$@" 2>>"$f"), "claude-wrapper", path, binary | args]

  # A second port that signals claude when the session closes its transport
  # or the BEAM dies (#303); see ClaudeWrapper.Command.lifeline_args/1. It is
  # opened by, and so closes with, the session process; the adapter callbacks
  # run in that process, so the lifeline is kept in its dictionary.
  defp open_lifeline(port) do
    with {:os_pid, os_pid} <- Port.info(port, :os_pid) do
      lifeline =
        Port.open(
          {:spawn_executable, "/bin/sh"},
          [:binary, {:args, Command.lifeline_args(os_pid)}]
        )

      Process.put({__MODULE__, :lifeline, port}, lifeline)
    end
  rescue
    ErlangError -> :ok
  end

  @impl true
  def command(port, iodata) do
    Port.command(port, iodata)
    :ok
  end

  @impl true
  def close(port) do
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)

    case Process.delete({__MODULE__, :lifeline, port}) do
      lifeline when is_port(lifeline) -> close_port(lifeline)
      nil -> :ok
    end

    case Process.delete({__MODULE__, :stderr, port}) do
      path when is_binary(path) -> File.rm(path)
      nil -> :ok
    end

    :ok
  end

  defp close_port(port) do
    if Port.info(port) != nil, do: Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end

  defp env_opts(%Config{} = config) do
    case Config.child_env(config) do
      [] -> []
      env -> [{:env, Config.port_env(env)}]
    end
  end

  defp cd_opts(%Config{working_dir: nil}), do: []
  defp cd_opts(%Config{working_dir: dir}), do: [{:cd, String.to_charlist(dir)}]
end
