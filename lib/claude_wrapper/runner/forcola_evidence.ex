defmodule ClaudeWrapper.Runner.ForcolaEvidence do
  @moduledoc false
  # Option validation and outcome translation for
  # `ClaudeWrapper.Runner.Forcola.run_evidenced/5`.
  #
  # Kept free of compile-time references to Forcola so it compiles (and is
  # testable with fakes) whether or not the optional dependency, or a Forcola
  # version with bounded-execution evidence, is present. Forcola results are
  # matched as plain maps with `:status`, `:stdout`, `:stderr` and an optional
  # `:evidence` map.

  alias ClaudeWrapper.Runner
  alias ClaudeWrapper.Runner.Collector

  @max_u32 4_294_967_295

  # Forcola requires a whole-run bound; with no configured timeout the
  # evidenced path keeps the legacy 24-hour bound.
  @unbounded_ms 24 * 60 * 60 * 1000

  # Default combined stdout+stderr bound. Always passing it also makes every
  # evidenced run a strict Forcola run, which requires the versioned shim
  # capability exchange before the child is spawned.
  @default_max_output_bytes 64 * 1024 * 1024

  @passthrough [
    :shim_path,
    :env_mode,
    :idle_timeout_ms,
    :interrupt_signal,
    :interrupt_grace_ms,
    :kill_grace_ms
  ]

  @known [:max_output_bytes, :max_line_bytes | @passthrough]

  @doc false
  @spec known_options() :: [atom()]
  def known_options, do: @known

  @doc false
  @spec default_max_output_bytes() :: pos_integer()
  def default_max_output_bytes, do: @default_max_output_bytes

  @doc false
  # Validate the resolved runner options and build the `Forcola.run/2`
  # keyword list (without `:output_observer`). Returns
  # `{:ok, forcola_opts, max_line_bytes}` or
  # `{:error, {:invalid_runner_options, reason}}`, always before spawning.
  @spec build(keyword(), timeout() | nil) ::
          {:ok, keyword(), pos_integer()} | {:error, {:invalid_runner_options, term()}}
  def build(opts, timeout) do
    options = Keyword.get(opts, :runner_options, [])

    with :ok <- validate_shape(options),
         :ok <- validate_each(options),
         :ok <- validate_interrupt(options),
         :ok <- validate_timeout(timeout),
         :ok <- validate_cd(opts[:cd]),
         :ok <- validate_env(Keyword.get(opts, :env, [])) do
      max_output = Keyword.get(options, :max_output_bytes, @default_max_output_bytes)
      max_line = Keyword.get(options, :max_line_bytes, Collector.default_max_line_bytes())

      bounds = [timeout_ms: timeout || @unbounded_ms, max_output_bytes: max_output]

      forcola_opts =
        [{:merge_stderr, false} | bounds] ++
          Keyword.take(opts, [:cd, :env]) ++ Keyword.take(options, @passthrough)

      {:ok, forcola_opts, max_line}
    end
  end

  defp validate_shape(options) do
    if ClaudeWrapper.Config.keyword_options?(options) do
      :ok
    else
      invalid(:runner_options, options)
    end
  end

  defp validate_each(options) do
    Enum.reduce_while(options, :ok, fn {key, value}, :ok ->
      case validate_option(key, value) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp validate_option(key, value)
       when key in [:idle_timeout_ms, :max_output_bytes, :interrupt_grace_ms, :max_line_bytes] do
    if u32?(value, 1), do: :ok, else: invalid(key, value)
  end

  defp validate_option(:kill_grace_ms, value) do
    if u32?(value, 0), do: :ok, else: invalid(:kill_grace_ms, value)
  end

  defp validate_option(:env_mode, value) when value in [:inherit, :replace], do: :ok
  defp validate_option(:interrupt_signal, :int), do: :ok

  defp validate_option(:shim_path, value) when is_binary(value) do
    if Path.type(value) == :absolute and not String.contains?(value, <<0>>),
      do: :ok,
      else: invalid(:shim_path, value)
  end

  defp validate_option(key, value) when key in @known, do: invalid(key, value)
  defp validate_option(key, _value), do: {:error, {:invalid_runner_options, {:unknown, key}}}

  # The interrupt signal and its grace are a pair: one without the other is
  # rejected rather than silently dropped.
  defp validate_interrupt(options) do
    signal? = Keyword.has_key?(options, :interrupt_signal)
    grace? = Keyword.has_key?(options, :interrupt_grace_ms)

    if signal? == grace? do
      :ok
    else
      invalid(:interrupt_signal, :requires_interrupt_grace_ms)
    end
  end

  defp validate_timeout(nil), do: :ok

  defp validate_timeout(timeout) do
    if u32?(timeout, 1), do: :ok, else: invalid(:timeout, timeout)
  end

  defp u32?(value, min), do: is_integer(value) and value >= min and value <= @max_u32

  defp validate_cd(nil), do: :ok
  defp validate_cd(cd) when is_binary(cd), do: :ok
  defp validate_cd(cd), do: invalid(:cd, cd)

  defp validate_env(env) when is_list(env) do
    case Enum.find(env, &(not valid_env?(&1))) do
      nil -> :ok
      entry -> invalid(:env, entry)
    end
  end

  defp validate_env(env), do: invalid(:env, env)

  defp valid_env?({name, value}) when is_binary(name) and is_binary(value),
    do:
      name != "" and not String.contains?(name, ["=", <<0>>]) and
        not String.contains?(value, <<0>>)

  defp valid_env?(_entry), do: false

  defp invalid(key, value), do: {:error, {:invalid_runner_options, {key, value}}}

  @doc false
  # True when the loaded Forcola exposes bounded-execution evidence on its
  # one-shot result. Checked at runtime from the struct definition so this
  # module does not depend on the Forcola version it was compiled against.
  @spec supported?(module()) :: boolean()
  def supported?(result_module) do
    Code.ensure_loaded?(result_module) and function_exported?(result_module, :__info__, 1) and
      Enum.any?(result_module.__info__(:struct) || [], &(&1.field == :evidence))
  end

  @doc false
  # Translate a collector outcome into `run_evidenced/5`'s
  # `{outcome, native_evidence}` pair.
  @spec translate({:done, term(), map()} | {:helper_down, term(), map()}) ::
          {term(), Runner.native_evidence()}
  def translate({:helper_down, reason, stats}) do
    stdout = Map.get(stats, :stdout, "")
    stderr = Map.get(stats, :stderr, "")

    native =
      Map.merge(unknown(stats.lines_dropped), %{
        execution: if(stdout != "" or stderr != "", do: :started, else: :unknown),
        stdout: stdout,
        stderr: stderr,
        output_truncated: Map.get(stats, :output_truncated, :unknown)
      })

    observer_outcome({{:error, {:helper_down, reason}}, native}, stats)
  end

  def translate({:done, outcome, stats}),
    do: observer_outcome(outcome(outcome, stats.lines_dropped), stats)

  defp observer_outcome({outcome, native}, stats) do
    case Map.get(stats, :observer_error) do
      nil -> {outcome, native}
      {kind, reason} -> {{:error, {:observer_failed, kind, reason}}, native}
    end
  end

  defp outcome({:ok, %{status: status} = result}, dropped) when is_integer(status),
    do: {{:ok, {result.stdout, status, result.stderr}}, evidence(result, dropped)}

  defp outcome({:ok, %{status: {:signal, signal}} = result}, dropped),
    do: {{:error, {:signal, signal}}, evidence(result, dropped)}

  defp outcome({:error, {reason, %{status: _} = result}}, dropped)
       when reason in [:timeout, :idle_timeout],
       do: {{:error, reason}, evidence(result, dropped)}

  defp outcome({:error, {reason, %{status: _} = result}}, dropped)
       when reason in [:max_output_bytes, :observer_overflow],
       do: {{:error, {:limit, reason}}, evidence(result, dropped)}

  defp outcome({:error, {:spawn, {reason, %{status: _} = result}}}, dropped),
    do: {{:error, {:spawn, reason}}, evidence(result, dropped)}

  # A bare spawn reason on a strict run comes from shim discovery, startup or
  # the capability exchange: SPAWN was never sent, so nothing executed.
  defp outcome({:error, {:spawn, reason}}, dropped) do
    evidence = %{Runner.not_started_evidence() | termination: {:spawn, reason}}
    {{:error, {:spawn, reason}}, %{evidence | lines_dropped: dropped}}
  end

  defp outcome(other, dropped),
    do: {{:error, {:io, {:unexpected_outcome, other}}}, unknown(dropped)}

  defp evidence(result, dropped) do
    native = Map.get(result, :evidence) || %{}
    stdout = binary(Map.get(result, :stdout))
    stderr = binary(Map.get(result, :stderr))

    %{
      execution: execution(native, stdout, stderr),
      child_status: Map.get(native, :child_status),
      child_signal: Map.get(native, :child_signal),
      termination: Map.get(native, :termination, :unknown),
      reason: Map.get(native, :reason),
      output_truncated: Map.get(native, :output_truncated, :unknown),
      cleanup: Map.get(native, :cleanup, :unknown),
      scope: Map.get(native, :scope, :unknown),
      guard_close: Map.get(native, :guard_close) || :unknown,
      stdout: stdout,
      stderr: stderr,
      lines_dropped: dropped
    }
  end

  defp execution(native, stdout, stderr) do
    reported? =
      Map.get(native, :termination) == :exit or
        is_integer(Map.get(native, :child_status)) or
        is_integer(Map.get(native, :child_signal))

    if reported? or stdout != "" or stderr != "", do: :started, else: :unknown
  end

  defp unknown(dropped) do
    %{
      execution: :unknown,
      child_status: nil,
      child_signal: nil,
      termination: :unknown,
      reason: nil,
      output_truncated: :unknown,
      cleanup: :unknown,
      scope: :unknown,
      guard_close: :unknown,
      stdout: "",
      stderr: "",
      lines_dropped: dropped
    }
  end

  defp binary(value) when is_binary(value), do: value
  defp binary(_value), do: ""
end
