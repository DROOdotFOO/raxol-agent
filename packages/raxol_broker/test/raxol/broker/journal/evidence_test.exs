defmodule Raxol.Broker.Journal.EvidenceTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.{Executor, Intent, Journal}
  alias Raxol.Broker.Journal.Evidence
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @date ~D[2026-10-02]
  @at "2026-10-02T14:30:00.000000Z"

  setup do
    base = Path.join(System.tmp_dir!(), "broker-evidence-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    {:ok, path: Path.join(base, "journal")}
  end

  test "actual ASK, proposal, reconciliation and fill records retain redacted correlations" do
    ctx = Broker.journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    fake = Fake.start(trade_approvals: true, warnings: ["private review warning"])
    executor = Broker.executor!(ctx.journal, fake)

    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Broker.d("2"), Broker.d("125"),
        provenance: :strategy,
        id: "private-intent"
      )

    assert {:ask, group_id, _prompts} = Executor.run(executor, intent, %Context{})

    assert {:ok, %{status: :pending_approval}} =
             Executor.approve(executor, group_id, "private-actor")

    [approval] = Fake.approvals(fake)
    approval_id = approval["approval_id"]
    Fake.resolve_approval(fake, approval_id, "approved")
    assert {:ok, [%{resolution: "approved"}]} = Executor.reconcile(executor)
    [order] = Fake.orders(fake)

    :ok =
      Journal.append_fill(
        %{
          order_id: order["order_id"],
          symbol: "AAPL",
          side: :buy,
          qty: Broker.d("2"),
          price: Broker.d("125"),
          realized_pnl: Broker.d("0")
        },
        ctx.journal
      )

    assert {:ok, report} = Evidence.run(ctx.path, @date)
    assert [group] = report["groups"]
    assert [fill] = report["fills"]
    proposal = Enum.find(group["events"], &(&1["stage"] == "order"))
    resolution = Enum.find(group["events"], &(&1["stage"] == "resolve"))
    review = Enum.find(group["events"], &(&1["stage"] == "review"))

    assert review["customer_approval_required"] == true
    assert proposal["outcome"] == "pending_approval"
    assert proposal["identifiers"]["approval_id"] == resolution["identifiers"]["approval_id"]
    assert resolution["identifiers"]["order_id"] == fill["order_id"]
    assert fill["group_ids"] == [group["group_id"]]
    assert group["final_recorded_outcome"] == "approved"
    assert group["final_recorded_state"] == "approved"
    assert Enum.all?(group["stages"], fn {_stage, status} -> status == "RECORDED" end)
    assert Enum.any?(group["events"], &(&1["action"] == "ask"))
    assert report["live_transport"] == "UNVERIFIED"
    assert report["cursor_traversal"] == "UNVERIFIED"
    assert report["current_broker_state"] == "UNVERIFIED"
    assert resolution["cursor_traversal"] == "UNVERIFIED"

    json = Jason.encode!(report)

    for private <- [
          "private-intent",
          "private-actor",
          "private review warning",
          "FAKE-0001",
          "AAPL",
          group_id,
          approval_id,
          order["order_id"],
          approval["args"]["ref_id"]
        ] do
      refute json =~ private
    end
  end

  test "nested data, raw JSON, params and free text never escape the allowlist", %{path: path} do
    secrets =
      ~w(private-account private-order private-approval private-ref private-token private-note private-strategy)

    response =
      response(%{
        "order_id" => "private-order",
        "approval_id" => "private-approval",
        "state" => "filled",
        "args" => %{"account_number" => "private-account", "ref_id" => "private-ref"},
        "raw" => %{"access_token" => "private-token", "nested" => ["private-note"]},
        "guide" => "private-note"
      })

    write_records(path, [
      rec("private-group", "intent", %{
        "intent" => %{
          "id" => "private-intent",
          "kind" => "limit",
          "side" => "buy",
          "symbol" => "private-token",
          "strategy" => "private-strategy",
          "qty" => "private-note",
          "params" => %{"token" => "private-token", "raw" => response}
        }
      }),
      rec("private-group", "review", %{"response" => response}),
      rec("private-group", "order", %{"status" => "placed", "response" => response}),
      rec("private-group", "resolve", %{
        "resolution" => "approved",
        "detail" => %{
          "approval_id" => "private-approval",
          "order_id" => "private-order",
          "state" => "unrecognized-private-state",
          "raw" => response
        }
      }),
      rec(nil, "fill", %{
        "fill" => %{"order_id" => "private-order", "symbol" => "private-token", "side" => "buy"}
      })
    ])

    assert {:ok, report} = Evidence.run(path, @date)
    assert [group] = report["groups"]
    assert [fill] = report["fills"]
    [intent, review, order, resolution] = group["events"]
    assert intent["symbol_id"] == fill["symbol_id"]
    assert review["identifiers"] == order["identifiers"]
    assert order["identifiers"]["order_id"] == fill["order_id"]
    assert order["identifiers"]["approval_id"] == resolution["identifiers"]["approval_id"]
    assert group["final_recorded_state"] == "UNVERIFIED"
    assert group["stages"]["placing"] == "UNVERIFIED"
    json = Jason.encode!(report)

    for secret <- secrets ++ ~w(private-group private-intent unrecognized-private-state) do
      refute json =~ secret
    end

    assert {:ok, ^report} = Evidence.run(path, @date)
  end

  test "missing stages, unknown outcomes and unmatched fills stay unverified", %{path: path} do
    write_records(path, [
      rec("unfinished", "intent", %{"intent" => %{"id" => "one", "kind" => "limit"}}),
      rec("unfinished", "placing", %{"notional" => "250"}),
      rec("unknown", "order", %{"status" => "vendor-private-status", "response" => %{}}),
      rec(nil, "fill", %{"fill" => %{"order_id" => "unlinked"}})
    ])

    assert {:ok, report} = Evidence.run(path, @date)
    assert [unfinished, unknown] = report["groups"]
    assert unfinished["final_recorded_outcome"] == "UNVERIFIED"
    assert unfinished["final_recorded_state"] == "UNVERIFIED"
    assert unfinished["stages"]["review"] == "UNVERIFIED"
    assert unfinished["stages"]["order"] == "UNVERIFIED"
    assert unknown["final_recorded_outcome"] == "UNVERIFIED"
    assert unknown["stages"]["intent"] == "UNVERIFIED"
    assert [%{"linkage" => "UNVERIFIED", "group_ids" => []}] = report["fills"]
    assert report["result"] == "UNVERIFIED"
  end

  test "empty verified history is not a passing live checkpoint", %{path: path} do
    write_records(path, [])
    assert {:ok, report} = Evidence.run(path, @date)
    assert report["groups"] == []
    assert report["fills"] == []
    assert report["journal_integrity"] == "VERIFIED"
    assert report["result"] == "UNVERIFIED"
  end

  test "day selection keeps an earlier intent linked to a later reconciliation and fill", %{
    path: path
  } do
    old = "2026-10-01T14:30:00Z"

    write_records(path, [
      rec("earlier", "intent", %{"at" => old, "intent" => %{"id" => "one"}}),
      rec("earlier", "order", %{
        "at" => old,
        "status" => "unknown",
        "response" => response(%{"order_id" => "linked"})
      }),
      rec("earlier", "resolve", %{
        "at" => old,
        "resolution" => "placed",
        "detail" => %{"order_id" => "linked", "state" => "confirmed"}
      }),
      rec(nil, "fill", %{"fill" => %{"order_id" => "linked"}}),
      rec("other-day", "intent", %{"at" => old, "intent" => %{"id" => "other"}})
    ])

    assert {:ok, report} = Evidence.run(path, @date)
    assert [group] = report["groups"]
    assert [%{"group_ids" => [group_id]}] = report["fills"]
    assert group["group_id"] == group_id
    assert group["final_recorded_state"] == "confirmed"
    assert hd(group["events"])["at"] == old
  end

  test "refuses corruption rather than exporting partial evidence", %{path: path} do
    write_records(path, [rec("group", "intent", %{"intent" => %{"id" => "private"}})])
    Broker.flip_byte!(path)
    assert {:error, {:broken, _offset}} = Evidence.run(path, @date)
  end

  test "refuses missing, unchained and unreadable journal layouts", %{path: path} do
    assert Evidence.run(path, @date) == {:error, :no_journal}
    {:ok, handle} = FileStore.open("journal", base_dir: Path.dirname(path))
    :ok = FileStore.close(handle)
    assert Evidence.run(path, @date) == {:error, :unreadable_journal}
    File.rm_rf!(path)
    write_records(path, [])
    File.rm!(Path.join(path, "HEAD"))
    assert Evidence.run(path, @date) == {:error, :unreadable_journal}
  end

  defp rec(group, type, fields),
    do: Map.merge(%{"kind" => "broker", "group_id" => group, "at" => @at, "type" => type}, fields)

  defp response(body),
    do: %{
      "content" => [
        %{"type" => "text", "text" => Jason.encode!(%{"data" => body, "guide" => "private-note"})}
      ]
    }

  defp write_records(path, records) do
    {:ok, handle} = FileStore.open("journal", base_dir: Path.dirname(path), chain: true)
    if records != [], do: assert(match?({:ok, _}, FileStore.append_many(handle, records)))
    :ok = FileStore.close(handle)
  end
end
