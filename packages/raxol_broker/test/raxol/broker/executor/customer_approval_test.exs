defmodule Raxol.Broker.Executor.CustomerApprovalTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.MCP.Fake

  import Raxol.Broker.Test.Broker

  @moduletag :capture_log

  test "a strict executor refuses false or missing approval-required after ASK is approved" do
    for flag <- [false, :missing] do
      %{executor: executor, fake: fake, journal: journal, path: path} = strict_executor(flag)
      intent = intent(:llm)

      assert {:ask, group, _prompts} =
               Executor.run(executor, intent, %Raxol.Broker.Policy.Context{})

      assert {:error, :customer_approval_unconfirmed} =
               Executor.approve(executor, group, "terminal:operator")

      assert Fake.calls(fake, "place_") == []
      assert Journal.open_groups(journal) == {:ok, []}
      assert Journal.today_notional(t0(), journal) == {:ok, d("0")}
      group_records = Enum.filter(records(path), &(&1["group_id"] == group))
      refute Enum.any?(group_records, &(&1["type"] == "placing"))
      assert %{"type" => "close", "reason" => "customer_approval_unconfirmed"} =
               List.last(group_records)
    end
  end

  test "a strict executor refuses ALLOW when the review does not require customer approval" do
    %{executor: executor, fake: fake, journal: journal} = strict_executor(false)

    assert {:error, :customer_approval_unconfirmed} =
             Executor.run(executor, intent(:strategy), %Raxol.Broker.Policy.Context{})

    assert Fake.calls(fake, "place_") == []
    assert Journal.open_groups(journal) == {:ok, []}
  end

  test "a strict executor submits one proposal with a true flag through ALLOW or approved ASK" do
    for provenance <- [:strategy, :llm] do
      %{executor: executor, fake: fake} = strict_executor(true)
      intent = intent(provenance)
      result = Executor.run(executor, intent, %Raxol.Broker.Policy.Context{})

      result =
        case result do
          {:ask, group, _prompts} -> Executor.approve(executor, group, "terminal:operator")
          other -> other
        end

      assert {:ok, %{status: :pending_approval, journaled: true}} = result
      assert Fake.calls(fake, "place_") == ["place_equity_order"]
      assert Fake.orders(fake) == []
      assert [%{"state" => "pending"}] = Fake.approvals(fake)
      assert Executor.run(executor, intent, %Raxol.Broker.Policy.Context{}) == {:ok, :duplicate}
      assert Fake.calls(fake, "place_") == ["place_equity_order"]
    end
  end

  test "strict approval does not block the emergency kill path" do
    %{executor: executor, fake: fake, journal: journal} = strict_executor(true)

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(executor, intent(:strategy), %Raxol.Broker.Policy.Context{})

    assert [%{"approval_id" => id}] = Fake.approvals(fake)

    assert {:ok, %{approvals: {:ok, [^id]}, results: [%{kind: :decline}]}} =
             Executor.halt_orders(executor, 5_000)

    assert [%{"state" => "declined"}] = Fake.approvals(fake)

    :ok = Journal.record_armed(%{"by" => "test"}, journal)

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(executor, intent(:strategy), %Raxol.Broker.Policy.Context{})

    pending = Enum.find(Fake.approvals(fake), &(&1["state"] == "pending"))
    :ok = Fake.resolve_approval(fake, pending["approval_id"], "approved")
    assert [%{"order_id" => order_id}] = Fake.orders(fake)

    assert {:ok, %{orders: {:ok, [^order_id]}, results: [%{kind: :cancel}]}} =
             Executor.halt_orders(executor, 5_000)

    assert [%{"state" => "cancelled"}] = Fake.orders(fake)
  end

  test "strict approval permits targeted operator decline and cancellation" do
    %{executor: executor, fake: fake} = strict_executor(true)
    context = %Raxol.Broker.Policy.Context{}

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(executor, intent(:strategy), context)

    assert [%{"approval_id" => id}] = Fake.approvals(fake)
    {:ok, decline} = Intent.decline(id, provenance: :human)
    assert {:ok, %{status: :placed}} = Executor.run(executor, decline, context)
    assert [%{"state" => "declined"}] = Fake.approvals(fake)
    assert Fake.calls(fake, "decline_") == ["decline_trade_approval"]

    assert {:ok, %{status: :pending_approval}} =
             Executor.run(executor, intent(:strategy), context)

    pending = Enum.find(Fake.approvals(fake), &(&1["state"] == "pending"))
    :ok = Fake.resolve_approval(fake, pending["approval_id"], "approved")
    assert [%{"order_id" => order_id}] = Fake.orders(fake)
    {:ok, cancel} = Intent.cancel(order_id, provenance: :human)
    assert {:ok, %{status: :placed}} = Executor.run(executor, cancel, context)
    assert [%{"state" => "cancelled"}] = Fake.orders(fake)
    assert Fake.calls(fake, "cancel_") == ["cancel_equity_order"]
  end

  test "an invalid strict-approval value refuses startup rather than disabling the guard" do
    Process.flag(:trap_exit, true)
    fake = Fake.start()
    ctx = journal!()

    assert {:error, {:invalid_customer_approval_requirement, "true"}} =
             Executor.start_link(
               journal: ctx.journal,
               session: Fake.session(fake),
               account_number: "FAKE-0001",
               policy: policy(),
               require_customer_approval: "true"
             )

    assert Fake.calls(fake) == []
  end

  defp strict_executor(flag) do
    fake = Fake.start(trade_approvals: true, quotes: %{"F" => "12"})

    if flag != true do
      body =
        if flag == :missing,
          do: %{"alerts" => []},
          else: %{"alerts" => [], "customer_approval_required" => flag}

      Fake.on_call(fake, "review_equity_order", fn _args ->
        {:result,
         %{"isError" => false, "content" => [%{"type" => "text", "text" => Jason.encode!(body)}]}}
      end)
    end

    ctx = journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    executor = executor!(ctx.journal, fake, require_customer_approval: true)
    Map.merge(ctx, %{executor: executor, fake: fake})
  end

  defp intent(provenance) do
    {:ok, intent} =
      Intent.limit(:buy, "F", d("1"), d("12"),
        provenance: provenance,
        id: "strict-#{System.unique_integer([:positive])}"
      )

    intent
  end
end
