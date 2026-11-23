defmodule Raxol.Web3.Cache do
  @moduledoc """
  The response cache: four functions, lazy expiry, one owned bounded table.

  ADR-0033 decision 6. `get`, `put`, `delete`, `flush`; TTL in milliseconds, `0`
  meaning no expiry, expiry checked lazily on read. The table is owned by
  `Raxol.Web3.Tables` and lives as long as the node. Expiry uses monotonic time,
  so a wall-clock step cannot extend TTLs.

  ## Keys never come from a URL

  `Raxol.Web3.HTTP` keys an entry `{origin_id, fragment}`. A backend's fragment
  is `{scope, endpoint_key}` (`Raxol.Web3.Backend.Cache.opts/5`): the scope is
  `Raxol.Web3.Scope.of/2` of base URL and headers, the endpoint key is built from
  the endpoint name and its declared parameters. The request URI is never an
  input, because some upstreams carry the API key in the query string.

  ## Bounds

    * `config :raxol_web3, :cache_max_entries` (default `512`). A `put/3` past the
      cap reclaims expired rows, then evicts live rows (soonest expiry first,
      `:no_expiry` last) down to seven eighths of the cap.
    * `config :raxol_web3, :cache_max_value_bytes` (default `262_144`). A larger
      value is not stored; `put/3` still returns `:ok` and the next `get/1`
      misses.

  Together that bounds the table at 128 MiB by default. Both checks run before
  the insert, so the table may briefly hold cap + 1 rows.

  ## What to cache

  A finalized transaction can be cached long; chain statistics for seconds. A
  **height is never cached**: a cached height beside a live one breaks the
  monotonicity `Raxol.Web3.Backend`'s height shape expresses. `Raxol.Web3.TTL`
  holds the per-endpoint values.
  """

  alias Raxol.Web3.Tables

  @default_max_entries 512
  @default_max_value_bytes 262_144

  @type key :: term()
  @type value :: term()
  @type ttl_ms :: non_neg_integer()

  @doc """
  Fetch a fresh entry.

  A stale entry is deleted in the same call and reported as a miss, so a key
  that is read keeps its own memory in check. An expired entry that is never
  read again is reclaimed by the next `put/3` that needs the room, or by
  `flush/0`.
  """
  @spec get(key()) :: {:ok, value()} | :miss
  def get(key) do
    case :ets.lookup(Tables.cache(), key) do
      [{^key, value, :no_expiry}] -> {:ok, value}
      [{^key, value, expires_at}] -> fresh_or_expire(key, value, expires_at)
      [] -> :miss
    end
  end

  @doc """
  Store a value for `ttl_ms` milliseconds.

  `0` means no expiry. A negative TTL raises rather than being clamped: it is
  a caller's arithmetic mistake, and silently treating it as "expired already"
  or "never" would hide the bug behind a cache that merely looks cold.

  A value over `:cache_max_value_bytes` is not stored, and storing may evict
  other entries to stay under `:cache_max_entries`; the moduledoc has both.
  Either way the answer is `:ok`, because "the cache declined to hold this" is
  not a caller's error to handle.
  """
  @spec put(key(), value(), ttl_ms()) :: :ok
  def put(key, value, 0), do: insert(key, value, :no_expiry)

  def put(key, value, ttl_ms) when is_integer(ttl_ms) and ttl_ms > 0 do
    insert(key, value, now_ms() + ttl_ms)
  end

  def put(_key, _value, ttl_ms) do
    raise ArgumentError, "ttl_ms must be a non-negative integer, got: #{inspect(ttl_ms)}"
  end

  @doc "Forget one key."
  @spec delete(key()) :: :ok
  def delete(key) do
    :ets.delete(Tables.cache(), key)
    :ok
  end

  @doc "Forget everything."
  @spec flush() :: :ok
  def flush do
    :ets.delete_all_objects(Tables.cache())
    :ok
  end

  defp insert(key, value, expires_at) do
    if :erlang.external_size(value) > max_value_bytes() do
      :ok
    else
      insert_bounded(key, value, expires_at)
    end
  end

  # The `:ets.member/2` check is what keeps a hot key cheap: overwriting a row
  # that is already there does not grow the table, so refreshing one entry at
  # the cap must not cost an eighth of the cache.
  defp insert_bounded(key, value, expires_at) do
    table = Tables.cache()

    if :ets.info(table, :size) >= max_entries() and not :ets.member(table, key) do
      make_room(table)
    end

    :ets.insert(table, {key, value, expires_at})
    :ok
  end

  # One `:ets.select/2` over keys and expiries: the values, which are the large
  # half of a row, are never copied out to decide what to drop. Expired rows go
  # first because they are free, then live rows by soonest expiry. `:no_expiry`
  # sorts after every integer in Erlang term order, so the rows a caller asked
  # to keep forever are the last to go.
  defp make_room(table) do
    now = now_ms()

    {expired, live} =
      table
      |> :ets.select([{{:"$1", :_, :"$2"}, [], [{{:"$1", :"$2"}}]}])
      |> Enum.split_with(fn {_key, expires_at} -> expired?(expires_at, now) end)

    Enum.each(expired, &delete_row(table, &1))

    surplus = length(live) - low_water()

    if surplus > 0 do
      live
      |> Enum.sort_by(&elem(&1, 1))
      |> Enum.take(surplus)
      |> Enum.each(&delete_row(table, &1))
    end

    :ok
  end

  defp delete_row(table, {key, _expires_at}), do: :ets.delete(table, key)

  defp expired?(:no_expiry, _now), do: false
  defp expired?(expires_at, now), do: now >= expires_at

  defp low_water do
    cap = max_entries()
    cap - max(1, div(cap, 8))
  end

  defp max_entries do
    Application.get_env(:raxol_web3, :cache_max_entries, @default_max_entries)
  end

  defp max_value_bytes do
    Application.get_env(:raxol_web3, :cache_max_value_bytes, @default_max_value_bytes)
  end

  defp fresh_or_expire(key, value, expires_at) do
    if now_ms() < expires_at do
      {:ok, value}
    else
      delete(key)
      :miss
    end
  end

  defp now_ms, do: System.monotonic_time(:millisecond)
end
