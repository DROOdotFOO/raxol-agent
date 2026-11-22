defmodule Raxol.Payments.Poll do
  @moduledoc """
  Shared status-polling engine for cross-chain settlement.

  Settlement is observed only by polling (Riddler has no client-facing push), so
  to see a sub-three-second settlement the loop polls fast inside a short budget
  window, then widens for the long tail to avoid hammering the service:

  * For the first `:budget_ms`, poll every `:fast_interval_ms`.
  * After that, poll every `:slow_interval_ms` until `:timeout_ms`.
  * An HTTP 429 is treated as a transient backoff, not a failure.

  `run/3` returns `{:ok, status, elapsed_ms}` when `terminal?` first holds, so the
  caller can classify the settlement as within-budget or slow. It returns
  `{:error, :timeout}` at the ceiling (`{:error, {:timeout, last_status}}` with
  `last_status_on_timeout: true`, `last_status` nil when no fetch succeeded) and
  `{:error, reason}` on a non-retryable fetch error.

  ## Clock

  Every reading of the time and every wait between polls goes through the
  `:clock` option, `system_clock/0` by default. A caller that passes its own
  (such as a test's virtual clock, whose time moves only when the poller
  waits) decides the elapsed time, so how many polls fit before the
  deadline depends on the clock and not on how fast the host runs.
  """

  @default_budget_ms 3_000
  @default_fast_interval_ms 300
  @default_slow_interval_ms 2_000
  @default_timeout_ms 120_000

  @type result :: {:ok, term(), non_neg_integer()} | {:error, term()}

  @typedoc """
  The time source of `run/3`: `now_ms` reads monotonic milliseconds, and
  `sleep_ms` waits that many milliseconds.
  """
  @type clock :: %{now_ms: (-> integer()), sleep_ms: (non_neg_integer() -> term())}

  @doc "The real clock: `System.monotonic_time/1` and `Process.sleep/1`."
  @spec system_clock() :: clock()
  def system_clock,
    do: %{now_ms: fn -> System.monotonic_time(:millisecond) end, sleep_ms: &Process.sleep/1}

  @doc "Default budget window in milliseconds."
  @spec default_budget_ms() :: pos_integer()
  def default_budget_ms, do: @default_budget_ms

  @doc """
  Poll `fetch` until `terminal?` holds, the deadline passes, or a fetch fails.

  `fetch` is a 0-arity function returning `{:ok, status} | {:error, reason}`;
  `terminal?` takes a status and returns a boolean.
  """
  @spec run((-> {:ok, term()} | {:error, term()}), (term() -> boolean()), keyword()) :: result()
  def run(fetch, terminal?, opts \\ [])
      when is_function(fetch, 0) and is_function(terminal?, 1) do
    clock = Keyword.get(opts, :clock, system_clock())
    start = clock.now_ms.()

    state = %{
      clock: clock,
      start: start,
      budget: Keyword.get(opts, :budget_ms, @default_budget_ms),
      fast: Keyword.get(opts, :fast_interval_ms, @default_fast_interval_ms),
      slow: Keyword.get(opts, :slow_interval_ms, @default_slow_interval_ms),
      deadline: start + Keyword.get(opts, :timeout_ms, @default_timeout_ms),
      with_last: Keyword.get(opts, :last_status_on_timeout, false),
      last: nil
    }

    do_poll(fetch, terminal?, state)
  end

  defp do_poll(fetch, terminal?, state) do
    case fetch.() do
      {:ok, status} ->
        if terminal?.(status),
          do: {:ok, status, elapsed(state)},
          else: wait_or_timeout(fetch, terminal?, %{state | last: status})

      {:error, reason} ->
        if backoff?(reason),
          do: wait_or_timeout(fetch, terminal?, state),
          else: {:error, reason}
    end
  end

  defp wait_or_timeout(fetch, terminal?, state) do
    now = state.clock.now_ms.()
    interval = if now - state.start < state.budget, do: state.fast, else: state.slow

    if now + interval > state.deadline do
      if state.with_last, do: {:error, {:timeout, state.last}}, else: {:error, :timeout}
    else
      state.clock.sleep_ms.(interval)
      do_poll(fetch, terminal?, state)
    end
  end

  # Rate limiting is transient: back off and keep polling rather than fail.
  defp backoff?({:http, 429, _body}), do: true
  defp backoff?(_reason), do: false

  defp elapsed(state), do: state.clock.now_ms.() - state.start
end
