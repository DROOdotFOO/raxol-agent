defmodule Raxol.Broker.JournalIndexTest do
  @moduledoc """
  The journal's query index: notional and order-rate counters, counted from
  `placing` (see `Raxol.Broker.Test.JournalCase`).
  """
  use Raxol.Broker.Test.JournalCase, async: true

  alias Raxol.Broker.{Intent, Journal, Policy}
  alias Raxol.Broker.Test.JournalCase

  @t0 JournalCase.t0()
  @day JournalCase.day()

  test "strategy events have the same ordered results live and after journal restart",
       %{opts: opts, name: name} do
    start!(opts)
    first = limit("1")
    dispatched = limit("2")
    last = limit("3")
    other = limit("4")
    active = %{"id" => "z-active"}
    stopped = %{"id" => "stopped"}
    another = %{"id" => "a-active"}

    :ok = Journal.put_strategy(active, name)
    :ok = Journal.put_strategy(stopped, name)
    :ok = Journal.put_strategy(another, name)
    :ok = Journal.emit(first, active["id"], name)
    :ok = Journal.emit(dispatched, active["id"], name)
    :ok = Journal.emit(last, active["id"], name)
    :ok = Journal.emit(other, another["id"], name)
    :ok = Journal.dispatched(dispatched.id, "placed", name)
    :ok = Journal.drop_strategy(stopped["id"], name)

    assert Journal.strategies(name) == {:ok, [active, another]}
    assert Journal.pending_intents(active["id"], name) == {:ok, [first, last]}
    assert Journal.pending_intents(another["id"], name) == {:ok, [other]}

    stop_supervised!(name)
    start!(opts)

    assert Journal.status(name) == :ok
    assert Journal.strategies(name) == {:ok, [active, another]}
    assert Journal.pending_intents(active["id"], name) == {:ok, [first, last]}
    assert Journal.pending_intents(another["id"], name) == {:ok, [other]}
  end

  test "event writes cannot add broker group records", %{opts: opts, name: name, path: path} do
    start!(opts)

    assert {:error, :invalid_event} =
             GenServer.call(name, {:event, "fill", ~s({"fill":{"realized_pnl":"1000"}})})

    assert {:error, :invalid_event_fields} =
             GenServer.call(name, {:event, "strategy", "[]"})

    assert :ok =
             Journal.append_event(
               :strategy,
               %{
                 "action" => "add",
                 "strategy_id" => "broken",
                 "spec" => "not a strategy spec",
                 "group_id" => "fake",
                 "type" => "placing"
               },
               name
             )

    assert Journal.strategies(name) == {:ok, []}

    stop_supervised!(name)
    start!(opts)

    assert Journal.strategies(name) == {:ok, []}
    assert [%{"type" => "strategy"} = event] = records(path)
    refute Map.has_key?(event, "group_id")
  end

  describe "index" do
    test "only placed orders count; denials, failed orders and cancels never do",
         %{opts: opts, clock: clock} do
      start!(opts)
      name = opts[:name]
      ctx = context()

      at(clock, @t0)

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      big = limit("100")

      {:ok, _} =
        Journal.append_group(
          %{
            intent: big,
            context: ctx,
            entries: [{:verdict, :pre_review, Policy.evaluate(big, ctx)}]
          },
          name
        )

      failed = limit("3")

      entries =
        List.replace_at(
          placed_entries(failed, ctx),
          -1,
          {:order, :failed, %{"error" => "rejected"}}
        )

      {:ok, _} = Journal.append_group(%{intent: failed, context: ctx, entries: entries}, name)

      {:ok, cancel} = Intent.cancel("o-1", provenance: :human)

      {:ok, _} =
        Journal.append_group(
          %{intent: cancel, context: ctx, entries: placed_entries(cancel, ctx)},
          name
        )

      at(clock, DateTime.add(@t0, 30, :second))
      second = limit("1", "100")

      {:ok, _} =
        Journal.append_group(
          %{intent: second, context: ctx, entries: placed_entries(second, ctx)},
          name
        )

      assert Journal.today_notional(@day, name) == {:ok, d("350")}
      # `since` is inclusive.
      assert Journal.today_notional(@t0, name) == {:ok, d("350")}
      assert Journal.today_notional(DateTime.add(@t0, 1, :second), name) == {:ok, d("100")}

      # The minute window excludes its start and includes `now`.
      assert Journal.orders_last_minute(DateTime.add(@t0, 59, :second), name) == {:ok, 2}
      assert Journal.orders_last_minute(DateTime.add(@t0, 60, :second), name) == {:ok, 1}
      assert Journal.orders_last_minute(DateTime.add(@t0, 90, :second), name) == {:ok, 0}
    end

    test "the index is rebuilt from disk on start", %{opts: opts, clock: clock} do
      name = opts[:name]
      start!(opts)
      ctx = context()

      {:ok, _} =
        Journal.append_group(
          %{intent: limit("2"), context: ctx, entries: placed_entries(limit("2"), ctx)},
          name
        )

      fill = %{
        order_id: "o-1",
        symbol: "AAPL",
        side: :sell,
        qty: d("2"),
        price: d("130"),
        realized_pnl: d("-12.50")
      }

      assert :ok = Journal.append_fill(fill, name)
      at(clock, DateTime.add(@t0, 5, :second))
      assert :ok = Journal.append_fill(%{fill | realized_pnl: d("30")}, name)
      assert {:error, {:invalid_fill, _}} = Journal.append_fill(%{fill | realized_pnl: 1.5}, name)

      stop_supervised!(name)
      start!(opts)

      assert Journal.status(name) == :ok
      assert Journal.today_notional(@day, name) == {:ok, d("250")}
      assert Journal.realized_pnl_today(@day, name) == {:ok, d("17.50")}
      assert Journal.realized_pnl_today(DateTime.add(@t0, 1, :second), name) == {:ok, d("30")}
    end
  end

  describe "counting from placing" do
    test "an in-flight order counts live and after a restart alike", %{opts: opts, clock: clock} do
      name = opts[:name]
      start!(opts)
      placed_at = DateTime.add(@t0, 5, :second)
      at(clock, placed_at)
      in_flight!(name, limit("4"), context())

      live = counters(name, placed_at)
      assert live == {{:ok, d("500")}, {:ok, 1}}
      assert Journal.orders_last_minute(DateTime.add(placed_at, 60, :second), name) == {:ok, 0}

      stop_supervised!(name)
      start!(opts)

      assert Journal.status(name) == :ok
      assert counters(name, placed_at) == live
      assert Journal.pending_intents("strategy", name) == {:ok, []}
      assert Journal.strategies(name) == {:ok, []}
    end

    test "a failed order stops counting, live and after a restart", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}

      :ok = Journal.append_to_group(id, {:order, :failed, %{"error" => "rejected"}}, name)
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}

      stop_supervised!(name)
      start!(opts)

      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
      assert %{"type" => "order", "status" => "failed"} = List.last(records(path))
    end

    test "an unknown order response keeps counting", %{opts: opts} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      :ok = Journal.append_to_group(id, {:order, :unknown, %{"error" => "timeout"}}, name)
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}

      stop_supervised!(name)
      start!(opts)
      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
    end

    test "a pending approval keeps counting and keeps its intent, live and after a restart",
         %{opts: opts} do
      name = opts[:name]
      start!(opts)
      intent = limit("4")
      id = in_flight!(name, intent, context())
      response = %{"approval_id" => "apr-1"}
      :ok = Journal.append_to_group(id, {:order, :pending_approval, response}, name)

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      assert Journal.placing_for_intent(intent.id, name) == {:ok, id}

      stop_supervised!(name)
      start!(opts)

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      assert Journal.placing_for_intent(intent.id, name) == {:ok, id}
    end

    test "a close after placing is an unknown outcome and keeps counting",
         %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      id = in_flight!(name, limit("4"), context())
      :ok = Journal.append_to_group(id, {:close, :abandoned}, name)

      assert %{"type" => "close", "reason" => "abandoned", "outcome" => "unknown"} =
               List.last(records(path))

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      written = length(records(path))

      stop_supervised!(name)
      start!(opts)

      assert counters(name, @t0) == {{:ok, d("500")}, {:ok, 1}}
      assert length(records(path)) == written
    end

    test "a close before placing is a DENY", %{opts: opts, path: path} do
      name = opts[:name]
      start!(opts)
      {:ok, id} = Journal.open_group(limit("4"), context(), name)
      :ok = Journal.append_to_group(id, {:close, :abandoned}, name)

      assert %{"type" => "close", "outcome" => "deny"} = List.last(records(path))
      assert counters(name, @t0) == {{:ok, d("0")}, {:ok, 0}}
    end
  end
end
