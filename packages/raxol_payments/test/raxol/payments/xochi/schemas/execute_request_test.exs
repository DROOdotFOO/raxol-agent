defmodule Raxol.Payments.Xochi.Schemas.ExecuteRequestTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.ExecuteRequest

  describe "ExecuteRequest.to_json/1" do
    test "converts to JSON with required fields" do
      req = %ExecuteRequest{
        intent_id: "intent_123",
        quote_id: "quote_456",
        signature: "0xdeadbeef",
        nonce: 42
      }

      json = ExecuteRequest.to_json(req)

      assert json["intent_id"] == "intent_123"
      assert json["quote_id"] == "quote_456"
      assert json["signature"] == "0xdeadbeef"
      assert json["nonce"] == 42
      refute Map.has_key?(json, "pull_signature")
    end

    test "includes optional fields when set" do
      req = %ExecuteRequest{
        intent_id: "i",
        quote_id: "q",
        signature: "0x",
        nonce: 1,
        pull_signature: "0xpull",
        aztec_proof: "0xproof"
      }

      json = ExecuteRequest.to_json(req)
      assert json["pull_signature"] == "0xpull"
      assert json["aztec_proof"] == "0xproof"
    end
  end
end
