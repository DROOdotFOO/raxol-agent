defmodule Raxol.Broker.Strategy.RunnerTest do
  @moduledoc """
  Runners against a real journal and an executor on the Fake.
  """
  use ExUnit.Case, async: true

  import Raxol.Broker.Test.Broker, only: [d: 1]

  alias Raxol.Broker.{Journal, Strategy}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()
    fake = Fake.start(quotes: %{"F" => "9.80"})
    executor = Broker.executor!(ctx.journal, fake)
    sup_name = :"strategies_#{System.unique_integer([:positive])}"

    start_supervised!(
      {Strategy.Supervisor, name: sup_name, journal: ctx.journal, executor: executor}
    )

    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    opts = [journal: ctx.journal, supervisor: sup_name]
    :ok = Strategy.Supervisor.add(spec, opts)
    [{runner, _info}] = Strategy.Supervisor.running(sup_name)

    Map.merge(ctx, %{fake: fake, executor: executor, sup: sup_name, opts: opts, runner: runner})
  end

  defp quote!(runner, price),
    do: send(runner, {:quote, "F", %{last: d(price), bid: nil, ask: nil}})

  test "an emitted intent is journaled before the executor opens its group", ctx do
    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    _ = Strategy.Supervisor.running(ctx.sup)

    records = Broker.records(ctx.path)
    emit = Enum.find_index(records, &(&1["type"] == "emit"))
    opened = Enum.find_index(records, &(&1["type"] == "intent"))
    dispatch = Enum.find(records, &(&1["type"] == "dispatch"))

    assert emit < opened
    assert Enum.at(records, emit)["intent"]["id"] == Enum.at(records, opened)["intent"]["id"]
    assert dispatch["outcome"] == "placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    assert Journal.pending_intents("dip_buy-F", ctx.journal) == {:ok, []}
  end

  test "a runner killed after emitting and before the executor answers places exactly once",
       ctx do
    test = self()

    Fake.on_call(ctx.fake, "review_equity_order", fn _args ->
      send(test, {:reviewing, self()})
      receive do: (:go -> :answer)
    end)

    quote!(ctx.runner, "10.00")
    quote!(ctx.runner, "9.80")
    assert_receive {:reviewing, review}, 5_000
    assert {:ok, [intent]} = Journal.pending_intents("dip_buy-F", ctx.journal)

    ref = Process.monitor(ctx.runner)
    Process.exit(ctx.runner, :kill)
    assert_receive {:DOWN, ^ref, :process, _, :killed}

    send(review, :go)
    [{restarted, _info}] = Strategy.Supervisor.running(ctx.sup)
    assert restarted != ctx.runner

    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    assert Journal.pending_intents("dip_buy-F", ctx.journal) == {:ok, []}

    dispatches = for %{"type" => "dispatch"} = r <- Broker.records(ctx.path), do: r
    assert [%{"intent_id" => id, "outcome" => "duplicate"}] = dispatches
    assert id == intent.id
  end

  test "stop ends the runner and restore does not bring it back", ctx do
    assert :ok = Strategy.Supervisor.stop("dip_buy-F", ctx.opts)
    assert Strategy.Supervisor.running(ctx.sup) == []
    assert :ok = Strategy.Supervisor.restore(ctx.opts)
    assert Strategy.Supervisor.running(ctx.sup) == []
    assert {:ok, []} = Strategy.Supervisor.list(ctx.opts)
  end

  test "restore starts every added strategy that is not running", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "AAPL", "usd" => "500"})
    :ok = Journal.put_strategy(spec, ctx.journal)
    assert length(Strategy.Supervisor.running(ctx.sup)) == 1

    assert :ok = Strategy.Supervisor.restore(ctx.opts)
    assert {:ok, list} = Strategy.Supervisor.list(ctx.opts)

    assert Enum.map(list, &{&1.id, &1.status}) == [
             {"dip_buy-F", :running},
             {"dip_buy-AAPL", :running}
           ]
  end

  test "an id already added is refused", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "5"})
    assert {:error, {:already_added, "dip_buy-F"}} = Strategy.Supervisor.add(spec, ctx.opts)
  end
end
