defmodule Raxol.Payments.Xochi.Schemas.DepositRouteRequestTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.DepositRouteRequest

  describe "DepositRouteRequest" do
    @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
    @evm_addr "0x" <> String.duplicate("ab", 20)

    defp deposit_route(overrides \\ %{}) do
      struct(
        %DepositRouteRequest{
          wallet: @tron_wallet,
          from_chain_id: 728_126_428,
          to_chain_id: 8453,
          from_token: @tron_usdt,
          to_token: @evm_addr,
          from_amount: "1000000",
          recipient_address: @evm_addr
        },
        overrides
      )
    end

    test "a Tron origin -> EVM destination request validates" do
      assert :ok = DepositRouteRequest.validate(deposit_route())
    end

    test "to_json serializes the /api/intent/quote wire keys" do
      json = DepositRouteRequest.to_json(deposit_route(%{trust_score: 40}))
      assert json["wallet"] == @tron_wallet
      assert json["from_chain_id"] == 728_126_428
      assert json["to_chain_id"] == 8453
      assert json["from_token"] == @tron_usdt
      assert json["to_token"] == @evm_addr
      assert json["from_amount"] == "1000000"
      assert json["recipient_address"] == @evm_addr
      assert json["settlement_preference"] == "public"
      assert json["trust_score"] == 40
    end

    test "omits trust_score when nil" do
      json = DepositRouteRequest.to_json(deposit_route())
      refute Map.has_key?(json, "trust_score")
    end

    test "rejects an EVM origin (that path signs an intent, it does not deposit)" do
      assert {:error, {:unsupported_origin_vm, _}} =
               DepositRouteRequest.validate(deposit_route(%{from_chain_id: 8453}))
    end

    test "rejects a non-base58 origin wallet" do
      assert {:error, {:invalid_wallet, _}} =
               DepositRouteRequest.validate(deposit_route(%{wallet: @evm_addr}))
    end

    test "rejects a non-base58 origin token" do
      assert {:error, {:invalid_from_token, _}} =
               DepositRouteRequest.validate(deposit_route(%{from_token: @evm_addr}))
    end

    test "rejects a non-EVM destination token" do
      assert {:error, {:invalid_to_token, _}} =
               DepositRouteRequest.validate(deposit_route(%{to_token: @tron_usdt}))
    end

    test "requires an EVM recipient (the Tron wallet cannot receive on EVM)" do
      assert {:error, {:invalid_recipient_address, _}} =
               DepositRouteRequest.validate(deposit_route(%{recipient_address: nil}))

      assert {:error, {:invalid_recipient_address, _}} =
               DepositRouteRequest.validate(deposit_route(%{recipient_address: @tron_wallet}))
    end

    test "rejects a non-positive base-unit amount" do
      assert {:error, {:invalid_from_amount, _}} =
               DepositRouteRequest.validate(deposit_route(%{from_amount: "0"}))

      assert {:error, {:invalid_from_amount, _}} =
               DepositRouteRequest.validate(deposit_route(%{from_amount: "1.5"}))
    end
  end
end
