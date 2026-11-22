defmodule Raxol.Payments.Xochi.Schemas.QuoteRequestTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  describe "QuoteRequest.to_json/1" do
    test "converts struct to camelCase JSON map" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        slippage_bps: 100,
        gasless: true
      }

      json = QuoteRequest.to_json(req)

      assert json["wallet"] == "0xabc"
      assert json["from_chain_id"] == 1
      assert json["to_chain_id"] == 8453
      assert json["from_amount"] == "1000000"
      assert json["settlement_preference"] == "public"
      assert json["slippage_bps"] == 100
      assert json["gasless"] == true
      assert is_integer(json["deadline"])
    end

    test "includes trust_score when set" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        trust_score: 75
      }

      json = QuoteRequest.to_json(req)
      assert json["trust_score"] == 75
    end

    test "omits trust_score when nil" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "trust_score")
    end

    test "includes recipient_address when set" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 8453,
        to_chain_id: 728_126_428,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        recipient_address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
      }

      json = QuoteRequest.to_json(req)
      assert json["recipient_address"] == "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
    end

    test "omits recipient_address when nil (Xochi defaults it to the wallet)" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "recipient_address")
    end

    test "includes attestations when non-empty" do
      attestation = %{
        type_code: 0x01,
        issuer: "0xoracle",
        subject: "0xsubject",
        issued_at: 1000,
        expires_at: 2000,
        signature: "0xsig",
        payload: <<0xDE, 0xAD>>
      }

      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public",
        attestations: [attestation]
      }

      json = QuoteRequest.to_json(req)
      assert [att] = json["attestations"]
      assert att["typeCode"] == 0x01
      assert att["issuer"] == "0xoracle"
      assert att["payload"] == "dead"
    end

    test "omits attestations when empty" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "attestations")
    end

    test "includes stealth pub keys when set" do
      spending = "0x02" <> String.duplicate("ab", 32)
      viewing = "0x03" <> String.duplicate("cd", 32)

      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: spending,
        stealth_viewing_pub_key: viewing
      }

      json = QuoteRequest.to_json(req)
      assert json["stealth_spending_pub_key"] == spending
      assert json["stealth_viewing_pub_key"] == viewing
    end

    test "omits stealth pub keys when nil" do
      req = %QuoteRequest{
        wallet: "0xabc",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xA0b8",
        to_token: "0x8335",
        from_amount: "1000000",
        settlement_preference: "public"
      }

      json = QuoteRequest.to_json(req)
      refute Map.has_key?(json, "stealth_spending_pub_key")
      refute Map.has_key?(json, "stealth_viewing_pub_key")
    end
  end

  @valid_addr "0x" <> String.duplicate("ab", 20)

  describe "QuoteRequest.validate/1" do
    test "valid request returns :ok" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert :ok = QuoteRequest.validate(req)
    end

    test "accepts a non-EVM (base58) recipient_address -- Riddler validates the format" do
      # A cross-VM route (EVM origin, Tron destination) sends a base58 recipient.
      # raxol must not apply its EVM 0x-hex check to it; Riddler validates the
      # format against to_chain_id.
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 8453,
        to_chain_id: 728_126_428,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public",
        recipient_address: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
      }

      assert :ok = QuoteRequest.validate(req)
    end

    test "empty recipient_address returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public",
        recipient_address: ""
      }

      assert {:error, {:invalid_recipient_address, _}} = QuoteRequest.validate(req)
    end

    test "invalid wallet address returns error" do
      req = %QuoteRequest{
        wallet: "not_an_address",
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_wallet, _}} = QuoteRequest.validate(req)
    end

    test "invalid token address returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: "0xshort",
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_from_token, _}} = QuoteRequest.validate(req)
    end

    test "chain ID of 0 returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 0,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      }

      assert {:error, {:invalid_chain_id, _}} = QuoteRequest.validate(req)
    end

    test "stealth settlement without pub keys returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth"
      }

      assert {:error, {:stealth_keys_required, _}} = QuoteRequest.validate(req)
    end

    test "stealth settlement with compressed pub keys returns :ok" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: "0x02" <> String.duplicate("ab", 32),
        stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32)
      }

      assert :ok = QuoteRequest.validate(req)
    end

    test "stealth settlement with malformed pub keys returns error" do
      req = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: "0x04deadbeef",
        stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32)
      }

      assert {:error, {:stealth_keys_required, _}} = QuoteRequest.validate(req)
    end

    # Tron, a synthetic unknown chain, and a registered testnet (allowed).
    test "stealth settlement is refused on any chain outside the EVM registry" do
      stealth = %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 8453,
        to_chain_id: 1,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "stealth",
        stealth_spending_pub_key: "0x02" <> String.duplicate("ab", 32),
        stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32)
      }

      for chain <- [728_126_428, 999_999] do
        assert {:error, :stealth_unsupported_on_chain} =
                 QuoteRequest.validate(%{stealth | to_chain_id: chain})
      end

      assert :ok = QuoteRequest.validate(%{stealth | to_chain_id: 84_532})

      assert :ok =
               QuoteRequest.validate(%{
                 stealth
                 | to_chain_id: 999_999,
                   settlement_preference: "public"
               })
    end
  end

  describe "QuoteRequest swap_kind" do
    @exact_output [
      swap_kind: "exact_output",
      from_amount: nil,
      output_amount: "990000",
      max_from_amount: "1100000"
    ]

    test "exact_input keeps the from_amount wire shape with no swap_kind" do
      json = QuoteRequest.to_json(swap_request([]))

      assert json["from_amount"] == "1000000"
      refute Map.has_key?(json, "swap_kind")
      refute Map.has_key?(json, "output_amount")
      refute Map.has_key?(json, "max_from_amount")
    end

    test "exact_output sends swap_kind and output_amount, never from_amount or the ceiling" do
      req = swap_request(@exact_output)
      assert :ok = QuoteRequest.validate(req)

      json = QuoteRequest.to_json(req)
      assert json["swap_kind"] == "exact_output"
      assert json["output_amount"] == "990000"
      refute Map.has_key?(json, "from_amount")
      refute Map.has_key?(json, "max_from_amount")
    end

    test "validate refuses an incomplete or contradictory exact_output request" do
      for {overrides, reason} <- [
            {[output_amount: nil], :invalid_output_amount},
            {[output_amount: "1.5"], :invalid_output_amount},
            {[max_from_amount: nil], :invalid_max_from_amount},
            {[max_from_amount: "-1"], :invalid_max_from_amount},
            {[from_amount: "1000000"], :invalid_from_amount}
          ] do
        req = swap_request(Keyword.merge(@exact_output, overrides))
        assert {:error, {^reason, _}} = QuoteRequest.validate(req)
      end
    end

    test "validate refuses output_amount on exact_input and an unknown swap_kind" do
      assert {:error, {:invalid_output_amount, _}} =
               QuoteRequest.validate(swap_request(output_amount: "990000"))

      assert {:error, {:invalid_swap_kind, "exact"}} =
               QuoteRequest.validate(swap_request(swap_kind: "exact"))
    end
  end

  defp swap_request(overrides) do
    struct!(
      %QuoteRequest{
        wallet: @valid_addr,
        from_chain_id: 1,
        to_chain_id: 8453,
        from_token: @valid_addr,
        to_token: @valid_addr,
        from_amount: "1000000",
        settlement_preference: "public"
      },
      overrides
    )
  end
end
