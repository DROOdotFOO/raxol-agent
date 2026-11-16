defmodule Raxol.Payments.Ramp.PeerPlansTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.Ramp.Peer.{ABI, Plans, Wallet}
  @fixture Path.expand("../../../fixtures/ramp/peer_maker_calldata.json", __DIR__)
  @vectors @fixture |> File.read!() |> Jason.decode!()
  for {vector, index} <- Enum.with_index(@vectors["cases"]) do
    @vector vector
    test "matches TS maker adapter calldata vector #{index}" do
      v = @vector

      plan =
        case v["action"] do
          "approve_usdc" ->
            Plans.approval(String.to_integer(v["amount"]))

          "create_deposit" ->
            Plans.deposit(String.to_integer(v["amount"]), v["rail"], v["payee_hash"], %{
              minimum: String.to_integer(v["terms"]["minimum"]),
              maximum: String.to_integer(v["terms"]["maximum"]),
              rate: String.to_integer(v["terms"]["conversionRate"])
            })

          action ->
            Plans.withdrawal(
              String.to_integer(v["deposit_id"]),
              String.to_integer(v["amount"]),
              action == "withdraw_deposit"
            )
        end

      assert plan.data == v["transaction"]["data"]
      assert plan.to == v["transaction"]["to"]
      assert plan.chain_id == v["transaction"]["chain_id"]
      assert to_string(plan.value) == v["transaction"]["value"]
    end
  end

  test "unsigned EIP-1559 payload matches viem serialization and signing digest" do
    plan = Plans.approval(2_000_000)

    raw =
      <<2>> <>
        Wallet.rlp([8453, 0, 1, 3, 100_000, ABI.unhex(plan.to), 0, ABI.unhex(plan.data), []])

    assert ABI.hex(raw) == @vectors["unsigned_transaction"]["serialized"]
    assert ABI.hash(raw) == @vectors["unsigned_transaction"]["digest"]
  end

  test "unsigned allowance cannot encode negative, zero, floating or overflowing money" do
    for value <- [-1, 0, 1.5, Integer.pow(2, 256)] do
      assert_raise FunctionClauseError, fn -> Plans.approval(value) end
    end
  end

  test "RLP handles empty access list and long calldata" do
    assert ABI.hex(Wallet.rlp([0, 1, <<128>>, []])) == "0xc580018180c0"
    assert byte_size(Wallet.rlp(:binary.copy(<<1>>, 56))) == 58
  end
end
