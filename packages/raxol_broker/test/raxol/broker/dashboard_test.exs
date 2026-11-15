defmodule Raxol.Broker.DashboardTest do
  @moduledoc """
  The dashboard run headless (`Raxol.Headless`, ticks sent by hand) against
  a real executor and journal on the Fake, and the executor's own ASK
  timeout with no dashboard at all.
  """
  use ExUnit.Case, async: false

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @snapshot Path.expand("../../fixtures/dashboard/two_asks.txt", __DIR__)

  setup_all do
    unless Process.whereis(Raxol.Headless), do: start_supervised!(Raxol.Headless)
    :ok
  end

  setup do
    ctx = Broker.journal!()
    :ok = Journal.put_mode(:armed, %{"by" => "test"}, ctx.journal)
    fake = Fake.start(warnings: ["Order exceeds 5% of buying power"])
    executor = Broker.executor!(ctx.journal, fake)

    Application.put_env(:raxol_broker, Raxol.Broker.Dashboard,
      executor: executor,
      journal: ctx.journal,
      strategies: :no_strategies_here,
      client: :no_client_here
    )

    on_exit(fn -> Application.delete_env(:raxol_broker, Raxol.Broker.Dashboard) end)
    Map.merge(ctx, %{fake: fake, executor: executor})
  end

  defp dashboard! do
    id = "dash#{System.unique_integer([:positive])}"

    {:ok, ^id} =
      Raxol.Headless.start(Raxol.Broker.Dashboard,
        id: id,
        subscriptions: false,
        width: 100,
        height: 30
      )

    on_exit(fn -> Raxol.Headless.stop(id) end)
    id
  end

  defp ask!(ctx, id, qty \\ "2") do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new(qty), Decimal.new("125"),
        provenance: :strategy,
        id: id
      )

    context = %Context{quotes: %{"AAPL" => Decimal.new("125")}}
    assert {:ask, group_id, _prompts} = Executor.run(ctx.executor, intent, context)
    group_id
  end

  defp screen(id) do
    {:ok, text} = Raxol.Headless.screenshot(id)

    text
    |> String.split("\n")
    |> Enum.map(&String.trim_trailing/1)
    |> Enum.join("\n")
    |> String.trim()
  end

  test "an ASK shows within one frame of parking; a approves it into exactly one place", ctx do
    dash = dashboard!()
    assert screen(dash) =~ "pending approvals (a approve, d deny, j/k move):\n  none"

    group_id = ask!(ctx, "ask-approve")
    :ok = Raxol.Headless.send_message(dash, :tick)
    assert screen(dash) =~ "> ask-approve  limit buy AAPL 2 @ 125  denied in 5m"
    assert screen(dash) =~ "review_warning: Order review returned 1 warning(s)."

    :ok = Raxol.Headless.send_key(dash, "a")
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]
    assert screen(dash) =~ "approve ask-approve: placed"

    approval = Enum.find(Broker.records(ctx.path), &(&1["type"] == "approval"))

    assert %{"group_id" => ^group_id, "decision" => "approved", "by" => "dashboard:headless"} =
             approval
  end

  test "d declines the focused ASK and nothing is placed", ctx do
    dash = dashboard!()
    _ = ask!(ctx, "ask-decline")
    :ok = Raxol.Headless.send_message(dash, :tick)

    :ok = Raxol.Headless.send_key(dash, "d")
    assert Fake.calls(ctx.fake, "place_") == []
    assert Executor.parked(ctx.executor) == []
    assert screen(dash) =~ "decline ask-decline: declined"
  end

  test "renders two pending ASKs", ctx do
    dash = dashboard!()
    _ = ask!(ctx, "ask-one")
    _ = ask!(ctx, "ask-two", "3")
    :ok = Raxol.Headless.send_message(dash, :tick)
    :ok = Raxol.Headless.send_key(dash, "j")

    assert screen(dash) == String.trim(File.read!(@snapshot))
  end

  test "with no dashboard, an unanswered ASK is denied by the executor as :ask_timeout", ctx do
    ctx = Map.merge(ctx, Broker.journal!())
    policy = Broker.policy("1000", "5000", ask_timeout: 1)
    :ok = Journal.put_mode(:armed, %{"by" => "test"}, ctx.journal)
    executor = Broker.executor!(ctx.journal, ctx.fake, policy: policy)
    :erlang.trace(executor, true, [:receive])

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("1"), Decimal.new("125"),
        provenance: :strategy,
        id: "ask-timeout"
      )

    assert {:ask, group_id, _} =
             Executor.run(executor, intent, %Context{quotes: %{"AAPL" => Decimal.new("125")}})

    assert_receive {:trace, ^executor, :receive, {:ask_timeout, ^group_id}}, 5_000
    assert Executor.parked(executor) == []

    last =
      ctx.path |> Broker.records() |> Enum.filter(&(&1["group_id"] == group_id)) |> List.last()

    assert %{"type" => "verdict", "result" => %{"action" => "deny", "rule" => "ask_timeout"}} =
             last

    assert {:ok, [%{"outcome" => "deny ask_timeout"} | _]} = Journal.recent(ctx.journal)
    assert Fake.calls(ctx.fake, "place_") == []
  end
end
