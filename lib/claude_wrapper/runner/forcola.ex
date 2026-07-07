if Code.ensure_loaded?(Forcola) do
  defmodule ClaudeWrapper.Runner.Forcola do
    @moduledoc """
    Leak-free runner backed by [forcola](https://hex.pm/packages/forcola).

    Every `claude` invocation runs under forcola's Rust shim, which places
    the CLI in its own process group and kills the whole group (SIGTERM,
    then SIGKILL) on timeout, on early stream halt, or when the BEAM dies.
    That reaps `claude` and every stdio MCP server it spawned together,
    where the default `ClaudeWrapper.Runner.Port` would leave them running
    (see #185).

    This module compiles only when `forcola` is a dependency. Select it
    with `config :claude_wrapper, runner: ClaudeWrapper.Runner.Forcola`.
    forcola is POSIX-only.
    """

    @behaviour ClaudeWrapper.Runner

    # forcola requires a mandatory whole-run bound. When the caller sets
    # no timeout we still want group-kill-on-BEAM-death, so we pass a very
    # large bound rather than falling back to the leaky path.
    @unbounded_ms 24 * 60 * 60 * 1000

    # Streaming safety: bounds the gap between output frames, matching
    # Runner.Port's historical per-receive deadline.
    @stream_idle_timeout_ms 300_000

    @impl true
    def run(binary, args, opts, timeout) do
      forcola_opts =
        [timeout_ms: timeout || @unbounded_ms, merge_stderr: merge_stderr?(opts)] ++
          Keyword.take(opts, [:cd, :env])

      case Forcola.run([binary | args], forcola_opts) do
        {:ok, %Forcola.Result{status: status, stdout: stdout}} when is_integer(status) ->
          {:ok, {stdout, status}}

        {:ok, %Forcola.Result{status: {:signal, signal}}} ->
          {:error, {:signal, signal}}

        {:error, {:timeout, _partial}} ->
          {:error, :timeout}

        {:error, {:spawn, reason}} ->
          {:error, {:spawn, reason}}
      end
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      forcola_opts =
        [
          timeout_ms: @unbounded_ms,
          idle_timeout_ms: timeout || @stream_idle_timeout_ms
        ] ++ Keyword.take(opts, [:cd, :env])

      # merge_stderr defaults to false: stderr must not be folded into the
      # NDJSON line stream, where it would feed non-JSON to the parser.
      halting_lines(Forcola.Stream.lines([binary | args], forcola_opts))
    end

    # Forcola.Stream.lines/2 raises Forcola.Stream.Error on a non-clean
    # termination (non-zero exit, signal, timeout) after emitting every
    # line produced before death. Runner.Port's streaming path halts
    # silently on exit instead, so to keep Query.stream/2's contract
    # identical across runners we enumerate in a linked task and treat the
    # terminal error as end-of-stream.
    #
    # Halting the outer stream early shuts the task down; the task owns the
    # forcola port, so killing it closes the port and the shim group-kills
    # the CLI tree -- the leak-free property is preserved.
    defp halting_lines(stream) do
      Stream.resource(
        fn ->
          # self() here is the process that enumerates the outer stream;
          # the task forwards lines to it.
          parent = self()
          ref = make_ref()

          task =
            Task.async(fn ->
              try do
                Enum.each(stream, fn line -> send(parent, {ref, :line, line}) end)
              rescue
                _ -> :ok
              after
                send(parent, {ref, :done})
              end
            end)

          {task, ref}
        end,
        fn {_task, ref} = state ->
          receive do
            {^ref, :line, line} -> {[line], state}
            {^ref, :done} -> {:halt, state}
          end
        end,
        fn {task, _ref} -> Task.shutdown(task, :brutal_kill) end
      )
    end

    defp merge_stderr?(opts), do: Keyword.get(opts, :stderr_to_stdout, false)
  end
end
