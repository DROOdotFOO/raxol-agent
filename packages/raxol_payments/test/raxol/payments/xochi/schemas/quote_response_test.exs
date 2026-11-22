defmodule Raxol.Payments.Xochi.Schemas.QuoteResponseTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

  describe "QuoteResponse.from_json/1" do
    test "parses JSON response" do
      json = %{
        "intentId" => "intent_123",
        "quoteId" => "quote_456",
        "canSolve" => true,
        "toAmount" => "995000",
        "minToAmount" => "990000",
        "xochiFee" => "3000",
        "xochiFeeRate" => "0.30",
        "estimatedGasCost" => "0.50",
        "expiry" => "2026-04-06T12:30:30Z",
        "gasless" => false,
        "settlementOptions" => [%{"type" => "public", "available" => true}],
        "eip712Data" => %{"domain" => %{}}
      }

      resp = QuoteResponse.from_json(json)

      assert resp.intent_id == "intent_123"
      assert resp.quote_id == "quote_456"
      assert resp.can_solve == true
      assert resp.to_amount == "995000"
      assert resp.xochi_fee == "3000"
      assert resp.eip712_data == %{"domain" => %{}}
      assert length(resp.settlement_options) == 1
    end

    test "defaults can_solve to false" do
      json = %{"intentId" => "i", "quoteId" => "q"}
      resp = QuoteResponse.from_json(json)
      assert resp.can_solve == false
    end

    test "parses the live snake_case shape with eip712 and payment_method" do
      json = %{
        "intent_id" => "xi_1",
        "quote_id" => "xq_1",
        "can_solve" => true,
        "to_amount" => "24925000",
        "min_to_amount" => "24800375",
        "payment_method" => "erc3009",
        "fee" => %{"fee_amount" => "75000", "total_bps" => 30},
        "eip712" => %{"domain" => %{"name" => "Xochi"}, "types" => %{}, "message" => %{}},
        "settlement_options" => ["public"]
      }

      resp = QuoteResponse.from_json(json)

      assert resp.intent_id == "xi_1"
      assert resp.quote_id == "xq_1"
      assert resp.can_solve == true
      assert resp.to_amount == "24925000"
      assert resp.payment_method == "erc3009"

      assert resp.eip712_data == %{
               "domain" => %{"name" => "Xochi"},
               "types" => %{},
               "message" => %{}
             }

      assert resp.xochi_fee == "75000"
      assert resp.settlement_options == ["public"]
    end

    test "an unfillable snake_case quote carries reason as error" do
      json = %{
        "intent_id" => "i",
        "quote_id" => "q",
        "can_solve" => false,
        "reason" => "no liquidity"
      }

      resp = QuoteResponse.from_json(json)
      assert resp.can_solve == false
      assert resp.error == "no liquidity"
    end

    test "parses deposit-route fields (snake_case and camelCase) (#400)" do
      for {addr, att, deadline} <- [
            {"deposit_address", "deposit_attestation", "deposit_deadline"},
            {"depositAddress", "depositAttestation", "depositDeadline"}
          ] do
        json = %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "can_solve" => true,
          addr => "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX",
          att => "0x" <> String.duplicate("ab", 65),
          deadline => 1_900_000_000
        }

        resp = QuoteResponse.from_json(json)
        assert resp.deposit_address == "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"
        assert resp.deposit_attestation == "0x" <> String.duplicate("ab", 65)
        assert resp.deposit_deadline == 1_900_000_000
        assert QuoteResponse.deposit_route?(resp)
      end
    end

    test "deposit_route? is false for an EVM pull quote (no deposit_address)" do
      resp = QuoteResponse.from_json(%{"intent_id" => "i", "quote_id" => "q", "eip712" => %{}})
      assert resp.deposit_address == nil
      refute QuoteResponse.deposit_route?(resp)
    end
  end
end
