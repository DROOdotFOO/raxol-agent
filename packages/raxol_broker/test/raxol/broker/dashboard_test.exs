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
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
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

  defp key(char), do: %Raxol.Core.Events.Event{type: :key, data: %{key: :char, char: char}}

  # The TEA app as the SSH surface starts it for an authenticated user.
  defp operator_model(operator \\ "ssh:alice") do
    Raxol.Broker.Dashboard.init(%{
      options: [environment: :ssh, dashboard: [operator: operator]]
    })
  end

  defp press(model, keys) do
    Enum.reduce(keys, model, fn k, model ->
      {model, _commands} = Raxol.Broker.Dashboard.update(key(k), model)
      model
    end)
  end

  defp tick(model), do: model |> then(&Raxol.Broker.Dashboard.update(:tick, &1)) |> elem(0)

  test "headless shows an ASK within one frame, read-only: a sends nothing", ctx do
    dash = dashboard!()
    assert screen(dash) =~ "pending approvals (a approve, d deny, j/k move), read-only:\n  none"

    _ = ask!(ctx, "ask-approve")
    :ok = Raxol.Headless.send_message(dash, :tick)
    assert screen(dash) =~ "  ask-approve  limit buy AAPL 2 @ 125  denied in 5m"
    assert screen(dash) =~ "review_warning: Order review returned 1 warning(s)."

    :ok = Raxol.Headless.send_key(dash, "j")
    :ok = Raxol.Headless.send_key(dash, "a")
    assert screen(dash) =~ "read-only: this surface has no operator; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []
    assert [_] = Executor.parked(ctx.executor)
  end

  test "an operator approves the focused ASK into exactly one place, journaled by name", ctx do
    group_id = ask!(ctx, "ask-approve")
    model = operator_model() |> tick() |> press(["a"])
    assert model.status == "pick an approval with j/k first; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []

    model = press(model, ["j", "a"])
    assert model.status == "approve ask-approve: placed"
    assert Fake.calls(ctx.fake, "place_") == ["place_equity_order"]

    approval = Enum.find(Broker.records(ctx.path), &(&1["type"] == "approval"))

    assert %{"group_id" => ^group_id, "decision" => "approved", "by" => "ssh:alice"} =
             approval
  end

  test "an operator's d declines the focused ASK and nothing is placed", ctx do
    _ = ask!(ctx, "ask-decline")
    model = operator_model() |> tick() |> press(["j", "d"])

    assert model.status == "decline ask-decline: declined"
    assert Fake.calls(ctx.fake, "place_") == []
    assert Executor.parked(ctx.executor) == []
  end

  test "a focused ASK answered elsewhere is not replaced by the next one", ctx do
    first = ask!(ctx, "ask-first")
    _ = ask!(ctx, "ask-second", "3")
    model = operator_model() |> tick() |> press(["j"])
    assert model.focus == first

    :ok = Executor.decline(ctx.executor, first, "elsewhere")
    model = model |> tick() |> press(["a"])

    assert model.focus == nil
    assert model.status == "pick an approval with j/k first; nothing sent"
    assert Fake.calls(ctx.fake, "place_") == []
    assert [%{intent: %{id: "ask-second"}}] = Executor.parked(ctx.executor)
  end

  test "K kills only for an operator and only after y", ctx do
    _ = ask!(ctx, "ask-kill")

    assert operator_model(nil) |> press(["K", "y"]) |> Map.fetch!(:status) =~ "read-only"
    assert Raxol.Broker.Mode.current(ctx.journal) == :armed

    model = operator_model() |> press(["K", "x"])
    assert model.status == "kill cancelled; nothing sent"
    assert Raxol.Broker.Mode.current(ctx.journal) == :armed

    model = press(model, ["K", "y"])
    assert model.status =~ "killed:"
    assert Raxol.Broker.Mode.current(ctx.journal) == :disarmed

    halt = ctx.path |> Broker.records() |> Enum.filter(&(&1["type"] == "halt")) |> List.last()
    assert %{"reason" => "kill", "trigger" => "ssh:alice"} = halt
  end

  test "an SSH surface with no operator, and LiveView, are read-only" do
    assert operator_model(nil).operator == nil

    assert Raxol.Broker.Dashboard.init(%{options: [environment: :liveview]}).operator == nil
    assert "terminal:" <> _ = Raxol.Broker.Dashboard.init(%{options: []}).operator
  end

  test "renders two pending ASKs", ctx do
    dash = dashboard!()
    _ = ask!(ctx, "ask-one")
    _ = ask!(ctx, "ask-two", "3")
    :ok = Raxol.Headless.send_message(dash, :tick)
    :ok = Raxol.Headless.send_key(dash, "j")
    :ok = Raxol.Headless.send_key(dash, "j")

    assert screen(dash) == String.trim(File.read!(@snapshot))
  end

  test "with no dashboard, an unanswered ASK is denied by the executor as :ask_timeout", ctx do
    ctx = Map.merge(ctx, Broker.journal!())
    policy = Broker.policy("1000", "5000", ask_timeout: 1)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
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
