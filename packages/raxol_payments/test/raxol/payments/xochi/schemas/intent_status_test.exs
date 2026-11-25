defmodule Raxol.Payments.Xochi.Schemas.IntentStatusTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.IntentStatus

  describe "IntentStatus.from_json/1" do
    test "parses JSON status" do
      json = %{
        "intentId" => "intent_123",
        "status" => "bridging",
        "txHash" => "0xabc",
        "updatedAt" => "2026-04-06T12:00:00Z",
        "terminal" => false
      }

      status = IntentStatus.from_json(json)
      assert status.intent_id == "intent_123"
      assert status.status == :bridging
      assert status.tx_hash == "0xabc"
      assert status.terminal == false
    end

    test "parses the worker's snake_case shape (canonical wire format)" do
      # Mirrors xochi handlePollIntentStatus's terminal response body (intents.ts).
      json = %{
        "intent_id" => "xi_164840b490711c736ae8187ac7b48dff",
        "status" => "completed",
        "tx_hash" => "0xabc",
        "terminal" => true
      }

      status = IntentStatus.from_json(json)
      assert status.intent_id == "xi_164840b490711c736ae8187ac7b48dff"
      assert status.status == :completed
      assert status.tx_hash == "0xabc"
      assert status.terminal == true
    end

    test "detects terminal statuses" do
      for s <- ["completed", "failed", "expired", "refunded"] do
        json = %{"intentId" => "i", "status" => s}
        status = IntentStatus.from_json(json)
        assert IntentStatus.terminal?(status), "expected #{s} to be terminal"
      end
    end

    test "parses the refunded status and its reason (camelCase and snake_case)" do
      for key <- ["refundReason", "refund_reason"] do
        json = %{"intent_id" => "int_r", "status" => "refunded", key => "solver timeout"}
        status = IntentStatus.from_json(json)
        assert status.status == :refunded
        assert status.refund_reason == "solver timeout"
        # Terminal independently of the worker's `terminal` flag: refunded is a
        # terminal status, so a poll stops even if the worker omits the flag.
        assert IntentStatus.terminal?(status)
      end
    end

    test "refund_reason is nil when the worker omits it" do
      json = %{"intent_id" => "int_r", "status" => "refunded", "terminal" => true}
      status = IntentStatus.from_json(json)
      assert status.status == :refunded
      assert status.refund_reason == nil
    end

    test "non-terminal statuses" do
      for s <- [
            "pending",
            "pull_pending",
            "executing",
            "bridging",
            "settling",
            "source_finalized",
            "refund_pending"
          ] do
        json = %{"intentId" => "i", "status" => s}
        status = IntentStatus.from_json(json)
        assert status.status == String.to_existing_atom(s)
        refute IntentStatus.terminal?(status), "expected #{s} to be non-terminal"
      end
    end

    test "source_finalized and refund_pending stay non-terminal under a terminal flag" do
      for s <- ["source_finalized", "refund_pending"] do
        status = IntentStatus.from_json(%{"intent_id" => "i", "status" => s, "terminal" => true})
        refute IntentStatus.terminal?(status), "expected #{s} to be non-terminal"
      end
    end

    test "parses PXE shielded settlement fields" do
      json = %{
        "intentId" => "intent_pxe",
        "status" => "completed",
        "settlementType" => "shielded",
        "noteCommitment" => "0xcommit123",
        "nullifierHash" => "0xnull456",
        "l2TxHash" => "0xl2tx789"
      }

      status = IntentStatus.from_json(json)
      assert status.settlement_type == :shielded
      assert status.note_commitment == "0xcommit123"
      assert status.nullifier_hash == "0xnull456"
      assert status.l2_tx_hash == "0xl2tx789"
    end

    test "parses stealth settlement type" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "stealth"
      }

      status = IntentStatus.from_json(json)
      assert status.settlement_type == :stealth
    end

    test "nil settlement type when not present" do
      json = %{"intentId" => "i", "status" => "pending"}
      status = IntentStatus.from_json(json)
      assert status.settlement_type == nil
    end

    test "parses the anonymous view's markers of a private settlement" do
      status =
        IntentStatus.from_json(%{
          "intent_id" => "i",
          "status" => "settling",
          "settlement_type" => "shielded",
          "settlement_confirmed" => true,
          "legs_withheld" => true
        })

      assert status.legs_withheld
      assert status.settlement_confirmed
      assert IntentStatus.settlement_confirmed?(status)
      refute IntentStatus.terminal?(status)
    end

    test "parses the owner view's settlement receipt and chain" do
      hash = "0x" <> String.duplicate("e", 64)

      status =
        IntentStatus.from_json(%{
          "intent_id" => "i",
          "status" => "settling",
          "settlement_tx_hash" => hash,
          "settlement_chain_id" => 10
        })

      assert status.settlement_tx_hash == hash
      assert status.settlement_chain_id == 10
      refute status.legs_withheld
      assert IntentStatus.settlement_confirmed?(status)
    end

    test "a status without either marker is unconfirmed and not withheld" do
      status = IntentStatus.from_json(%{"intent_id" => "i", "status" => "settling"})
      refute status.legs_withheld
      refute IntentStatus.settlement_confirmed?(status)
    end

    test "shielded? returns true for shielded settlement_type" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "shielded"
      }

      status = IntentStatus.from_json(json)
      assert IntentStatus.shielded?(status)
    end

    test "shielded? returns true when note_commitment present" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "noteCommitment" => "0xcommit"
      }

      status = IntentStatus.from_json(json)
      assert IntentStatus.shielded?(status)
    end

    test "shielded? returns false for public settlement" do
      json = %{
        "intentId" => "i",
        "status" => "completed",
        "settlementType" => "public"
      }

      status = IntentStatus.from_json(json)
      refute IntentStatus.shielded?(status)
    end

    test "parses attestation_status verified" do
      json = %{"intentId" => "i", "status" => "completed", "attestationStatus" => "verified"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :verified
    end

    test "parses attestation_status rejected" do
      json = %{"intentId" => "i", "status" => "failed", "attestationStatus" => "rejected"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :rejected
    end

    test "parses attestation_status not_required" do
      json = %{"intentId" => "i", "status" => "completed", "attestationStatus" => "not_required"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == :not_required
    end

    test "attestation_status nil when not present" do
      json = %{"intentId" => "i", "status" => "pending"}
      status = IntentStatus.from_json(json)
      assert status.attestation_status == nil
    end
  end
end
