defmodule Raxol.Broker.PolicyHolidayTest do
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Executor, Intent, Journal, MarketCalendar, Policy}
  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp policy(after_hours),
    do:
      Broker.policy("1000", "400",
        after_hours_market: after_hours,
        order_types: [:market, :limit, :stop_limit, :stop_market]
      )

  defp context(after_hours, trading_day, session) do
    %Context{
      policy: policy(after_hours),
      today_notional: d("0"),
      quotes: %{"AAPL" => d("125")},
      trading_day: trading_day,
      market_session: session
    }
  end

  defp limit(id) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d("2"), d("125"), provenance: :strategy, id: id)
    intent
  end

  defp market(id) do
    {:ok, intent} = Intent.buy_usd("AAPL", d("250"), provenance: :strategy, id: id)
    intent
  end

  defp broker!(after_hours, start, fake_opts \\ []) do
    clock =
      start_supervised!(
        Supervisor.child_spec({Agent, fn -> start end}, id: make_ref())
      )

    now = fn -> Agent.get(clock, & &1) end
    ctx = Broker.journal!(clock: now)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    fake = Fake.start(Keyword.merge([quotes: %{"AAPL" => "125"}, trade_approvals: true], fake_opts))
    executor = Broker.executor!(ctx.journal, fake, policy: policy(after_hours), clock: now)
    Map.merge(ctx, %{clock: clock, fake: fake, executor: executor})
  end

  test "a known closed calendar day denies every equity order type regardless of after-hours permission" do
    {:ok, shares} = Intent.buy_shares("AAPL", d("2"), provenance: :strategy)
    {:ok, sell} = Intent.sell("AAPL", d("2"), provenance: :human)
    {:ok, stop_limit} =
      Intent.stop_limit(:sell, "AAPL", d("2"), d("125"), d("124"), provenance: :human)
    {:ok, stop_market} = Intent.stop_market(:sell, "AAPL", d("2"), d("125"), provenance: :human)

    for after_hours <- [false, true],
        session <- [:regular, :extended, :closed],
        intent <- [market("market"), limit("limit"), shares, sell, stop_limit, stop_market] do
      assert Policy.evaluate(intent, context(after_hours, false, session)) ==
               {:deny, {:trading_day, :closed}}
    end
  end

  test "weekday overnight limits and explicitly enabled market orders retain their existing behavior" do
    for after_hours <- [false, true] do
      assert {:allow, _} = Policy.evaluate(limit("overnight"), context(after_hours, true, :closed))
    end

    assert {:allow, _} = Policy.evaluate(market("enabled"), context(true, true, :closed))

    assert {:deny, {:after_hours_market, :closed}} =
             Policy.evaluate(market("disabled"), context(false, true, :closed))
  end

  test "contexts predating trading-day recording retain their original policy result" do
    assert {:allow, _} = Policy.evaluate(limit("legacy-limit"), context(false, nil, :closed))
    assert {:allow, _} = Policy.evaluate(market("legacy-market"), context(true, nil, :closed))

    assert {:deny, {:after_hours_market, {:missing_context, :market_session}}} =
             Policy.evaluate(market("unknown-session"), context(false, nil, nil))
  end

  test "human cancels and declines are still allowed on a closed calendar day" do
    {:ok, cancel} = Intent.cancel("order-1", provenance: :human)
    {:ok, decline} = Intent.decline("approval-1", provenance: :human)
    ctx = %Context{trading_day: false, market_session: :closed}
    assert Policy.evaluate(cancel, ctx) == {:allow, cancel}
    assert Policy.evaluate(decline, ctx) == {:allow, decline}
  end

  test "the trading-day field is normalized, journaled and backward-compatible with older records" do
    for value <- [true, false, nil] do
      ctx = context(false, value, :closed)
      assert {:ok, ^ctx} = Context.normalize(ctx)
      encoded = Codec.encode_context(ctx)
      assert encoded["trading_day"] == value
      assert Codec.decode_context(encoded) == {:ok, ctx}
    end

    legacy = context(true, nil, :closed)
    encoded = legacy |> Codec.encode_context() |> Map.delete("trading_day")
    assert Codec.decode_context(encoded) == {:ok, legacy}
    assert {:allow, _} = Policy.evaluate(market("replayed"), legacy)

    assert Context.normalize(%{legacy | trading_day: :closed}) ==
             {:error, {:invalid, :trading_day}}

    assert Codec.decode_context(Map.put(encoded, "trading_day", "false")) ==
             {:error, {:bad_context, :trading_day}}
  end

  test "executor rejects holiday and weekend limits and markets before review, even with caller-spoofed context" do
    for after_hours <- [false, true] do
      ctx = broker!(after_hours, ~U[2026-07-03 16:00:00Z])
      lying = context(after_hours, true, :regular)

      for now <- [
            ~U[2026-01-01 17:00:00Z],
            ~U[2026-01-19 17:00:00Z],
            ~U[2026-02-16 17:00:00Z],
            ~U[2026-04-03 16:00:00Z],
            ~U[2026-05-25 16:00:00Z],
            ~U[2026-06-19 16:00:00Z],
            ~U[2026-07-03 16:00:00Z],
            ~U[2026-07-04 16:00:00Z],
            ~U[2026-07-05 16:00:00Z],
            ~U[2026-09-07 16:00:00Z],
            ~U[2026-11-26 17:00:00Z],
            ~U[2026-12-25 17:00:00Z],
            ~U[2027-01-01 17:00:00Z],
            ~U[2027-01-18 17:00:00Z],
            ~U[2027-02-15 17:00:00Z],
            ~U[2027-03-26 16:00:00Z],
            ~U[2027-05-31 16:00:00Z],
            ~U[2027-06-18 16:00:00Z],
            ~U[2027-07-05 16:00:00Z],
            ~U[2027-09-06 16:00:00Z],
            ~U[2027-11-25 17:00:00Z],
            ~U[2027-12-24 17:00:00Z]
          ],
          kind <- [:limit, :market] do
        Agent.update(ctx.clock, fn _ -> now end)
        id = "#{now}-#{kind}"
        intent = if kind == :limit, do: limit(id), else: market(id)

        assert {:deny, _gid, {:trading_day, :closed}} = Executor.run(ctx.executor, intent, lying)
      end

      records = Enum.filter(Broker.records(ctx.path), &(&1["type"] == "context"))
      assert length(records) == 44

      for record <- records do
        assert record["context"]["trading_day"] == false
        assert record["context"]["market_session"] == "closed"
      end

      assert Fake.calls(ctx.fake, "review_") == []
      assert Fake.calls(ctx.fake, "place_") == []
      assert Fake.approvals(ctx.fake) == []
      assert Fake.orders(ctx.fake) == []
      assert {:ok, notional} =
               Journal.today_notional(
                 MarketCalendar.day_start(~U[2027-12-24 17:00:00Z]),
                 ctx.journal
               )
      assert Decimal.equal?(notional, d("0"))
    end
  end

  test "holiday midnight cannot queue held proposals and the next trading day still enforces its cap" do
    ctx = broker!(true, ~U[2026-07-03 03:59:59Z])

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(ctx.executor, limit("before-midnight"), %Context{})

    Agent.update(ctx.clock, fn _ -> ~U[2026-07-03 04:00:00Z] end)

    for intent <- [limit("holiday-limit"), market("holiday-market")] do
      assert {:deny, _gid, {:trading_day, :closed}} =
               Executor.run(ctx.executor, intent, %Context{})
    end

    assert length(Fake.approvals(ctx.fake)) == 1
    assert length(Fake.calls(ctx.fake, "place_")) == 1

    Agent.update(ctx.clock, fn _ -> ~U[2026-07-06 14:00:00Z] end)

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(ctx.executor, limit("next-trading-day"), %Context{})

    assert {:deny, _gid, {:daily_notional_cap, _}} =
             Executor.run(ctx.executor, limit("over-next-day-cap"), %Context{})

    assert length(Fake.approvals(ctx.fake)) == 2
    assert length(Fake.calls(ctx.fake, "place_")) == 2
  end

  test "closed-day denial starts at New York midnight in EST and EDT for both after-hours settings" do
    for after_hours <- [false, true],
        {before_holiday, midnight} <- [
          {~U[2026-01-01 04:59:59Z], ~U[2026-01-01 05:00:00Z]},
          {~U[2026-07-03 03:59:59Z], ~U[2026-07-03 04:00:00Z]}
        ] do
      ctx = broker!(after_hours, before_holiday)

      assert {:ok, %{status: :pending_approval}} =
               Executor.run(ctx.executor, limit("previous-local-day"), %Context{})

      Agent.update(ctx.clock, fn _ -> midnight end)

      for intent <- [limit("midnight-limit"), market("midnight-market")] do
        assert {:deny, _gid, {:trading_day, :closed}} =
                 Executor.run(ctx.executor, intent, %Context{})
      end

      assert length(Fake.approvals(ctx.fake)) == 1
      assert length(Fake.calls(ctx.fake, "place_")) == 1
    end
  end

  test "approving an ASK parked on a trading day rechecks the holiday calendar before sending" do
    ctx = broker!(true, ~U[2026-07-03 03:59:59Z], warnings: ["Review required"])
    assert {:ask, gid, _prompts} =
             Executor.run(ctx.executor, limit("parked-before-holiday"), %Context{})

    Agent.update(ctx.clock, fn _ -> ~U[2026-07-03 04:00:00Z] end)

    assert Executor.approve(ctx.executor, gid, "human") == {:deny, gid, {:trading_day, :closed}}
    assert Fake.calls(ctx.fake, "place_") == []
    assert Fake.approvals(ctx.fake) == []
  end

  test "executor can cancel an order and decline a held proposal during a holiday" do
    ctx = broker!(false, ~U[2026-07-02 14:00:00Z])
    assert {:ok, %{status: :pending_approval}} =
             Executor.run(ctx.executor, limit("to-cancel"), %Context{})

    [%{"approval_id" => approval_id}] = Fake.approvals(ctx.fake)
    :ok = Fake.resolve_approval(ctx.fake, approval_id, "approved")
    [%{"order_id" => order_id}] = Fake.orders(ctx.fake)

    {:ok, proposal} = Intent.buy_usd("AAPL", d("100"), provenance: :strategy, id: "to-decline")
    assert {:ok, %{status: :pending_approval}} =
             Executor.run(ctx.executor, proposal, %Context{})

    [_approved, %{"approval_id" => pending_id}] = Fake.approvals(ctx.fake)
    Agent.update(ctx.clock, fn _ -> ~U[2026-07-03 16:00:00Z] end)
    {:ok, cancel} = Intent.cancel(order_id, provenance: :human, id: "holiday-cancel")
    {:ok, decline} = Intent.decline(pending_id, provenance: :human, id: "holiday-decline")

    assert {:ok, %{status: :placed}} = Executor.run(ctx.executor, cancel, %Context{})
    assert {:ok, %{status: :placed}} = Executor.run(ctx.executor, decline, %Context{})
    assert Fake.calls(ctx.fake, "cancel_") == ["cancel_equity_order"]
    assert Fake.calls(ctx.fake, "decline_") == ["decline_trade_approval"]
  end
end
