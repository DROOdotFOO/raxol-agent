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
             "account FAKE-0001: agentic_allowed=true buying_power=1000",
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

  test "live nested buying power appears in the account line", ctx do
    body = %{
      "data" => %{
        "buying_power" => %{
          "buying_power" => "1234.50",
          "display_currency" => "USD",
          "unleveraged_buying_power" => "900.00"
        }
      },
      "guide" => "portfolio guide"
    }

    Fake.on_call(ctx.fake, "get_portfolio", fn _args ->
      {:result, %{"content" => [%{"type" => "text", "text" => Jason.encode!(body)}]}}
    end)

    assert "account FAKE-0001: agentic_allowed=true buying_power=1234.50" in lines(ctx, nil)
    assert {"get_portfolio", %{"account_number" => "FAKE-0001"}} in Fake.calls(ctx.fake)
  end

  test "missing, legacy and malformed buying power is unknown rather than raw text", ctx do
    bodies = [
      %{},
      %{"buying_power" => "1000"},
      %{"buying_power" => %{"amount" => "1000"}},
      %{"buying_power" => nil},
      %{"buying_power" => %{}},
      %{"buying_power" => %{"buying_power" => nil}},
      %{"buying_power" => %{"buying_power" => 1000}},
      %{"buying_power" => %{"buying_power" => ""}},
      %{"buying_power" => %{"buying_power" => "not an amount"}},
      %{"buying_power" => %{"buying_power" => "1000 USD"}},
      %{"buying_power" => %{"buying_power" => "NaN"}},
      %{"buying_power" => %{"buying_power" => "Infinity"}}
    ]

    for body <- bodies do
      :ok = Fake.portfolio(ctx.fake, body)
      assert Snapshot.buying_power(ctx.client, "FAKE-0001") == "?", inspect(body)
      assert "account FAKE-0001: agentic_allowed=true buying_power=?" in lines(ctx, nil)
    end
  end

  test "a zero nested buying power remains a readable amount", ctx do
    :ok = Fake.portfolio(ctx.fake, %{"buying_power" => %{"buying_power" => "0.00"}})
    assert Snapshot.buying_power(ctx.client, "FAKE-0001") == "0.00"
  end

  test "an unreadable portfolio response renders unknown buying power", ctx do
    Fake.on_call(ctx.fake, "get_portfolio", fn _args ->
      {:result, %{"content" => [%{"type" => "text", "text" => "not JSON"}]}}
    end)

    assert "account FAKE-0001: agentic_allowed=true buying_power=?" in lines(ctx, nil)
  end

  test "the mode line follows the journal", ctx do
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    assert "mode: armed" in lines(ctx, nil)
  end

  test "connect reports drift and the account pin", ctx do
    assert {:ok, ["connected: " <> _, "agentic account: FAKE-0001", "no drift from the capture"]} =
             Connect.report(ctx.client)

    assert {:ok, [_, "account FAKE-0001 is the agentic account", _]} =
             Connect.report(ctx.client, "FAKE-0001")

    assert {:error, {:account_pin, {:not_the_agentic_account, "FAKE-0001"}}} =
             Connect.report(ctx.client, "OTHER-1")

    [quotes] = for %{"name" => "get_equity_quotes"} = t <- Fake.tools(), do: t
    changed = put_in(quotes, ["inputSchema", "properties", "extra"], %{"type" => "string"})
    drifted = Fake.start(tools: [changed])
    client = start_supervised!({Client, Fake.client_opts(drifted)}, id: :drifted)

    assert {:ok, [_, _, "changed: get_equity_quotes (read)"]} = Connect.report(client)
  end

  test "the executor's session never becomes ready for an account that is not the agentic one",
       ctx do
    fake = Fake.start(account: "OTHER-1")

    {:ok, executor} =
      Raxol.Broker.Executor.start_link(
        journal: ctx.journal,
        session: Fake.session(fake),
        account_number: "FAKE-0001",
        policy: Broker.policy(),
        reconnect_ms: 60_000
      )

    assert Raxol.Broker.Executor.await_port(executor, 1_000) == {:error, :port_not_ready}
    assert Fake.calls(fake) == [{"get_accounts", %{}}]
    GenServer.stop(executor)
  end
end
