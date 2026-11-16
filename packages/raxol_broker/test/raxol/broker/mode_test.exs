defmodule Raxol.Broker.ModeTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Journal, Mode, Strategy}
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()
    fake = Fake.start(quotes: %{"F" => "9.80"}, trade_approvals: true)
    client = start_supervised!({Client, Fake.client_opts(fake)})
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "F", "usd" => "25"})
    :ok = Journal.put_strategy(spec, ctx.journal)
    Map.merge(ctx, %{fake: fake, client: client, policy: Broker.policy_file!(ctx.base)})
  end

  defp arm(ctx, answer, extra \\ []) do
    test = self()

    confirm = fn lines ->
      send(test, {:summary, lines})
      answer
    end

    [
      journal: ctx.journal,
      client: ctx.client,
      policy_path: ctx.policy,
      account: "FAKE-0001",
      confirm: confirm
    ]
    |> Keyword.merge(extra)
    |> Mode.arm()
  end

  test "a fresh journal is disarmed" do
    ctx = Broker.journal!()
    assert Mode.current(ctx.journal) == :disarmed
  end

  test "typing ARM after the checks writes an armed record", ctx do
    assert {:ok, fields} = arm(ctx, "ARM")
    assert fields["human_must_approve_trades"] == true
    assert fields["quotes"] == %{"F" => "9.80"}
    assert Mode.current(ctx.journal) == :armed

    assert_received {:summary, lines}
    assert "  F last 9.80" in lines
    assert "trade approvals in the Robinhood app: on (human_must_approve_trades: true)" in lines
    assert {:ok, :armed, %{"human_must_approve_trades" => true}} = Journal.mode(ctx.journal)
    assert List.last(lines) =~ "Type ARM"
  end

  test "approvals off refuses before confirmation and writes nothing", ctx do
    fake = Fake.start(trade_approvals: false)
    client = start_supervised!({Client, Fake.client_opts(fake)}, id: :approvals_off)
    before = Broker.records(ctx.path)

    assert arm(ctx, "ARM", client: client) == {:error, {:approvals_off, "FAKE-0001"}}
    refute_received {:summary, _}
    assert Broker.records(ctx.path) == before
    assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
  end

  test "a live data.setting approval flag is recorded and shown in confirmation", ctx do
    body = %{
      "data" => %{
        "setting" => %{
          "account_number" => "FAKE-0001",
          "human_must_approve_trades" => true
        }
      },
      "guide" => "approval guide"
    }

    Fake.on_call(ctx.fake, "get_trade_approval_setting", fn _args ->
      {:result, %{"content" => [%{"type" => "text", "text" => Jason.encode!(body)}]}}
    end)

    assert {:ok, fields} = arm(ctx, "ARM")
    assert fields["human_must_approve_trades"] == true
    assert {:ok, :armed, %{"human_must_approve_trades" => true}} = Journal.mode(ctx.journal)
    assert_received {:summary, summary}
    assert "trade approvals in the Robinhood app: on (human_must_approve_trades: true)" in summary
  end

  test "live approvals off refuses with no confirmation, journal write or later tool call", ctx do
    body = %{"data" => %{"setting" => %{"human_must_approve_trades" => false}}}

    Fake.on_call(ctx.fake, "get_trade_approval_setting", fn _args ->
      {:result, %{"content" => [%{"type" => "text", "text" => Jason.encode!(body)}]}}
    end)

    before = Broker.records(ctx.path)
    assert arm(ctx, "ARM") == {:error, {:approvals_off, "FAKE-0001"}}
    refute_received {:summary, _}
    assert Broker.records(ctx.path) == before
    assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}

    assert Fake.calls(ctx.fake) == [
             {"get_accounts", %{}},
             {"get_trade_approval_setting", %{"account_number" => "FAKE-0001"}}
           ]
  end

  test "missing, legacy and nonboolean approval flags refuse without writing", ctx do
    before = Broker.records(ctx.path)

    bodies = [
      %{},
      %{"human_must_approve_trades" => true},
      %{"setting" => nil},
      %{"setting" => []},
      %{"setting" => %{}},
      %{"setting" => %{"human_must_approve_trades" => nil}},
      %{"setting" => %{"human_must_approve_trades" => "true"}},
      %{"setting" => %{"human_must_approve_trades" => "false"}},
      %{"setting" => %{"human_must_approve_trades" => 1}}
    ]

    for body <- bodies do
      Fake.on_call(ctx.fake, "get_trade_approval_setting", fn _args ->
        {:result,
         %{"content" => [%{"type" => "text", "text" => Jason.encode!(%{"data" => body})}]}}
      end)

      assert arm(ctx, "ARM") == {:error, {:approval_setting, :unreadable}}, inspect(body)
      refute_received {:summary, _}
      assert Broker.records(ctx.path) == before
      assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
    end

    assert Enum.all?(Fake.calls(ctx.fake), fn {tool, _args} ->
             tool in ["get_accounts", "get_trade_approval_setting"]
           end)
  end

  test "an unreadable approval response refuses without confirmation or journal writes", ctx do
    before = Broker.records(ctx.path)

    for result <- [
          %{"content" => [%{"type" => "text", "text" => "not JSON"}]},
          %{"content" => [], "isError" => false},
          %{"content" => [], "isError" => true}
        ] do
      Fake.on_call(ctx.fake, "get_trade_approval_setting", fn _args -> {:result, result} end)
      assert {:error, {:approval_setting, _reason}} = arm(ctx, "ARM")
      refute_received {:summary, _}
      assert Broker.records(ctx.path) == before
      assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
    end
  end

  test "contradictory or absent nested quotes cannot arm", ctx do
    before = Broker.records(ctx.path)

    for row <- [
          %{"symbol" => "F", "last_trade_price" => "9.80"},
          %{"symbol" => "F", "quote" => %{"last_trade_price" => "9.80"}},
          %{"symbol" => "OTHER", "quote" => %{"symbol" => "F", "last_trade_price" => "9.80"}}
        ] do
      Fake.on_call(ctx.fake, "get_equity_quotes", fn _args ->
        {:result,
         %{
           "content" => [
             %{"type" => "text", "text" => Jason.encode!(%{"data" => %{"results" => [row]}})}
           ]
         }}
      end)

      assert arm(ctx, "ARM") == {:error, {:no_quote, "F"}}
      refute_received {:summary, _}
      assert Broker.records(ctx.path) == before
      assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
    end
  end

  test "a halt requested inside confirmation refuses without arming", ctx do
    confirm = fn _ ->
      :ok = Raxol.Broker.HaltRequest.request(ctx.path)
      "ARM"
    end

    assert arm(ctx, "ARM", confirm: confirm) == {:error, :halt_requested}
    assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
  end

  test "a completed kill while confirmation waits invalidates that arm", ctx do
    assert {:ok, _} = arm(ctx, "ARM")

    confirm = fn _ ->
      :ok = Raxol.Broker.HaltRequest.request(ctx.path)
      :ok = Mode.disarm("kill", journal: ctx.journal)
      File.rm!(Raxol.Broker.HaltRequest.path(ctx.path))
      "ARM"
    end

    assert arm(ctx, "ARM", confirm: confirm) == {:error, :mode_changed}
    assert {:ok, :disarmed, %{"reason" => "kill"}} = Journal.mode(ctx.journal)
    assert Mode.current(ctx.journal) == :disarmed
  end

  test "anything but ARM writes nothing", ctx do
    assert arm(ctx, "arm") == {:error, :not_confirmed}
    assert arm(ctx, nil) == {:error, :not_confirmed}
    assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
  end

  test "a one-byte journal edit blocks arming", ctx do
    Broker.flip_byte!(ctx.path)

    assert {:error, {:journal, {:broken, _offset}}} = arm(ctx, "ARM")
    refute_received {:summary, _}
    assert Mode.current(ctx.journal) == :disarmed
  end

  test "a strategy symbol quoting above max_notional_per_order refuses", ctx do
    policy = Broker.policy_file!(ctx.base, "5")

    assert {:error, {:quote_above_cap, "F", price, cap}} = arm(ctx, "ARM", policy_path: policy)
    assert Decimal.equal?(price, Decimal.new("9.80")) and Decimal.equal?(cap, 5)
    assert Mode.current(ctx.journal) == :disarmed
  end

  test "a symbol with no quote refuses", ctx do
    {:ok, spec} = Strategy.spec("dip_buy", %{"symbol" => "ZZZ", "usd" => "25"})
    :ok = Journal.put_strategy(spec, ctx.journal)
    assert arm(ctx, "ARM") == {:error, {:no_quote, "ZZZ"}}
  end

  test "a missing policy file or a client that is not connected refuses", ctx do
    missing = Path.join(ctx.base, "nope.exs")
    assert {:error, {:policy, {:missing_file, ^missing}}} = arm(ctx, "ARM", policy_path: missing)

    down = Fake.start(faults: [{:any, :closed, 99}])
    opts = Fake.client_opts(down, backoff: [retries: 0, base_ms: 0])
    stopped = start_supervised!({Client, opts}, id: :down)
    assert {:error, {:not_connected, _}} = arm(ctx, "ARM", client: stopped)
  end

  test "disarm is unconditional", ctx do
    assert {:ok, _fields} = arm(ctx, "ARM")
    assert :ok = Mode.disarm("operator", journal: ctx.journal)
    assert Mode.current(ctx.journal) == :disarmed
    assert :ok = Mode.disarm("again", journal: ctx.journal)
  end
end
