defmodule ClaudeWrapper.Retry do
  @moduledoc """
  Retry policy with exponential backoff for query execution.

  ## Usage

      config = ClaudeWrapper.Config.new()
      query = ClaudeWrapper.Query.new("fix the bug")

      # Retry up to 3 times with exponential backoff
      {:ok, result} = ClaudeWrapper.Retry.execute(query, config,
        max_retries: 3,
        base_delay_ms: 1_000,
        max_delay_ms: 30_000
      )

      # With custom retry predicate
      {:ok, result} = ClaudeWrapper.Retry.execute(query, config,
        retry_on: fn
          {:error, %ClaudeWrapper.Error{kind: :command_failed, exit_code: 1}} -> true
          {:error, %ClaudeWrapper.Error{kind: :timeout}} -> true
          _ -> false
        end
      )
  """

  alias ClaudeWrapper.{Config, Error, Query, Result}

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
      The default retries `:timeout` errors, plain non-zero `:command_failed`
      exits, and rate limits (`:auth` errors with reason `:rate_limit`). Other
      auth failures and rail-stop errors (`:max_turns_exceeded`,
      `:max_budget_exceeded`) are not retried.
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

    case Query.execute(query, config) do
      {:ok, _result} = success ->
        success

      {:error, _reason} = error ->
        if attempt < max_retries and retry_on.(error) do
          delay = compute_delay(attempt, base_delay, max_delay, multiplier, jitter?)
          Process.sleep(delay)
          do_execute(query, config, attempt + 1, opts)
        else
          error
        end
    end
  end

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
  def default_retry_on({:error, %Error{kind: :timeout}}), do: true

  def default_retry_on({:error, %Error{kind: :command_failed, exit_code: code}})
      when code != 0,
      do: true

  # Recognized rate limits are reclassified to :auth/:rate_limit by query.ex; a
  # bounded backoff-retry is appropriate (other :auth reasons re-fail identically).
  def default_retry_on({:error, %Error{kind: :auth, reason: :rate_limit}}), do: true

  def default_retry_on(_), do: false
end
