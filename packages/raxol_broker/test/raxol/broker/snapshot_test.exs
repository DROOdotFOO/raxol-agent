defmodule Raxol.Broker.SnapshotTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Connect, Journal, Snapshot}
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()

    fake =
      Fake.start(
        quotes: %{"F" => "9.80"},
        positions: [%{"symbol" => "F", "quantity" => "3"}]
      )

    client = start_supervised!({Client, Fake.client_opts(fake)})
    Map.merge(ctx, %{fake: fake, client: client})
  end

  defp lines(ctx, sample) do
    Snapshot.lines(
      client: ctx.client,
      journal: ctx.journal,
      policy: Broker.policy(),
      sample: sample,
      now: Broker.t0()
    )
  end

  test "prints accounts, positions, mode, journal and a sample verdict with no review or order",
       ctx do
    assert lines(ctx, "buy F 2 @ 9.80") == [
             "account FAKE-0001: agentic_allowed=true",
             "positions FAKE-0001: F 3",
             "mode: disarmed",
             "journal: ok",
             "sample buy F 2 @ 9.80: ALLOW (no order placed)"
           ]

    assert ["sample buy F 100usd: DENY order_type :market" <> _] =
             Enum.take(lines(ctx, "buy F 100usd"), -1)

    calls = Enum.map(Fake.calls(ctx.fake), &elem(&1, 0))
    assert calls != []
    refute Enum.any?(calls, &String.match?(&1, ~r/\A(place|cancel|review|preview|decline)_/))
  end

  test "the mode line follows the journal", ctx do
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    assert "mode: armed" in lines(ctx, nil)
  end

  test "connect reports no drift against the capture, and names a changed tool", ctx do
    assert {:ok, ["connected: " <> _, "no drift from the capture"]} = Connect.report(ctx.client)

    [quotes] = for %{"name" => "get_equity_quotes"} = t <- Fake.tools(), do: t
    changed = put_in(quotes, ["inputSchema", "properties", "extra"], %{"type" => "string"})
    drifted = Fake.start(tools: [changed])
    client = start_supervised!({Client, Fake.client_opts(drifted)}, id: :drifted)

    assert {:ok, [_, "changed: get_equity_quotes (read)"]} = Connect.report(client)
  end
end
