defmodule Raxol.Broker.Executor.ContextTest do
  @moduledoc """
  The context the executor fetches itself, the New York calendar, and the
  drawdown breaker, against the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Executor, Intent, Journal, MarketCalendar, Mode, Strategy}
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp limit(id, qty \\ "2", price \\ "125") do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d(qty), d(price), provenance: :strategy, id: id)
    intent
  end

  describe "MarketCalendar" do
    test "the exchange day starts at New York midnight, EST or EDT" do
      assert MarketCalendar.day_start(~U[2026-03-08 04:59:59Z]) == ~U[2026-03-07 05:00:00Z]
      assert MarketCalendar.day_start(~U[2026-03-08 05:00:00Z]) == ~U[2026-03-08 05:00:00Z]
      assert MarketCalendar.day_start(~U[2026-03-09 03:59:59Z]) == ~U[2026-03-08 05:00:00Z]
      assert MarketCalendar.day_start(~U[2026-03-09 04:00:00Z]) == ~U[2026-03-09 04:00:00Z]
      assert MarketCalendar.day_start(~U[2026-11-01 04:00:00Z]) == ~U[2026-11-01 04:00:00Z]
      assert MarketCalendar.day_start(~U[2026-11-02 04:59:59Z]) == ~U[2026-11-01 04:00:00Z]
      assert MarketCalendar.day_start(~U[2026-11-02 05:00:00Z]) == ~U[2026-11-02 05:00:00Z]
    end

    test "sessions follow New York time" do
      # Friday 2026-10-02, EDT.
      assert MarketCalendar.session(~U[2026-10-02 13:29:59Z]) == :extended
      assert MarketCalendar.session(~U[2026-10-02 13:30:00Z]) == :regular
      assert MarketCalendar.session(~U[2026-10-02 19:59:59Z]) == :regular
      assert MarketCalendar.session(~U[2026-10-02 20:00:00Z]) == :extended
      assert MarketCalendar.session(~U[2026-10-03 00:00:00Z]) == :closed
      assert MarketCalendar.session(~U[2026-10-03 15:00:00Z]) == :closed
      # Monday 2026-12-07, EST.
      assert MarketCalendar.session(~U[2026-12-07 14:30:00Z]) == :regular
      assert MarketCalendar.session(~U[2026-12-07 14:29:00Z]) == :extended
    end
  end

  describe "fetched context" do
    setup do
      ctx = Broker.journal!()
      :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
      {:ok, ctx}
    end

    test "portfolio, positions and quotes come from the session, not the caller", ctx do
      fake =
        Fake.start(
          quotes: %{"AAPL" => "125"},
          positions: [%{"symbol" => "AAPL", "quantity" => "1"}],
          portfolio: %{"equity" => "1000", "adjusted_equity_previous_close" => "1000"}
        )

      policy = Broker.policy("1000", "5000", max_position_weight: d("0.3"))
      executor = Broker.executor!(ctx.journal, fake, policy: policy)

      lying = %Context{
        portfolio_value: d("1000000"),
        start_of_day_value: d("1000000"),
        day_pnl: d("0"),
        positions: %{},
        market_session: :regular
      }

      # Held 125 plus 250 of a 1000 portfolio is 37.5%.
      assert {:deny, gid, {:max_position_weight, %{weight: weight}}} =
               Executor.run(executor, limit("weight"), lying)

      assert Decimal.equal?(weight, d("0.375"))
      [_intent, context | _] = Enum.filter(Broker.records(ctx.path), &(&1["group_id"] == gid))
      assert context["context"]["portfolio_value"] == "1000"
      assert context["context"]["positions"] == %{"AAPL" => "125"}
      assert context["context"]["market_session"] == "regular"
      assert Fake.calls(fake, "place_") == []
    end

    test "an unreadable portfolio denies a rule that needs it", ctx do
      fake = Fake.start(faults: [{"get_portfolio", {:http, 503}, 10}])
      policy = Broker.policy("1000", "5000", max_position_weight: d("0.3"))
      executor = Broker.executor!(ctx.journal, fake, policy: policy)

      assert {:deny, _gid, {:max_position_weight, {:missing_context, :portfolio_value}}} =
               Executor.run(executor, limit("unreadable"), %Context{})
    end

    test "an unreadable positions listing denies a rule that needs it", ctx do
      fake = Fake.start(faults: [{"get_equity_positions", {:http, 503}, 10}])
      policy = Broker.policy("1000", "5000", max_position_weight: d("0.3"))
      executor = Broker.executor!(ctx.journal, fake, policy: policy)

      assert {:deny, _gid, {:max_position_weight, {:missing_context, :positions}}} =
               Executor.run(executor, limit("no-positions"), %Context{})

      assert Fake.calls(fake, "place_") == []
    end
  end

  describe "drawdown breaker" do
    setup do
      ctx = Broker.journal!()
      fake = Fake.start(quotes: %{"F" => "9.80"}, trade_approvals: true)
      policy = Broker.policy("1000", "5000", drawdown_halt: d("0.05"))
      sup = :"strategies_#{System.unique_integer([:positive])}"
      executor = Broker.executor!(ctx.journal, fake, policy: policy, strategies: sup)

      start_supervised!(
        {Strategy.Supervisor, name: sup, journal: ctx.journal, executor: executor, clock: &Broker.t0/0}
      )

      {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
      :ok = Strategy.Supervisor.add(spec, journal: ctx.journal, supervisor: sup)
      :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
      Map.merge(ctx, %{fake: fake, executor: executor, sup: sup})
    end

    # The first sync returns once both quotes are handled; any pause the
    # executor sent meanwhile is then queued, and the second sync handles it.
    defp dip!(sup) do
      [{runner, _}] = Strategy.Supervisor.running(sup)
      send(runner, {:quote, "F", %{last: d("10.00"), bid: nil, ask: nil}})
      send(runner, {:quote, "F", %{last: d("9.50"), bid: nil, ask: nil}})
      :sys.get_state(runner)
      :sys.get_state(runner)
      Strategy.Supervisor.running(sup)
    end

    test "a loss past drawdown_halt pauses every runner and places nothing until arm", ctx do
      Fake.portfolio(ctx.fake, %{"equity" => "940", "adjusted_equity_previous_close" => "1000"})
      _ = dip!(ctx.sup)

      assert Mode.current(ctx.journal) == :disarmed

      assert [{_pid, %{status: :paused, paused: [:drawdown_halt]}}] =
               Strategy.Supervisor.running(ctx.sup)

      assert Fake.calls(ctx.fake, "place_") == []

      halt = Enum.find(Broker.records(ctx.path), &(&1["type"] == "halt"))
      assert halt["reason"] == "drawdown_halt"

      # Paused: further dips emit nothing.
      emits = Enum.count(Broker.records(ctx.path), &(&1["type"] == "emit"))
      _ = dip!(ctx.sup)
      assert Enum.count(Broker.records(ctx.path), &(&1["type"] == "emit")) == emits

      # A fresh arm resumes the runners.
      Fake.portfolio(ctx.fake, %{"equity" => "1000", "adjusted_equity_previous_close" => "1000"})
      client = start_supervised!({Client, Fake.client_opts(ctx.fake)})

      assert {:ok, _} =
               Mode.arm(
                 journal: ctx.journal,
                 client: client,
                 policy_path: Broker.policy_file!(ctx.base),
                 account: "FAKE-0001",
                 confirm: fn _ -> "ARM" end,
                 strategies: ctx.sup
               )

      assert [{_pid, %{status: :running}}] = dip!(ctx.sup)
      assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    end

    test "a loss inside drawdown_halt places", ctx do
      Fake.portfolio(ctx.fake, %{"equity" => "960", "adjusted_equity_previous_close" => "1000"})
      _ = dip!(ctx.sup)
      assert Mode.current(ctx.journal) == :armed
      assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    end

    defp arm!(ctx) do
      client = start_supervised!({Client, Fake.client_opts(ctx.fake)})

      {:ok, _} =
        Mode.arm(
          journal: ctx.journal,
          client: client,
          policy_path: Broker.policy_file!(ctx.base),
          account: "FAKE-0001",
          confirm: fn _ -> "ARM" end,
          strategies: ctx.sup
        )
    end

    test "a runner restarted, or a strategy added, during the pause starts paused", ctx do
      Fake.portfolio(ctx.fake, %{"equity" => "940", "adjusted_equity_previous_close" => "1000"})
      [{runner, %{status: :paused}}] = dip!(ctx.sup)

      ref = Process.monitor(runner)
      Process.exit(runner, :kill)
      assert_receive {:DOWN, ^ref, :process, _, :killed}
      :sys.get_state(:"#{ctx.sup}.Runners")
      [{restarted, _}] = Strategy.Supervisor.running(ctx.sup)
      :sys.get_state(restarted)

      {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => "500"})
      :ok = Strategy.Supervisor.add(spec, journal: ctx.journal, supervisor: ctx.sup)
      Enum.each(Strategy.Supervisor.running(ctx.sup), fn {pid, _} -> :sys.get_state(pid) end)

      assert [
               {_, %{id: "dip_buy-AAPL", status: :paused, paused: [:drawdown_halt]}},
               {^restarted, %{id: "dip_buy-F", status: :paused, paused: [:drawdown_halt]}}
             ] = Strategy.Supervisor.running(ctx.sup)

      assert Journal.pauses(ctx.journal) == {:ok, [:drawdown_halt]}
    end

    test "an intent pending during the pause is sent only after a fresh arm", ctx do
      Fake.portfolio(ctx.fake, %{"equity" => "940", "adjusted_equity_previous_close" => "1000"})
      [{runner, _}] = dip!(ctx.sup)

      {:ok, intent} =
        Intent.limit(:buy, "F", d("1"), d("9.50"), provenance: :strategy, id: "pending-in-pause")

      :ok = Journal.emit(intent, "dip_buy-F", ctx.journal)
      send(runner, :retry)
      :sys.get_state(runner)
      assert Fake.calls(ctx.fake, "place_") == []

      assert {:ok, [%{id: "pending-in-pause"}]} =
               Journal.pending_intents("dip_buy-F", ctx.journal)

      Fake.portfolio(ctx.fake, %{"equity" => "1000", "adjusted_equity_previous_close" => "1000"})
      arm!(ctx)
      :sys.get_state(runner)

      assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
      assert Journal.pauses(ctx.journal) == {:ok, []}
    end
  end
end
