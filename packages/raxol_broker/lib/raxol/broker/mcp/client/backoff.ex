defmodule Raxol.Broker.MCP.Client.Backoff do
  @moduledoc false

  # Pure retry arithmetic and failure classification for
  # `Raxol.Broker.MCP.Client`: delays, deadlines, and which results are
  # throttles, 401s or transient connect failures.

  alias Raxol.Broker.MCP.Client.State

  @default %{base_ms: 500, max_ms: 8_000, retries: 3}
  @throttle_statuses [429, 502, 503, 504]
  # `Process.send_after/3` refuses delays past 2^32 - 1 ms.
  @max_timer_ms 4_294_967_295

  @type t :: %{base_ms: non_neg_integer(), max_ms: non_neg_integer(), retries: non_neg_integer()}

  @spec max_timer_ms() :: pos_integer()
  def max_timer_ms, do: @max_timer_ms

  @doc "The `:backoff` option merged over the defaults, or `{:stop, {:invalid_backoff, opts}}`."
  @spec config(term()) :: {:ok, t()} | {:stop, {:invalid_backoff, term()}}
  def config(opts) do
    with true <- Keyword.keyword?(opts),
         %{base_ms: base, max_ms: max, retries: retries} = backoff when map_size(backoff) == 3 <-
           Map.merge(@default, Map.new(opts)),
         true <- valid?(base, max, retries) do
      {:ok, backoff}
    else
      _invalid -> {:stop, {:invalid_backoff, opts}}
    end
  end

  defp valid?(base, max, retries),
    do:
      is_integer(base) and base >= 0 and is_integer(max) and max >= base and
        max <= @max_timer_ms and is_integer(retries) and retries >= 0

  @doc "A new request's attempt: not yet retried or throttled, with the caller's deadline."
  @spec attempt(timeout()) :: State.attempt()
  def attempt(timeout) do
    deadline = if timeout == :infinity, do: :infinity, else: now_ms() + timeout
    %{retried: false, throttled: 0, last: nil, resend: false, deadline: deadline}
  end

  @doc "`base_ms * 2^n`, capped at `max_ms`."
  @spec max_delay(t(), non_neg_integer()) :: non_neg_integer()
  def max_delay(%{base_ms: base, max_ms: max}, n), do: min(base * Integer.pow(2, n), max)

  @doc """
  The delay before retry `n` (1-based): between half of `max_delay(n - 1)`
  and all of it, so callers throttled together do not retry together.
  """
  @spec jittered(t(), pos_integer()) :: non_neg_integer()
  def jittered(backoff, n) do
    delay = max_delay(backoff, n - 1)
    half = div(delay, 2)
    half + :rand.uniform(delay - half + 1) - 1
  end

  @doc "Whether `delay` ms from now still ends before the attempt's deadline."
  @spec within_deadline?(State.attempt(), non_neg_integer()) :: boolean()
  def within_deadline?(%{deadline: :infinity}, _delay), do: true
  def within_deadline?(%{deadline: deadline}, delay), do: now_ms() + delay < deadline

  @doc "A throttle status (`{:error, {:http, 429 | 502 | 503 | 504}}`)?"
  @spec throttled?(term()) :: boolean()
  def throttled?({:error, {:http, status}}) when status in @throttle_statuses, do: true
  def throttled?(_result), do: false

  @spec unauthorized?(term()) :: boolean()
  def unauthorized?(result), do: http_status(result) == 401

  # The status a request or connect failed with. A connect's is wrapped in
  # `{:connect_failed, _}`, and a handshake's in `{:initialization_failed, _}`
  # inside that.
  defp http_status({:error, {:http, status}}), do: status
  defp http_status({:error, {:connect_failed, {:http, status}}}), do: status

  defp http_status({:error, {:connect_failed, {:initialization_failed, {:http, status}}}}),
    do: status

  defp http_status(_result), do: nil

  @doc """
  A connect failure worth another attempt, as queued callers are answered
  with it; nil for anything else (a 401, a 4xx, a refused or blocked spec).
  From the transport's closed error set: a 5xx or throttle status, a dial,
  read or deadline timeout, a transport or DNS failure, a crashed exchange
  task; and from the inner client, its request timer and the connect budget.
  """
  @spec transient(term()) :: term() | nil
  def transient(result), do: transient(http_status(result), result)

  defp transient(status, _result) when is_integer(status) and status >= 500, do: {:http, status}
  defp transient(status, _result) when status in @throttle_statuses, do: {:http, status}
  defp transient(_status, result), do: transient_reason(connect_reason(result))

  defp transient_reason({:transport, _kind} = reason), do: reason
  defp transient_reason({:timeout, _phase} = reason), do: reason
  defp transient_reason({:task_down, _kind} = reason), do: reason
  defp transient_reason({:not_ready, _status} = reason), do: reason
  defp transient_reason(reason) when reason in [:timeout, :dns_failed], do: reason
  defp transient_reason(_reason), do: nil

  defp connect_reason({:error, {:connect_failed, {:initialization_failed, reason}}}), do: reason
  defp connect_reason({:error, {:connect_failed, reason}}), do: reason
  defp connect_reason({:error, reason}), do: reason
  defp connect_reason(_result), do: nil

  @spec now_ms() :: integer()
  def now_ms, do: System.monotonic_time(:millisecond)
end
