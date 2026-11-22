defmodule Raxol.Payments.Xochi.Schemas.ExecuteResponseTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.ExecuteResponse

  describe "ExecuteResponse.from_json/1" do
    test "parses JSON response" do
      json = %{
        "success" => true,
        "intentId" => "intent_123",
        "status" => "executing",
        "txHash" => "0xabc"
      }

      resp = ExecuteResponse.from_json(json)
      assert resp.success == true
      assert resp.intent_id == "intent_123"
      assert resp.status == :executing
      assert resp.tx_hash == "0xabc"
    end

    test "parses stealth settlement fields" do
      json = %{
        "success" => true,
        "intentId" => "i",
        "status" => "settling",
        "stealthAddress" => "0xstealth",
        "ephemeralPubKey" => "0xeph",
        "viewTag" => 42
      }

      resp = ExecuteResponse.from_json(json)
      assert resp.stealth_address == "0xstealth"
      assert resp.ephemeral_pub_key == "0xeph"
      assert resp.view_tag == 42
    end

    test "parses the worker's snake_case shape (canonical wire format)" do
      # Mirrors xochi handleExecuteIntent's response body (intents.ts).
      json = %{
        "success" => true,
        "intent_id" => "xi_164840b490711c736ae8187ac7b48dff",
        "status" => "executing",
        "tx_hash" => "0xabc",
        "stealth_address" => "0xstealth",
        "ephemeral_pub_key" => "0xeph",
        "view_tag" => 7
      }

      resp = ExecuteResponse.from_json(json)
      assert resp.intent_id == "xi_164840b490711c736ae8187ac7b48dff"
      assert resp.status == :executing
      assert resp.tx_hash == "0xabc"
      assert resp.stealth_address == "0xstealth"
      assert resp.ephemeral_pub_key == "0xeph"
      assert resp.view_tag == 7
    end

    test "parses every served lifecycle status" do
      for s <- ~w(pending pull_pending executing bridging settling source_finalized
                  completed refund_pending refunded failed expired) do
        resp = ExecuteResponse.from_json(%{"intent_id" => "i", "status" => s})
        assert resp.status == String.to_existing_atom(s)
      end
    end

    test "an unlisted status parses as unknown" do
      assert ExecuteResponse.from_json(%{"intent_id" => "i", "status" => "bogus"}).status ==
               :unknown
    end
  end
end
