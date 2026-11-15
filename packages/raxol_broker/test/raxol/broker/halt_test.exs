defmodule Raxol.Broker.HaltTest do
  @moduledoc """
  The kill switch and the dead-man switch against a real executor, journal
  and strategy supervisor on the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Executor, Halt, Heartbeat, Intent, Journal, Mode, Strategy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  defp broker!(fake_opts \\ []) do
    ctx = Broker.journal!()
    fake = Fake.start(Keyword.merge([quotes: %{"F" => "9.80", "AAPL" => "125"}], fake_opts))
    sup = :"strategies_#{System.unique_integer([:positive])}"
    executor = Broker.executor!(ctx.journal, fake, strategies: sup)
    start_supervised!({Strategy.Supervisor, name: sup, journal: ctx.journal, executor: executor})
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    :ok = Strategy.Supervisor.add(spec, journal: ctx.journal, supervisor: sup)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    Map.merge(ctx, %{fake: fake, executor: executor, sup: sup})
  end

  defp place!(ctx, id) do
    {:ok, intent} = Intent.limit(:buy, "AAPL", d("1"), d("125"), provenance: :human, id: id)
    {:ok, %{status: status}} = Executor.run(ctx.executor, intent, %Context{})
    status
  end

  defp kill!(ctx, bound \\ 5_000) do
    {:ok, summary} =
      Halt.kill(
        journal: ctx.journal,
        executor: ctx.executor,
        strategies: ctx.sup,
        bound: bound,
        trigger: "test"
      )

    summary
  end

  defp types(path), do: path |> Broker.records() |> Enum.map(& &1["type"])

  describe "kill/1" do
    test "three open orders: three cancels, no running strategy, disarmed, in journal order" do
      ctx = broker!()
      for id <- ~w(k1 k2 k3), do: :placed = place!(ctx, id)
      before = length(Broker.records(ctx.path))

      summary = kill!(ctx)

      assert Fake.calls(ctx.fake, "cancel_") == List.duplicate("cancel_equity_order", 3)
      assert Enum.all?(Fake.orders(ctx.fake), &(&1["state"] == "cancelled"))
      assert Strategy.Supervisor.running(ctx.sup) == []
      assert Mode.current(ctx.journal) == :disarmed
      assert {:ok, [_, _, _]} = summary.orders
      assert Enum.map(summary.results, & &1.outcome) == ~w(placed placed placed)

      after_kill = ctx.path |> types() |> Enum.drop(before)
      assert hd(after_kill) == "mode"
      assert List.last(after_kill) == "halt"
      assert Enum.count(after_kill, &(&1 == "order")) == 3

      halt = ctx.path |> Broker.records() |> List.last()
      assert %{"reason" => "kill", "trigger" => "test", "results" => [_, _, _]} = halt
    end

    test "a cancel that hangs: kill returns within the bound, two cancelled, one timeout" do
      ctx = broker!()
      for id <- ~w(t1 t2 t3), do: :placed = place!(ctx, id)
      [_, %{"order_id" => stuck}, _] = Fake.orders(ctx.fake)

      Fake.on_call(ctx.fake, "cancel_equity_order", fn args ->
        if args["order_id"] == stuck, do: :hang, else: :answer
      end)

      {micros, summary} = :timer.tc(fn -> kill!(ctx, 300) end)
      assert micros < 3_000_000

      outcomes = Map.new(summary.results, &{&1.id, &1.outcome})
      assert outcomes[stuck] == "unknown :timeout"
      assert outcomes |> Map.delete(stuck) |> Map.values() == ["placed", "placed"]

      orders = for %{"type" => "order"} = r <- Broker.records(ctx.path), do: r
      assert Enum.count(orders, &(&1["response"]["error"] == ":timeout")) == 1
    end

    test "pending trade approvals are declined through the executor" do
      ctx = broker!(trade_approvals: true)
      :pending_approval = place!(ctx, "proposal")

      summary = kill!(ctx)

      assert Fake.calls(ctx.fake, "decline_") == ["decline_trade_approval"]
      assert [%{"state" => "declined"}] = Fake.approvals(ctx.fake)
      assert [%{kind: :decline, outcome: "placed"}] = summary.results

      [intent] =
        for %{"type" => "intent", "intent" => %{"kind" => "decline"} = i} <-
              Broker.records(ctx.path),
            do: i

      assert intent["id"] == "decline-" <> intent["order_id"]
    end
  end

  describe "dead-man switch" do
    setup do
      ctx = broker!()
      {clock, time} = Broker.clock(0)

      heartbeat =
        start_supervised!(
          {Heartbeat,
           name: :"heartbeat_#{System.unique_integer([:positive])}",
           timeout: 1_000,
           journal: ctx.journal,
           strategies: ctx.sup,
           clock: clock,
           schedule: fn _ms -> :ok end}
        )

      Map.merge(ctx, %{heartbeat: heartbeat, time: time})
    end

    defp check!(heartbeat) do
      send(heartbeat, :check)
      Heartbeat.status(heartbeat)
    end

    defp runner_status(sup),
      do: sup |> Strategy.Supervisor.running() |> Enum.map(&elem(&1, 1).status)

    test "silence past the timeout pauses strategies; a beat resumes them; both journaled", ctx do
      Agent.update(ctx.time, &(&1 + 999))
      assert %{paused: false} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:running]

      Agent.update(ctx.time, &(&1 + 1))
      assert %{paused: true} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:paused]
      assert Mode.current(ctx.journal) == :armed

      :ok = Heartbeat.beat(ctx.heartbeat, "test")
      assert runner_status(ctx.sup) == [:running]

      halts = for %{"type" => "halt"} = r <- Broker.records(ctx.path), do: r["reason"]
      assert halts == ["dead_man_pause", "dead_man_resume"]
    end

    test "a beat inside the timeout keeps strategies running", ctx do
      Agent.update(ctx.time, &(&1 + 900))
      :ok = Heartbeat.beat(ctx.heartbeat, "test")
      Agent.update(ctx.time, &(&1 + 900))
      assert %{paused: false} = check!(ctx.heartbeat)
      assert runner_status(ctx.sup) == [:running]
    end
  end
end
