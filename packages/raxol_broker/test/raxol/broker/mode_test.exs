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
