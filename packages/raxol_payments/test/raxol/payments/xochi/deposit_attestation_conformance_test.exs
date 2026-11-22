defmodule Raxol.Payments.Xochi.DepositAttestationConformanceTest do
  # Byte-exact parity with Riddler's v3 signer, judged by the vectors Riddler
  # (the producer) generates -- never by vectors recomputed here, which would
  # pass for any encoding, a wrong one included.
  #
  # `test/fixtures/deposit_attestation_vectors.json` is
  # axol-io/Riddler `priv/conformance/deposit_attestation.json` (master
  # 3df48684), vendored byte for byte. Riddler serves the same file at
  # `/xochi/vectors/deposit-attestation.json` and publishes its sha256 on
  # `GET /xochi/capabilities` as `deposit_attestation_vectors_sha256`; the
  # pinned digest is `test/fixtures/DEPOSIT_ATTESTATION_VECTORS_SHA256`. To
  # refresh: copy the served file, update the digest, and re-run this test.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.DepositAttestation

  @fixtures Path.expand("../../../fixtures", __DIR__)
  @vectors_path Path.join(@fixtures, "deposit_attestation_vectors.json")
  @sha_path Path.join(@fixtures, "DEPOSIT_ATTESTATION_VECTORS_SHA256")
  @external_resource @vectors_path
  @external_resource @sha_path

  @body File.read!(@vectors_path)
  @doc_map Jason.decode!(@body)
  @fields ~w(intent_id quote_id wallet from_chain_id from_token from_amount deposit_address
             deposit_deadline refund_address to_chain_id to_token to_amount min_to_amount
             recipient stealth_spending_pub_key stealth_viewing_pub_key settlement_preference)a

  # Verified against a deadline long before every vector's.
  @now 0

  defp fields(quote), do: Map.new(@fields, &{&1, Map.fetch!(quote, Atom.to_string(&1))})

  defp expectation,
    do: %{signer: @doc_map["signer"], version: DepositAttestation.version(), now: @now}

  test "the vendored vectors are byte-identical to the pinned Riddler file" do
    pinned = @sha_path |> File.read!() |> String.trim()
    assert :crypto.hash(:sha256, @body) |> Base.encode16(case: :lower) == pinned
  end

  test "the vectors are v3 and this client verifies exactly v3" do
    assert @doc_map["version"] == DepositAttestation.version()
    assert DepositAttestation.version() == "xochi-deposit-attestation:v3"
    assert length(@doc_map["vectors"]) == 13
    # Riddler's all-abandon test key.
    assert @doc_map["signer"] == "0xf99f53e8f301ab2cfeb40a21a11757a71dac2bed"
  end

  test "every vector quote carries exactly the v3 field set" do
    for vector <- @doc_map["vectors"] do
      assert vector["quote"] |> Map.keys() |> Enum.sort() ==
               @fields |> Enum.map(&Atom.to_string/1) |> Enum.sort(),
             vector["name"]
    end
  end

  for vector <- @doc_map["vectors"] do
    @vector vector

    describe "vector #{vector["name"]}" do
      test "message/1 is byte-exact" do
        assert {:ok, message} = DepositAttestation.message(fields(@vector["quote"]))
        assert message == @vector["message"]
        assert message |> String.split("\n") |> length() == 18
      end

      test "recovers to the vector signer and verifies" do
        fields = fields(@vector["quote"])

        assert {:ok, recovered} =
                 DepositAttestation.recover(fields, @vector["deposit_attestation"])

        assert recovered == @doc_map["signer"]

        assert :ok =
                 DepositAttestation.verify(fields, @vector["deposit_attestation"], expectation())
      end
    end
  end

  test "the Canton hint case vectors are two different deals" do
    by_name = Map.new(@doc_map["vectors"], &{&1["name"], &1})
    upper = by_name["canton_party_recipient_case_preserved"]
    lower = by_name["canton_party_hint_case_is_a_different_party"]

    assert {:ok, upper_message} = DepositAttestation.message(fields(upper["quote"]))
    assert {:ok, lower_message} = DepositAttestation.message(fields(lower["quote"]))
    refute upper_message == lower_message

    assert {:error, :attestation_mismatch} =
             DepositAttestation.verify(
               fields(lower["quote"]),
               upper["deposit_attestation"],
               expectation()
             )
  end

  test "a vector's genuine attestation does not verify for any single altered field" do
    [vector | _] = @doc_map["vectors"]
    fields = fields(vector["quote"])

    alterations = %{
      intent_id: "xi_other",
      quote_id: "xq_other",
      wallet: "0x" <> String.duplicate("11", 20),
      from_chain_id: 1,
      from_token: "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8",
      from_amount: "1000001",
      deposit_address: "TXYZopqrstuvWXYZabcdefghijklmnop12",
      deposit_deadline: 1_750_000_001,
      refund_address: "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX",
      to_chain_id: 1,
      to_token: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48",
      to_amount: "997001",
      min_to_amount: "1",
      recipient: "0x" <> String.duplicate("22", 20),
      stealth_spending_pub_key: "0x02" <> String.duplicate("ab", 32),
      stealth_viewing_pub_key: "0x03" <> String.duplicate("cd", 32),
      settlement_preference: "stealth"
    }

    assert Map.keys(alterations) |> Enum.sort() == Enum.sort(@fields)

    for {field, value} <- alterations do
      assert {:error, :attestation_mismatch} =
               DepositAttestation.verify(
                 Map.put(fields, field, value),
                 vector["deposit_attestation"],
                 expectation()
               ),
             "altering #{field} still verified"
    end
  end
end
