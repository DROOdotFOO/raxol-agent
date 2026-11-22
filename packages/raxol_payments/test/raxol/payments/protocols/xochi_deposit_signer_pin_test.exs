defmodule Raxol.Payments.Protocols.XochiDepositSignerPinTest do
  # async: false -- sets the global :deployment, :require_deposit_signer_pin
  # and :xochi_deposit_attestation_signer.
  use ExUnit.Case, async: false

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.{Capabilities, DepositAttestation}
  alias Raxol.Payments.Xochi.Schemas.{DepositRouteRequest, QuoteResponse}

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @evm_recipient "0x" <> String.duplicate("ab", 20)
  @priv <<7::256>>
  @config %{base_url: "https://xochi.test"}

  setup do
    for key <- [:deployment, :require_deposit_signer_pin, :xochi_deposit_attestation_signer] do
      previous = Application.fetch_env(:raxol_payments, key)
      Application.delete_env(:raxol_payments, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_payments, key, value)
          :error -> Application.delete_env(:raxol_payments, key)
        end
      end)
    end

    :ok
  end

  describe "verify_deposit_route/4 signer resolution" do
    test "outside production an unpinned run falls back to the capability matrix signer" do
      Application.put_env(:raxol_payments, :deployment, :development)

      assert {:ok, %{deposit_address: @deposit_addr}} = verify(capabilities: matrix(signer()))
    end

    test "in production the capability matrix signer is refused without an operator pin" do
      Application.put_env(:raxol_payments, :deployment, :production)

      assert {:error, :deposit_signer_unpinned} = verify(capabilities: matrix(signer()))
    end

    test "in production an operator pin verifies, from opts or from config" do
      Application.put_env(:raxol_payments, :deployment, :production)

      assert {:ok, _} = verify(capabilities: matrix(nil), deposit_attestation_signer: signer())

      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())
      assert {:ok, _} = verify(capabilities: matrix(nil))
    end

    test "the pin is never overridden by a matrix signer that disagrees" do
      Application.put_env(:raxol_payments, :deployment, :development)
      attacker = "0x000000000000000000000000000000000000dEaD"

      assert {:error, :attestation_mismatch} =
               verify(capabilities: matrix(signer()), deposit_attestation_signer: attacker)
    end

    test "explicit config wins over the production default, both ways" do
      Application.put_env(:raxol_payments, :deployment, :production)
      Application.put_env(:raxol_payments, :require_deposit_signer_pin, false)
      assert {:ok, _} = verify(capabilities: matrix(signer()))

      Application.put_env(:raxol_payments, :deployment, :development)
      Application.put_env(:raxol_payments, :require_deposit_signer_pin, true)
      assert {:error, :deposit_signer_unpinned} = verify(capabilities: matrix(signer()))
    end

    test "a malformed operator pin is refused, not trusted or skipped" do
      Application.put_env(:raxol_payments, :deployment, :development)
      "0x" <> bare = signer()

      for pin <- [bare, signer() <> "\n", " " <> signer(), "0x" <> signer(), "not-an-address"] do
        assert {:error, :invalid_deposit_signer_pin} =
                 verify(capabilities: matrix(signer()), deposit_attestation_signer: pin)
      end
    end
  end

  describe "operator pin edge cases" do
    test "an empty opts pin does not mask a configured pin" do
      Application.put_env(:raxol_payments, :deployment, :development)
      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())
      attacker_matrix = matrix("0x000000000000000000000000000000000000dEaD")

      for pin <- ["", nil] do
        assert {:ok, _} = verify(capabilities: attacker_matrix, deposit_attestation_signer: pin)
      end
    end

    test "a checksummed or 0X pin verifies" do
      Application.put_env(:raxol_payments, :deployment, :production)
      "0x" <> hex = signer()

      for pin <- ["0X" <> hex, "0x" <> String.upcase(hex)],
          do:
            assert({:ok, _} = verify(capabilities: matrix(nil), deposit_attestation_signer: pin))
    end

    test "any configured value but false requires the pin" do
      Application.put_env(:raxol_payments, :deployment, :development)

      for value <- [true, nil, "true", "false", 1] do
        Application.put_env(:raxol_payments, :require_deposit_signer_pin, value)
        assert {:error, :deposit_signer_unpinned} = verify(capabilities: matrix(signer()))
      end
    end

    test "a required pin never fetches the capability matrix" do
      Application.put_env(:raxol_payments, :deployment, :production)
      test_pid = self()

      config = %{
        base_url: "https://xochi.test",
        req_options: [
          plug: fn conn ->
            send(test_pid, {:fetched, conn.request_path})
            Plug.Conn.send_resp(conn, 500, "")
          end
        ]
      }

      quote_resp = QuoteResponse.from_json(quote_body())

      assert {:error, :deposit_signer_unpinned} =
               Xochi.verify_deposit_route(config, request(), quote_resp, [])

      refute_received {:fetched, _}
    end
  end

  describe "assert_deposit_signer_pinned!/2" do
    test "raises when no valid pin is set and the pin is not required" do
      for pin <- [nil, ""] do
        assert_raise ArgumentError, ~r/deposit-attestation signer is not pinned/, fn ->
          Xochi.assert_deposit_signer_pinned!(pin, false)
        end
      end

      for pin <- ["0x1234", 42] do
        assert_raise ArgumentError, ~r/40-hex/, fn ->
          Xochi.assert_deposit_signer_pinned!(pin, false)
        end
      end
    end

    test "passes with a valid pin, or when the pin is required" do
      assert :ok = Xochi.assert_deposit_signer_pinned!(signer(), false)
      assert :ok = Xochi.assert_deposit_signer_pinned!(signer(), true)
      assert :ok = Xochi.assert_deposit_signer_pinned!(nil, true)
    end

    test "raises on a set but malformed pin, even when the pin is required" do
      assert_raise ArgumentError, ~r/not a 0x \+ 40-hex address/, fn ->
        Xochi.assert_deposit_signer_pinned!("0x1234", true)
      end
    end
  end

  describe "assert_deposit_signer_pinned!/0" do
    test "reads the configured pin and requirement" do
      Application.put_env(:raxol_payments, :deployment, :development)

      assert_raise ArgumentError, ~r/fail-open/, fn -> Xochi.assert_deposit_signer_pinned!() end

      Application.put_env(:raxol_payments, :deployment, :production)
      assert :ok = Xochi.assert_deposit_signer_pinned!()

      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, "0xbad")
      assert_raise ArgumentError, ~r/40-hex/, fn -> Xochi.assert_deposit_signer_pinned!() end

      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())
      Application.put_env(:raxol_payments, :require_deposit_signer_pin, false)
      assert :ok = Xochi.assert_deposit_signer_pinned!()
    end
  end

  defp verify(opts) do
    Xochi.verify_deposit_route(@config, request(), QuoteResponse.from_json(quote_body()), opts)
  end

  defp matrix(signer), do: %{Capabilities.fallback() | deposit_attestation_signer: signer}

  defp request do
    %DepositRouteRequest{
      wallet: "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7",
      from_chain_id: 728_126_428,
      to_chain_id: 8453,
      from_token: @tron_usdt,
      to_token: @evm_recipient,
      from_amount: "1000000",
      recipient_address: @evm_recipient
    }
  end

  defp quote_body do
    %{
      "intent_id" => "xi_dep_pin",
      "quote_id" => "xq_dep_pin",
      "can_solve" => true,
      "to_amount" => "995000",
      "deposit_address" => @deposit_addr,
      "deposit_attestation" => attestation()
    }
  end

  defp signer do
    {:ok, <<_prefix::8, xy::binary-size(64)>>} = ExSecp256k1.create_public_key(@priv)
    <<_first12::binary-size(12), addr::binary-size(20)>> = ExKeccak.hash_256(xy)
    "0x" <> Base.encode16(addr, case: :lower)
  end

  defp attestation do
    message =
      DepositAttestation.message(%{
        intent_id: "xi_dep_pin",
        quote_id: "xq_dep_pin",
        from_chain_id: 728_126_428,
        from_token: @tron_usdt,
        from_amount: "1000000",
        deposit_address: @deposit_addr
      })

    digest =
      ("\x19Ethereum Signed Message:\n" <> Integer.to_string(byte_size(message)) <> message)
      |> ExKeccak.hash_256()

    {:ok, signature} = ExSecp256k1.sign(digest, @priv)
    "0x" <> Base.encode16(EIP712.pack_signature(signature), case: :lower)
  end
end
