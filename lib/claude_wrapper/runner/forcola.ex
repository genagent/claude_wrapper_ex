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

    Requires forcola `~> 0.7.0`. `claude -p` documents piped
    stdin as a supported input channel ("useful for pipes" in `claude --help`), and
    before 0.3.4 `Forcola.run/2` and `Forcola.Stream.lines/2` left the
    child's stdin open and unfed after spawn -- a child that reads it
    blocked until the timeout below instead of exiting normally
    (forcola#67). 0.3.4 closes the child's stdin right after spawn, so
    this module needs no stdin handling of its own.

    ## Evidenced execution

    `run_evidenced/5` runs one `Forcola.run/2` and reports its
    bounded-execution evidence using Forcola 0.7 and its matching shim.
    The shim must support the bounded-run capability exchange. If an
    unsupported Forcola is loaded, it returns `{:error, {:evidence_unsupported, :forcola_result_lacks_evidence}}`
    before spawning. An older shim is rejected by Forcola itself before the
    child is spawned (`{:spawn, :incompatible_shim}`).

    Runner options (from `ClaudeWrapper.Config` `:runner_options`, validated
    before spawning; unknown keys are rejected):

      * `:max_output_bytes` - combined stdout+stderr bound, positive integer at
        most `4_294_967_295`. Default `67_108_864` (64 MiB). Exceeding it
        cancels the run with partial output retained.
      * `:idle_timeout_ms` - cancel after this long without output,
        independently of the whole-run `Config.timeout`
      * `:max_line_bytes` - per-line bound for the session/rate-limit
        observers (default 1 MiB). A longer stdout line is not observed and
        is counted in the evidence `:lines_dropped`; it is still retained in
        the bounded stdout.
      * `:env_mode` - `:inherit` (default) or `:replace`. Replacement clears
        the inherited environment before applying `Config.env`; use an
        absolute `Config.binary` when clearing `PATH`.
      * `:interrupt_signal` / `:interrupt_grace_ms` - the pair
        `interrupt_signal: :int, interrupt_grace_ms: ms` makes Forcola's
        native supervisor send SIGINT to the process group and wait `ms`
        before its TERM/KILL escalation
      * `:kill_grace_ms` - Forcola's TERM-to-KILL grace
      * `:shim_path` - a trusted absolute path to a matching Forcola shim

    `Config.timeout` is the whole-run bound (24 hours when `nil`) and is not
    reset by output. `Config.env` entries must be `{name, value}` strings.

    The native run executes in an owned helper process; Forcola's
    `:output_observer` frames arrive in the execution caller, which frames
    stdout lines and runs the observer itself. Forcola cancels the run if the
    caller's queue reaches its observer bound. If the execution caller dies,
    the helper exits and Forcola's shim cleans up as for owner death. If the
    helper dies, the call returns `{:error, {:helper_down, reason}}` with
    unknown cleanup. This module never signals the child itself.

    Evidence `:cleanup` is `:confirmed` only when the shim explicitly
    confirmed it, and `:scope` says what that covers. A process-group
    confirmation does not include descendants that escaped the group.
    """

    @behaviour ClaudeWrapper.Runner

    alias ClaudeWrapper.Runner.{Collector, ForcolaEvidence}

    # forcola requires a mandatory whole-run bound. When the caller sets
    # no timeout we still want group-kill-on-BEAM-death, so we pass a very
    # large bound rather than falling back to the leaky path.
    @unbounded_ms 24 * 60 * 60 * 1000

    # Streaming safety: bounds the gap between output frames when no finite
    # whole-run deadline was configured.
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

    @doc """
    Run to completion while observing stdout lines with a trusted callback.

    The timeout bounds the whole run, including a producer that keeps writing.
    Stderr is never merged into observed lines. See `ClaudeWrapper.Runner` for
    the callback and normalized output contract.
    """
    @spec run_observed(
            String.t(),
            [String.t()],
            keyword(),
            timeout() | nil,
            ClaudeWrapper.Runner.line_observer()
          ) ::
            {:ok, {String.t(), non_neg_integer(), String.t()}}
            | {:error, ClaudeWrapper.Runner.error()}
    @impl true
    def run_observed(binary, args, opts, timeout, observer) do
      forcola_opts =
        [timeout_ms: timeout || @unbounded_ms, merge_stderr: false] ++
          Keyword.take(opts, [:cd, :env])

      stream = Forcola.Stream.lines([binary | args], forcola_opts)
      next = &Enumerable.reduce(stream, &1, fn line, _acc -> {:suspend, line} end)
      collect_observed(next, [], observer)
    end

    # Suspend after each line so the accumulated stdout survives a terminal
    # Forcola.Stream.Error. An ordinary Enum.reduce would lose its accumulator
    # when that exception unwinds. Resuming to completion retains the stream's
    # cleanup handshake, including failures after a terminal JSON result.
    defp collect_observed(next, lines, observer) do
      case next_observed(next) do
        {:suspended, line, continuation} ->
          observer = observe_line(observer, line)
          collect_observed(continuation, [[line, "\n"] | lines], observer)

        {finished, _acc} when finished in [:done, :halted] ->
          {:ok, {observed_stdout(lines), 0, ""}}

        {:error, error} ->
          observed_failure(error, lines)
      end
    end

    defp next_observed(next) do
      next.({:cont, nil})
    rescue
      error in Forcola.Stream.Error -> {:error, error}
    end

    defp observe_line(nil, _line), do: nil

    defp observe_line(observer, line) do
      case observer.(line) do
        :observed -> nil
        :continue -> observer
        {:continue, next_observer} when is_function(next_observer, 1) -> next_observer
      end
    end

    defp observed_failure(%Forcola.Stream.Error{timed_out: true}, _lines),
      do: {:error, :timeout}

    defp observed_failure(%Forcola.Stream.Error{reason: reason}, _lines)
         when not is_nil(reason),
         do: {:error, {:spawn, reason}}

    defp observed_failure(%Forcola.Stream.Error{status: {:signal, signal}}, _lines),
      do: {:error, {:signal, signal}}

    defp observed_failure(%Forcola.Stream.Error{status: status, stderr: stderr}, lines)
         when is_integer(status),
         do: {:ok, {observed_stdout(lines), status, stderr}}

    defp observed_stdout(lines), do: lines |> Enum.reverse() |> IO.iodata_to_binary()

    @doc """
    Run one bounded `Forcola.run/2` and return its outcome with native
    evidence. See "Evidenced execution" above and
    `c:ClaudeWrapper.Runner.run_evidenced/5`.
    """
    @spec run_evidenced(
            String.t(),
            [String.t()],
            keyword(),
            timeout() | nil,
            ClaudeWrapper.Runner.line_observer()
          ) :: ClaudeWrapper.Runner.evidenced_result()
    @impl true
    def run_evidenced(binary, args, opts, timeout, observer) do
      with :ok <- evidence_supported(),
           {:ok, forcola_opts, max_line} <- ForcolaEvidence.build(opts, timeout) do
        argv = [binary | args]
        run = fn target -> Forcola.run(argv, [{:output_observer, target} | forcola_opts]) end

        run
        |> Collector.run(observer,
          max_line_bytes: max_line,
          max_output_bytes: forcola_opts[:max_output_bytes]
        )
        |> ForcolaEvidence.translate()
      else
        {:error, reason} -> {{:error, reason}, ClaudeWrapper.Runner.not_started_evidence()}
      end
    end

    defp evidence_supported do
      if ForcolaEvidence.supported?(Forcola.Result) do
        :ok
      else
        {:error, {:evidence_unsupported, :forcola_result_lacks_evidence}}
      end
    end

    @impl true
    def stream_lines(binary, args, opts, timeout) do
      whole_timeout = if is_integer(timeout), do: timeout, else: @unbounded_ms
      idle_timeout = if is_integer(timeout), do: timeout, else: @stream_idle_timeout_ms

      forcola_opts =
        [
          timeout_ms: whole_timeout,
          idle_timeout_ms: idle_timeout
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
