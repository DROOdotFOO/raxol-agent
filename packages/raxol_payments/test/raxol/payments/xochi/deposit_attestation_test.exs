defmodule Raxol.Payments.Xochi.DepositAttestationTest do
  # The fail-closed policy around a v3 deposit attestation. Byte-exact encoding
  # is pinned by Riddler's own vectors in deposit_attestation_conformance_test.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Test.DepositAttestationFixture, as: Fixture
  alias Raxol.Payments.Xochi.DepositAttestation

  # Real secp256k1 keys, no mocks.
  @priv <<1::256>>
  @now 1_800_000_000

  defp signer, do: Fixture.address(@priv)

  defp expect(overrides \\ %{}),
    do:
      Map.merge(%{signer: signer(), version: DepositAttestation.version(), now: @now}, overrides)

  describe "message/1" do
    test "is eighteen lines opening with the v3 tag, absent optionals as empty lines" do
      assert {:ok, message} = DepositAttestation.message(Fixture.fields())
      lines = String.split(message, "\n")

      assert length(lines) == 18
      assert hd(lines) == "xochi-deposit-attestation:v3"
      assert Enum.at(lines, 9) == ""
      assert Enum.slice(lines, 15, 2) == ["", ""]
      assert List.last(lines) == "public"
    end

    test "refuses a field containing the delimiter instead of signing it" do
      for field <- [:wallet, :recipient, :refund_address, :deposit_address, :intent_id] do
        assert {:error, {:newline_in_field, ^field}} =
                 DepositAttestation.message(Fixture.fields(%{field => "TLa2f6\nX"}))
      end
    end

    test "folds only a lowercase 0x prefix" do
      assert {:ok, folded} =
               DepositAttestation.message(Fixture.fields(%{refund_address: "0xAbC"}))

      assert {:ok, verbatim} =
               DepositAttestation.message(Fixture.fields(%{refund_address: "0XAbC"}))

      assert Enum.at(String.split(folded, "\n"), 9) == "0xabc"
      assert Enum.at(String.split(verbatim, "\n"), 9) == "0XAbC"
    end
  end

  describe "check_version/1" do
    test "accepts only v3" do
      assert :ok = DepositAttestation.check_version("xochi-deposit-attestation:v3")

      for other <- ["xochi-deposit-attestation:v1", "xochi-deposit-attestation:v2", "", nil, 3] do
        assert {:error, {:unsupported_deposit_attestation_version, ^other}} =
                 DepositAttestation.check_version(other)
      end
    end
  end

  describe "verify/3" do
    test "accepts a v3 attestation by the pinned signer with the window open" do
      fields = Fixture.fields()
      assert :ok = DepositAttestation.verify(fields, Fixture.sign(fields, @priv), expect())
    end

    test "is case-insensitive on the pinned signer" do
      fields = Fixture.fields()

      assert :ok =
               DepositAttestation.verify(
                 fields,
                 Fixture.sign(fields, @priv),
                 expect(%{signer: String.upcase(signer())})
               )
    end

    test "refuses a v1 attestation over the same deal, even when genuinely signed" do
      fields = Fixture.fields()

      v1 =
        Enum.join(
          [
            "xochi-deposit-attestation:v1",
            fields.intent_id,
            fields.quote_id,
            Integer.to_string(fields.from_chain_id),
            fields.from_token,
            fields.from_amount,
            fields.deposit_address
          ],
          "\n"
        )

      assert {:error, :attestation_mismatch} =
               DepositAttestation.verify(fields, Fixture.sign_message(v1, @priv), expect())
    end

    test "refuses a venue that advertises anything but v3, before recovery" do
      fields = Fixture.fields()
      sig = Fixture.sign(fields, @priv)

      assert {:error, {:unsupported_deposit_attestation_version, "xochi-deposit-attestation:v1"}} =
               DepositAttestation.verify(
                 fields,
                 sig,
                 expect(%{version: "xochi-deposit-attestation:v1"})
               )

      assert {:error, {:unsupported_deposit_attestation_version, nil}} =
               DepositAttestation.verify(fields, sig, expect(%{version: nil}))
    end

    test "refuses a closed or absent deposit window" do
      fields = Fixture.fields(%{deposit_deadline: @now})
      sig = Fixture.sign(fields, @priv)

      assert {:error, {:deposit_deadline_passed, %{deadline: @now, now: @now}}} =
               DepositAttestation.verify(fields, sig, expect())

      assert :ok = DepositAttestation.verify(fields, sig, expect(%{now: @now - 1}))

      no_deadline = Fixture.fields(%{deposit_deadline: nil})

      assert {:error, :missing_deposit_deadline} =
               DepositAttestation.verify(no_deadline, Fixture.sign(no_deadline, @priv), expect())

      assert {:error, {:invalid_deposit_deadline, "soon"}} =
               DepositAttestation.verify(
                 Fixture.fields(%{deposit_deadline: "soon"}),
                 sig,
                 expect()
               )
    end

    test "refuses a substituted deposit address (MITM swap)" do
      sig = Fixture.sign(Fixture.fields(), @priv)
      swapped = Fixture.fields(%{deposit_address: "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"})

      assert {:error, :attestation_mismatch} = DepositAttestation.verify(swapped, sig, expect())
    end

    test "refuses another signer" do
      fields = Fixture.fields()

      assert {:error, :attestation_mismatch} =
               DepositAttestation.verify(
                 fields,
                 Fixture.sign(fields, <<2::256>>),
                 expect()
               )
    end

    test "fails closed on a missing attestation or signer" do
      fields = Fixture.fields()
      sig = Fixture.sign(fields, @priv)

      assert {:error, :missing_attestation} = DepositAttestation.verify(fields, nil, expect())
      assert {:error, :missing_attestation} = DepositAttestation.verify(fields, "", expect())

      assert {:error, :signer_unavailable} =
               DepositAttestation.verify(fields, sig, expect(%{signer: nil}))

      assert {:error, :signer_unavailable} =
               DepositAttestation.verify(fields, sig, expect(%{signer: ""}))
    end

    test "refuses a malformed signature" do
      fields = Fixture.fields()
      "0x" <> hex = Fixture.sign(fields, @priv)
      <<rs::binary-size(128), _v::binary-size(2)>> = hex

      for bad <- ["0xdeadbeef", "not-a-sig", hex, "0x" <> rs <> "1d", "0x" <> rs <> "zz"] do
        assert {:error, :invalid_signature} = DepositAttestation.verify(fields, bad, expect())
      end
    end
  end
end
