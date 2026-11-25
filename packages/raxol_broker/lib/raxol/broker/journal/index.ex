defmodule Raxol.Broker.Journal.Index do
  @moduledoc false

  # The journal's query table, named after the server. Keys:
  #
  #   :status                        what recovery found
  #   {:order, at_us, group_id}      a counted order's recorded notional
  #   {:fill, at_us, offset}         a fill's realized P&L
  #   {:intent_placing, intent_id}   the group that placed it without failing
  #
  #   {:emit, intent_id}            a pending intent and its strategy
  #   {:strategy, strategy_id}      an active strategy spec
  #
  # Only recorded notionals are read, never recomputed, so the live index
  # and the one rebuilt on start agree.

  alias Raxol.Broker.Journal.Groups

  @minute_us 60_000_000

  @type table :: atom()

  @spec new(atom()) :: table()
  def new(name),
    do: :ets.new(name, [:named_table, :ordered_set, :protected, read_concurrency: true])

  @spec put_status(table(), term()) :: true
  def put_status(table, status), do: :ets.insert(table, {:status, status})

  @spec status(table()) :: {:ok, term()} | :error
  def status(table) do
    case :ets.lookup(table, :status) do
      [{:status, status}] -> {:ok, status}
      [] -> :error
    end
  end

  @doc "Sum of `tag` (`:order` or `:fill`) values at or after `from_us`."
  @spec sum(table(), :order | :fill, integer()) :: Decimal.t()
  def sum(table, tag, from_us) do
    table
    |> :ets.select([{{{tag, :"$1", :_}, :"$2"}, [{:>=, :"$1", from_us}], [:"$2"]}])
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  @doc "Counted orders in the 60 seconds ending at `to_us` (exclusive start)."
  @spec orders_last_minute(table(), integer()) :: non_neg_integer()
  def orders_last_minute(table, to_us) do
    from = to_us - @minute_us
    spec = [{{{:order, :"$1", :_}, :_}, [{:>, :"$1", from}, {:"=<", :"$1", to_us}], [true]}]
    :ets.select_count(table, spec)
  end

  @spec intent_placing(table(), String.t()) :: String.t() | nil
  def intent_placing(table, intent_id) do
    case :ets.lookup(table, {:intent_placing, intent_id}) do
      [{_key, group_id}] -> group_id
      [] -> nil
    end
  end

  @spec pending_intents(table(), String.t()) :: [map()]
  def pending_intents(table, strategy_id) do
    match =
      {{{:emit, :_}, :"$1", :"$2", :"$3"}, [{:==, :"$2", {:const, strategy_id}}],
       [{{:"$1", :"$3"}}]}

    table |> :ets.select([match]) |> ordered_values()
  end

  @spec strategies(table()) :: [map()]
  def strategies(table) do
    table
    |> :ets.select([{{{:strategy, :_}, :"$1", :"$2"}, [], [{{:"$1", :"$2"}}]}])
    |> ordered_values()
  end

  defp ordered_values(entries),
    do: entries |> Enum.sort_by(&elem(&1, 0)) |> Enum.map(&elem(&1, 1))

  # Events are indexed in journal order, so a later record wins. Each entry
  # carries a monotonic sequence number for ordered listings.
  @spec event(table(), map()) :: true
  def event(table, %{"kind" => "broker", "type" => "emit"} = record) do
    case record do
      %{"intent" => %{"id" => id} = intent, "strategy_id" => strategy}
      when is_binary(id) and is_binary(strategy) ->
        :ets.insert(table, {{:emit, id}, seq(), strategy, intent})

      _malformed ->
        true
    end
  end

  def event(table, %{"kind" => "broker", "type" => "dispatch", "intent_id" => id})
      when is_binary(id),
      do: :ets.delete(table, {:emit, id})

  def event(
        table,
        %{"kind" => "broker", "type" => "strategy", "strategy_id" => id} = record
      )
      when is_binary(id) do
    case record do
      %{"action" => "add", "spec" => %{"id" => ^id} = spec} ->
        :ets.insert(table, {{:strategy, id}, seq(), spec})

      %{"action" => "stop"} ->
        :ets.delete(table, {:strategy, id})

      _malformed ->
        true
    end
  end

  def event(_table, _record), do: true

  defp seq, do: System.unique_integer([:monotonic])

  @doc "Count a `placing` record written live for group `id`."
  @spec placed(table(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def placed(table, intent_id, id, placing) do
    :ets.insert(table, {{:intent_placing, intent_id}, id})
    count(table, id, placing)
  end

  @doc "Uncount a group whose order failed, freeing its intent for a retry."
  @spec failed(table(), String.t(), String.t(), map()) :: :ok | {:error, term()}
  def failed(table, intent_id, id, %{"at" => at}) do
    :ets.delete_object(table, {{:intent_placing, intent_id}, id})

    with {:ok, us} <- parse_us(at, {:unindexable_group, id, :at}) do
      :ets.delete(table, {:order, us, id})
      :ok
    end
  end

  @spec put_fill(table(), integer(), term(), Decimal.t()) :: true
  def put_fill(table, at_us, offset, pnl), do: :ets.insert(table, {{:fill, at_us, offset}, pnl})

  @doc "Rebuild the index from the groups and fill records read on start."
  @spec build(table(), [Groups.t()], [map()]) :: :ok | {:error, term()}
  def build(table, groups, fills) do
    with :ok <- each(Enum.filter(groups, &Groups.counts?/1), &count(table, &1.id, &1.placing)),
         :ok <- each(groups, &index_intent(table, &1)),
         do: each(fills, &index_fill(table, &1))
  end

  defp each(items, fun) do
    Enum.reduce_while(items, :ok, fn item, :ok ->
      case fun.(item) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp index_intent(_table, %Groups{placing: nil}), do: :ok
  defp index_intent(_table, %Groups{order: %{"status" => "failed"}}), do: :ok

  defp index_intent(table, %Groups{intent: %{"id" => intent_id}, id: id})
       when is_binary(intent_id) do
    :ets.insert(table, {{:intent_placing, intent_id}, id})
    :ok
  end

  defp index_intent(_table, %Groups{id: id}), do: {:error, {:unindexable_group, id, :intent}}

  defp index_fill(table, record) do
    unindexable = {:unindexable_fill, record["id"]}

    with %{"id" => offset, "at" => at, "fill" => %{"realized_pnl" => pnl}} <- record,
         {:ok, pnl} <- parse_decimal(pnl, unindexable),
         {:ok, us} <- parse_us(at, unindexable) do
      put_fill(table, us, offset, pnl)
      :ok
    else
      {:error, _} = error -> error
      _malformed -> {:error, unindexable}
    end
  end

  # An order counts at its `placing` record's time and recorded notional; a
  # cancel records none and never counts.
  defp count(_table, _id, %{"notional" => nil}), do: :ok

  defp count(table, id, %{"notional" => notional, "at" => at}) do
    with {:ok, notional} <- parse_decimal(notional, {:unindexable_group, id, :notional}),
         {:ok, us} <- parse_us(at, {:unindexable_group, id, :at}) do
      :ets.insert(table, {{:order, us, id}, notional})
      :ok
    end
  end

  defp count(_table, id, _placing), do: {:error, {:unindexable_group, id, :placing}}

  @spec to_us(DateTime.t()) :: integer()
  def to_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp parse_us(at, error) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> {:ok, to_us(datetime)}
      {:error, _} -> {:error, error}
    end
  end

  defp parse_us(_at, error), do: {:error, error}

  defp parse_decimal(value, error) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> {:error, error}
    end
  end

  defp parse_decimal(_value, error), do: {:error, error}
end
