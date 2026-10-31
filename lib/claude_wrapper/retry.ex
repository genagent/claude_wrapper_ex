defmodule ClaudeWrapper.Retry do
  @moduledoc """
  Retry policy with exponential backoff for query execution.

  ## What a retry repeats

  Each attempt runs the same query as a new CLI process: it re-sends the
  prompt, and the model may run the same tools again. The tool effects of a
  failed attempt (file edits, commits, pushes, shell commands) are not
  undone. So by default only failures that ended the run before any tool
  ran are retried: an `:api_error` result in the `:rate_limit`,
  `:overloaded`, `:server_error` or `:connection` category whose
  `num_turns` is 0, 1 or absent.

  `:timeout`, non-zero `:command_failed` and `:auth` rate limits can happen
  after tools ran, so they are retried only when a caller `:retry_on` opts
  in, and with two further limits:

    * A `:timeout` is retried only when the runner confirmed that the
      timed-out attempt's process group exited, so attempts never overlap.
      When the runner implements `c:ClaudeWrapper.Runner.run_evidenced/5`
      (`ClaudeWrapper.Runner.Forcola`), each attempt runs through
      `ClaudeWrapper.Query.execute/3` with an `:execution_observer`, and a
      timeout is retried only when the evidence has `cleanup: :confirmed`.
      With `ClaudeWrapper.Runner.Port` a timeout is returned without a retry.
    * A query that pins `--session-id` (`ClaudeWrapper.Query.session_id/2`)
      is never retried: the first attempt takes the id, and a second
      invocation fails with "Session ID ... is already in use".

  ## Usage

      config = ClaudeWrapper.Config.new()
      query = ClaudeWrapper.Query.new("fix the bug")

      # Retry up to 3 times with exponential backoff
      {:ok, result} = ClaudeWrapper.Retry.execute(query, config,
        max_retries: 3,
        base_delay_ms: 1_000,
        max_delay_ms: 30_000
      )

      # Opt in to retrying failures that may follow tool use
      {:ok, result} = ClaudeWrapper.Retry.execute(query, config,
        retry_on: fn
          {:error, %ClaudeWrapper.Error{kind: :command_failed, exit_code: 1}} -> true
          {:error, %ClaudeWrapper.Error{kind: :timeout}} -> true
          _ -> false
        end
      )
  """

  alias ClaudeWrapper.{Config, Error, ExecutionEvidence, Query, Result, Runner}

  @type opts :: [
          max_retries: non_neg_integer(),
          base_delay_ms: pos_integer(),
          max_delay_ms: pos_integer(),
          multiplier: number(),
          jitter: boolean(),
          retry_on: (term() -> boolean())
        ]

  @default_max_retries 3
  @default_base_delay_ms 1_000
  @default_max_delay_ms 30_000
  @default_multiplier 2

  @doc """
  Execute a query with retry logic.

  ## Options

    * `:max_retries` - Maximum number of retry attempts (default: 3)
    * `:base_delay_ms` - Initial delay between retries in ms (default: 1000)
    * `:max_delay_ms` - Maximum delay cap in ms (default: 30000)
    * `:multiplier` - Backoff multiplier (default: 2)
    * `:jitter` - Add random jitter to delays (default: true)
    * `:retry_on` - Function that receives the error and returns whether to retry.
      The default retries only `:api_error` results in the `:rate_limit`,
      `:overloaded`, `:server_error` and `:connection` categories when the
      run ended before any tool ran (`num_turns` of 1 or less). Timeouts,
      command failures, auth failures (including rate limits classified
      from CLI output), client API errors and rail-stop errors
      (`:max_turns_exceeded`, `:max_budget_exceeded`) are not retried
      unless this function opts in. Even then, a `:timeout` is retried only
      after the runner confirmed the attempt exited, and a query with a
      pinned `--session-id` is not retried (see the moduledoc).
  """
  @spec execute(Query.t(), Config.t(), opts()) :: {:ok, Result.t()} | {:error, term()}
  def execute(%Query{} = query, %Config{} = config, opts \\ []) do
    max_retries = Keyword.get(opts, :max_retries, @default_max_retries)
    base_delay = Keyword.get(opts, :base_delay_ms, @default_base_delay_ms)
    max_delay = Keyword.get(opts, :max_delay_ms, @default_max_delay_ms)
    multiplier = Keyword.get(opts, :multiplier, @default_multiplier)
    jitter? = Keyword.get(opts, :jitter, true)
    retry_on = Keyword.get(opts, :retry_on, &default_retry_on/1)

    retry_opts = %{
      max_retries: max_retries,
      base_delay: base_delay,
      max_delay: max_delay,
      multiplier: multiplier,
      jitter?: jitter?,
      retry_on: retry_on
    }

    do_execute(query, config, 0, retry_opts)
  end

  defp do_execute(query, config, attempt, opts) do
    %{
      max_retries: max_retries,
      base_delay: base_delay,
      max_delay: max_delay,
      multiplier: multiplier,
      jitter?: jitter?,
      retry_on: retry_on
    } = opts

    case run_attempt(query, config) do
      {{:ok, _result} = success, _evidence} ->
        success

      {{:error, _reason} = error, evidence} ->
        if attempt < max_retries and retryable?(query, error, evidence, retry_on) do
          delay = compute_delay(attempt, base_delay, max_delay, multiplier, jitter?)
          Process.sleep(delay)
          do_execute(query, config, attempt + 1, opts)
        else
          error
        end
    end
  end

  # With a runner that reports execution evidence, run through execute/3 so a
  # timed-out attempt's cleanup is known; otherwise the plain execute/2 path.
  defp run_attempt(query, config) do
    runner = Runner.impl(config)

    if Code.ensure_loaded?(runner) and function_exported?(runner, :run_evidenced, 5) do
      reference = make_ref()
      reply = Query.execute(query, config, execution_observer: {self(), reference})

      receive do
        {^reference, %ExecutionEvidence{} = evidence} -> {reply, evidence}
      after
        0 -> {reply, nil}
      end
    else
      {Query.execute(query, config), nil}
    end
  end

  # A pinned --session-id is taken by the first attempt, and a timed-out
  # attempt may still be running unless the runner confirmed its exit; either
  # way a retry cannot run cleanly, whatever retry_on says (#317).
  defp retryable?(%Query{session_id: session_id}, _error, _evidence, _retry_on)
       when is_binary(session_id),
       do: false

  defp retryable?(_query, {:error, %Error{kind: :timeout}} = error, evidence, retry_on) do
    match?(%ExecutionEvidence{cleanup: :confirmed}, evidence) and retry_on.(error)
  end

  defp retryable?(_query, error, _evidence, retry_on), do: retry_on.(error)

  @doc """
  Compute the delay for a given attempt number.
  """
  @spec compute_delay(non_neg_integer(), pos_integer(), pos_integer(), number(), boolean()) ::
          non_neg_integer()
  def compute_delay(attempt, base_delay, max_delay, multiplier, jitter?) do
    delay = round(base_delay * :math.pow(multiplier, attempt))
    delay = min(delay, max_delay)

    if jitter? do
      # Full jitter: random value between 0 and computed delay
      :rand.uniform(delay + 1) - 1
    else
      delay
    end
  end

  @doc false
  # The default `:retry_on` predicate. Public (@doc false) so it is unit-testable
  # without a paid claude call.
  #
  # Only an API error the CLI reported for a turn that ran no tools (#316):
  # rate limits, overload, server errors and refused connections are
  # transient. After a tool round trip (num_turns > 1), and for timeouts,
  # command failures and rate limits classified from CLI output (which can
  # follow tool use), a retry would repeat tool side effects (#317), so those
  # are left to a caller :retry_on.
  def default_retry_on(
        {:error, %Error{kind: :api_error, reason: %{category: category, num_turns: turns}}}
      )
      when category in [:rate_limit, :overloaded, :server_error, :connection] and
             turns in [nil, 0, 1],
      do: true

  def default_retry_on(_), do: false
end
