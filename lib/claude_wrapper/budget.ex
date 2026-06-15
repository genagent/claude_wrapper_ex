defmodule ClaudeWrapper.Budget do
  @moduledoc """
  Cumulative USD budget tracker with threshold callbacks.

  A budget process accumulates cost across turns and fires
  caller-supplied callbacks when configurable thresholds are first
  crossed. When a `:max_usd` ceiling is set, `check/1` returns
  `{:error, %ClaudeWrapper.Error{kind: :budget_exceeded}}` once the
  running total is at or above the ceiling, giving callers a hard stop
  before the next CLI invocation.

  This is the Elixir port of the Rust crate's `BudgetTracker` /
  `BudgetBuilder`. The Rust type is an `Arc<Mutex<...>>` handle shared
  across clones; the idiomatic Elixir equivalent is a `GenServer` whose
  pid (or registered name) is the shared handle. It mirrors the
  process-based style of `ClaudeWrapper.SessionServer` and
  `ClaudeWrapper.DuplexSession`.

  It is self-contained: `ClaudeWrapper.Session` and
  `ClaudeWrapper.SessionServer` are not aware of it. Drive it yourself
  from a multi-turn loop -- record each turn's `total_cost_usd`, then
  `check/1` before the next turn.

  ## Threshold semantics

    * `:warn_at_usd` -- `:on_warning` fires the first time the running
      total is at or above this value, and never again until `reset/1`.
    * `:max_usd` -- `:on_exceeded` fires the first time the running
      total is at or above this value, and `check/1` returns
      `{:error, %ClaudeWrapper.Error{kind: :budget_exceeded}}` from then
      on.

  Both thresholds are "at or above" (`>=`), so a record that lands the
  total exactly on the threshold crosses it. Non-positive and
  non-finite costs are ignored. `reset/1` clears the total and re-arms
  both callbacks so they can fire again.

  ## Usage

      {:ok, budget} =
        ClaudeWrapper.Budget.start_link(
          max_usd: 5.00,
          warn_at_usd: 4.00,
          on_warning: fn total -> IO.puts("warning: $\#{total} spent") end,
          on_exceeded: fn total -> IO.puts("budget hit: $\#{total}") end
        )

      # In a multi-turn loop, after each turn:
      :ok = ClaudeWrapper.Budget.record(budget, result.total_cost_usd)

      case ClaudeWrapper.Budget.check(budget) do
        :ok -> :keep_going
        {:error, %ClaudeWrapper.Error{kind: :budget_exceeded, reason: %{total_usd: total, max_usd: max}}} -> {:halt, total, max}
      end

      ClaudeWrapper.Budget.total(budget)
      #=> 4.32
  """

  use GenServer

  @typedoc "A running budget process: its pid or registered name."
  @type server :: GenServer.server()

  @typedoc """
  Callback invoked when a threshold is first crossed. Receives the
  running total (in USD) at the moment of the crossing.
  """
  @type callback :: (float() -> any())

  @type option ::
          {:max_usd, float() | nil}
          | {:warn_at_usd, float() | nil}
          | {:on_warning, callback() | nil}
          | {:on_exceeded, callback() | nil}
          | {:name, GenServer.name()}
          | GenServer.option()

  defmodule State do
    @moduledoc false

    @enforce_keys [:total, :warned, :exceeded]
    defstruct max_usd: nil,
              warn_at_usd: nil,
              on_warning: nil,
              on_exceeded: nil,
              total: 0.0,
              warned: false,
              exceeded: false

    @type t :: %__MODULE__{
            max_usd: float() | nil,
            warn_at_usd: float() | nil,
            on_warning: ClaudeWrapper.Budget.callback() | nil,
            on_exceeded: ClaudeWrapper.Budget.callback() | nil,
            total: float(),
            warned: boolean(),
            exceeded: boolean()
          }
  end

  # --- Client API ---

  @doc """
  Start a budget tracker.

  ## Options

    * `:max_usd` - Hard ceiling in USD. Once the running total reaches
      this value, `check/1` returns
      `{:error, %ClaudeWrapper.Error{kind: :budget_exceeded}}`. `nil`
      (default) means no ceiling.
    * `:warn_at_usd` - Warning threshold in USD. `:on_warning` fires
      the first time the running total reaches this value. `nil`
      (default) means no warning.
    * `:on_warning` - 1-arity function fired once when `:warn_at_usd`
      is crossed. Receives the running total.
    * `:on_exceeded` - 1-arity function fired once when `:max_usd` is
      crossed. Receives the running total.
    * `:name` - Register the process with a name.

  Also accepts standard `GenServer.start_link/3` options.
  """
  @spec start_link([option()]) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {max_usd, opts} = Keyword.pop(opts, :max_usd)
    {warn_at_usd, opts} = Keyword.pop(opts, :warn_at_usd)
    {on_warning, opts} = Keyword.pop(opts, :on_warning)
    {on_exceeded, opts} = Keyword.pop(opts, :on_exceeded)

    init_arg = %{
      max_usd: max_usd,
      warn_at_usd: warn_at_usd,
      on_warning: on_warning,
      on_exceeded: on_exceeded
    }

    GenServer.start_link(__MODULE__, init_arg, opts)
  end

  @doc """
  Record an additional cost in USD.

  Fires `:on_warning` the first time the running total reaches
  `:warn_at_usd`, and `:on_exceeded` the first time it reaches
  `:max_usd`. Non-positive and non-finite costs are ignored.

  Returns `:ok`.
  """
  @spec record(server(), number()) :: :ok
  def record(server, cost) when is_number(cost) do
    GenServer.call(server, {:record, cost})
  end

  @doc """
  Check the budget against the configured ceiling.

  Returns `{:error, %ClaudeWrapper.Error{kind: :budget_exceeded}}` (with
  `:reason` `%{total_usd: total, max_usd: max}`) when the running total
  is at or above `:max_usd`, and `:ok` otherwise (including when no
  ceiling is set).
  """
  @spec check(server()) :: :ok | {:error, ClaudeWrapper.Error.t()}
  def check(server) do
    GenServer.call(server, :check)
  end

  @doc "Cumulative cost recorded so far, in USD."
  @spec total(server()) :: float()
  def total(server) do
    GenServer.call(server, :total)
  end

  @doc """
  Remaining budget in USD.

  Returns `nil` when no `:max_usd` ceiling is set. Otherwise returns
  `max - total`, clamped at `0.0` once the ceiling is reached.
  """
  @spec remaining(server()) :: float() | nil
  def remaining(server) do
    GenServer.call(server, :remaining)
  end

  @doc "Configured ceiling in USD, or `nil` when none is set."
  @spec max_usd(server()) :: float() | nil
  def max_usd(server) do
    GenServer.call(server, :max_usd)
  end

  @doc "Configured warning threshold in USD, or `nil` when none is set."
  @spec warn_at_usd(server()) :: float() | nil
  def warn_at_usd(server) do
    GenServer.call(server, :warn_at_usd)
  end

  @doc """
  Clear the running total and re-arm both callbacks.

  After a reset the total is `0.0` and `:on_warning` / `:on_exceeded`
  can fire again the next time their thresholds are crossed.

  Returns `:ok`.
  """
  @spec reset(server()) :: :ok
  def reset(server) do
    GenServer.call(server, :reset)
  end

  # --- Server callbacks ---

  @impl true
  def init(%{} = init_arg) do
    state = %State{
      max_usd: init_arg.max_usd,
      warn_at_usd: init_arg.warn_at_usd,
      on_warning: init_arg.on_warning,
      on_exceeded: init_arg.on_exceeded,
      total: 0.0,
      warned: false,
      exceeded: false
    }

    {:ok, state}
  end

  @impl true
  def handle_call({:record, cost}, _from, state) do
    {:reply, :ok, apply_cost(state, cost)}
  end

  def handle_call(:check, _from, state) do
    {:reply, check_state(state), state}
  end

  def handle_call(:total, _from, state) do
    {:reply, state.total, state}
  end

  def handle_call(:remaining, _from, state) do
    {:reply, remaining_state(state), state}
  end

  def handle_call(:max_usd, _from, state) do
    {:reply, state.max_usd, state}
  end

  def handle_call(:warn_at_usd, _from, state) do
    {:reply, state.warn_at_usd, state}
  end

  def handle_call(:reset, _from, state) do
    {:reply, :ok, %{state | total: 0.0, warned: false, exceeded: false}}
  end

  # --- Internals ---

  # Accumulate a cost, fire any newly-crossed threshold callbacks, and
  # return the updated state. Mirrors the Rust `record`: thresholds are
  # evaluated against the new total, then callbacks fire once.
  #
  # Non-positive costs are ignored. Rust additionally guards against
  # non-finite costs (`cost_usd.is_finite()`); on the BEAM a numeric
  # term is always finite (the arithmetic that would yield NaN or
  # infinity raises ArithmeticError instead of producing a float), so
  # `record/2`'s `is_number/1` guard already covers that case.
  defp apply_cost(state, cost) when cost <= 0.0, do: state

  defp apply_cost(state, cost) do
    state
    |> Map.update!(:total, &(&1 + cost))
    |> fire_warning()
    |> fire_exceeded()
  end

  defp fire_warning(%State{warned: true} = state), do: state
  defp fire_warning(%State{warn_at_usd: nil} = state), do: state

  defp fire_warning(%State{warn_at_usd: threshold, total: total} = state)
       when total >= threshold do
    maybe_invoke(state.on_warning, total)
    %{state | warned: true}
  end

  defp fire_warning(state), do: state

  defp fire_exceeded(%State{exceeded: true} = state), do: state
  defp fire_exceeded(%State{max_usd: nil} = state), do: state

  defp fire_exceeded(%State{max_usd: threshold, total: total} = state)
       when total >= threshold do
    maybe_invoke(state.on_exceeded, total)
    %{state | exceeded: true}
  end

  defp fire_exceeded(state), do: state

  defp check_state(%State{max_usd: nil}), do: :ok

  defp check_state(%State{max_usd: max, total: total}) when total >= max do
    {:error, ClaudeWrapper.Error.new(:budget_exceeded, reason: %{total_usd: total, max_usd: max})}
  end

  defp check_state(_state), do: :ok

  defp remaining_state(%State{max_usd: nil}), do: nil

  defp remaining_state(%State{max_usd: max, total: total}) do
    max(max - total, 0.0)
  end

  defp maybe_invoke(nil, _total), do: :ok
  defp maybe_invoke(fun, total) when is_function(fun, 1), do: fun.(total)
end
