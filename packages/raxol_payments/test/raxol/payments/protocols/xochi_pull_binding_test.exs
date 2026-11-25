defmodule Raxol.Payments.Protocols.XochiPullBindingTest do
  # Writes the global solver-pin settings, which other modules read.
  use ExUnit.Case, async: false

  import Raxol.Payments.Test.XochiProtocolFixture

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.{Permit2, Xochi}
  alias Raxol.Payments.Test.XochiProtocolFixture.RealWallet
  alias Raxol.Payments.Xochi.Schemas.QuoteResponse

  describe "execute/4 origin-pull binding" do
    setup :put_real_wallet_key

    test "signs the served pull_authorization and sends it as pull_signature" do
      pull = canonical_erc3009_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_pull",
        quote_id: "xq_pull",
        can_solve: true,
        payment_method: "erc3009",
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr()),
        pull_authorization: pull
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      request = request(anvil_addr())

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)

      # The pull_signature is over the served pull_authorization typed data,
      # rebuilt independently so a regression diverges the signature.
      pull_types = %{
        "ReceiveWithAuthorization" =>
          Enum.map(pull["types"]["ReceiveWithAuthorization"], fn f -> {f["name"], f["type"]} end)
      }

      pull_domain = %{
        name: "USD Coin",
        version: "2",
        chainId: 8453,
        verifyingContract: pull["domain"]["verifyingContract"]
      }

      {:ok, raw} = RealWallet.sign_typed_data(pull_domain, pull_types, pull["message"])

      assert body["pull_signature"] == "0x" <> Base.encode16(raw, case: :lower)
      # Distinct payload from the intent signature.
      assert body["pull_signature"] != body["signature"]
    end

    test "signs a permit2 pull over Permit2's own domain, which declares no version" do
      # Permit2's EIP-712 domain is name/chainId/verifyingContract -- it carries NO
      # `version`. A served domain that omits a field must not be signed as though
      # that field were present and empty: doing so hashes a 4-field EIP712Domain
      # against the 3-field one Permit2 rebuilds on-chain, so Permit2 asks
      # `isValidSignature` about a digest the buyer never signed and the pull
      # reverts InvalidContractSignature() (0xb0669cbc).
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [permit2_spender()])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      pull =
        canonical_permit2_pull(%{
          domain: %{
            "name" => "Permit2",
            "chainId" => 8453,
            "verifyingContract" => permit2_address()
          },
          message: %{"spender" => permit2_spender()}
        })

      quote_resp = %QuoteResponse{
        intent_id: "xi_p2domain",
        quote_id: "xq_p2domain",
        can_solve: true,
        payment_method: "permit2",
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr()),
        pull_authorization: pull
      }

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)

      expected = permit2_reference_signature(pull)
      assert body["pull_signature"] == "0x" <> Base.encode16(expected, case: :lower)
    end

    test "omits pull_signature when the quote carries no pull_authorization" do
      quote_resp = %QuoteResponse{
        intent_id: "xi_nopull",
        quote_id: "xq_nopull",
        can_solve: true,
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr())
      }

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request(anvil_addr()))
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      refute Map.has_key?(Jason.decode!(raw_body), "pull_signature")
    end

    test "refuses to authorize a pull that exceeds the amount, retargets the token, or is not from the signer" do
      erc3009_pull = fn overrides -> canonical_erc3009_pull(overrides) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_bad",
          quote_id: "xq_bad",
          can_solve: true,
          payment_method: "erc3009",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }
      end

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # value far above the intended origin amount, redirected to an attacker -- the drain vector
      over =
        quote_for.(
          erc3009_pull.(%{
            message: %{
              "value" => "100000000",
              "to" => "0x000000000000000000000000000000000000dEaD"
            }
          })
        )

      assert {:error, {:authorization_mismatch, :pull_value}} =
               Xochi.execute(config, over, RealWallet, request)

      # retargeted to a different token contract
      wrong_token =
        quote_for.(
          erc3009_pull.(%{
            domain: %{"verifyingContract" => "0x0000000000000000000000000000000000000bad"}
          })
        )

      assert {:error, {:authorization_mismatch, :pull_token}} =
               Xochi.execute(config, wrong_token, RealWallet, request)

      # pull from someone other than the signer
      wrong_from =
        quote_for.(
          erc3009_pull.(%{message: %{"from" => "0x000000000000000000000000000000000000beef"}})
        )

      assert {:error, {:authorization_mismatch, :pull_from}} =
               Xochi.execute(config, wrong_from, RealWallet, request)

      # nothing was signed or submitted for any rejected pull
      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "binds the pull recipient to an operator solver allowlist when configured" do
      solver = "0x0000000000000000000000000000000000005011"
      attacker = "0x000000000000000000000000000000000000dEaD"

      pull_to = fn to -> canonical_erc3009_pull(%{message: %{"to" => to}}) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_sv",
          quote_id: "xq_sv",
          can_solve: true,
          payment_method: "erc3009",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }
      end

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # fail-open: with no allowlist set, any solver recipient is accepted
      assert {:ok, _} =
               Xochi.execute(config, quote_for.(pull_to.(solver)), RealWallet, request)

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [solver])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      # an allowlisted recipient still passes
      assert {:ok, _} =
               Xochi.execute(config, quote_for.(pull_to.(solver)), RealWallet, request)

      # a recipient outside the allowlist is rejected before any signature
      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_for.(pull_to.(attacker)), RealWallet, request)
    end

    test "pins the canonical solver address the live gate uses, case-insensitively" do
      # The live gate pins this checksummed (mixed-case) Riddler solver. The
      # allowlist normalizes case, so a pull to the same address as the worker
      # serves it (lowercased) passes, while any other recipient is rejected
      # before signing -- the forged-`to` abort the gate relies on.
      canonical = "0x8d7d8AcfC25E999273394F7Ab44C239806724e2B"
      attacker = "0x000000000000000000000000000000000000dEaD"

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [canonical])
      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)

      on_exit(fn ->
        Application.delete_env(:raxol_payments, :pull_solver_allowlist)
        Application.delete_env(:raxol_payments, :pull_require_solver_pin)
      end)

      pull_to = fn to -> canonical_erc3009_pull(%{message: %{"to" => to}}) end

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_canon",
          quote_id: "xq_canon",
          can_solve: true,
          payment_method: "erc3009",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }
      end

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      # the pinned solver passes even when served lowercased
      assert {:ok, _} =
               Xochi.execute(
                 config,
                 quote_for.(pull_to.(String.downcase(canonical))),
                 RealWallet,
                 request
               )

      # any other recipient aborts with :pull_to
      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_for.(pull_to.(attacker)), RealWallet, request)
    end

    test "binds the permit2 spender to the solver allowlist when configured" do
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [
        "0x0000000000000000000000000000000000005011"
      ])

      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      # spender 0x...dEaD is not in the configured allowlist
      pull = canonical_permit2_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_p2",
        quote_id: "xq_p2",
        can_solve: true,
        payment_method: "permit2",
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr()),
        pull_authorization: pull
      }

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_spender}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "binds the permit2 verifyingContract to the canonical Permit2" do
      # The served verifyingContract decides WHO checks this signature. Left to
      # the quote, a hostile worker nominates a contract it controls -- one whose
      # DOMAIN_SEPARATOR() agrees with whatever it served -- and every check that
      # asks that address agrees with the payload. Meanwhile the allowance being
      # spent was granted to the canonical Permit2, which is where the pull runs.
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [
        "0x000000000000000000000000000000000000dEaD"
      ])

      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_vc",
          quote_id: "xq_vc",
          can_solve: true,
          payment_method: "permit2",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }
      end

      # The canonical address passes, served in any case.
      canonical = Permit2.verifying_contract()

      assert {:ok, _} =
               Xochi.execute(
                 config,
                 quote_for.(
                   canonical_permit2_pull(%{
                     domain: %{"verifyingContract" => String.downcase(canonical)}
                   })
                 ),
                 RealWallet,
                 request
               )

      # A verifier of the worker's choosing aborts before anything is signed.
      assert {:error, {:authorization_mismatch, :pull_verifier}} =
               Xochi.execute(
                 config,
                 quote_for.(
                   canonical_permit2_pull(%{
                     domain: %{
                       "verifyingContract" => "0x00000000000000000000000000000000000badc0"
                     }
                   })
                 ),
                 RealWallet,
                 request
               )

      # So does omitting it: the domain must carry exactly name, chainId and
      # verifyingContract.
      no_verifier =
        update_in(canonical_permit2_pull(), ["domain"], &Map.delete(&1, "verifyingContract"))

      assert {:error, {:authorization_mismatch, {:pull_domain, :fields}}} =
               Xochi.execute(config, quote_for.(no_verifier), RealWallet, request)
    end

    test "rejects a permit2 pull when no solver allowlist is configured (fail-closed)" do
      # Permit2 has NO on-chain recipient guard -- the spender picks where funds go
      # at call time -- so the pin is the only destination control and is always
      # required. With no allowlist set, a permit2 pull is unsafe to sign.
      pull = canonical_permit2_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_p2o",
        quote_id: "xq_p2o",
        can_solve: true,
        payment_method: "permit2",
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr()),
        pull_authorization: pull
      }

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_spender}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "rejects an erc3009 pull when pull_require_solver_pin is set and no allowlist" do
      # ERC-3009 is bounded even unpinned (the signed `to` + on-chain msg.sender ==
      # to), but an operator can demand a hard pin. With the flag on and no
      # allowlist, even a well-formed pull must be rejected before any signature.
      Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_require_solver_pin) end)

      pull = canonical_erc3009_pull()

      quote_resp = %QuoteResponse{
        intent_id: "xi_pin",
        quote_id: "xq_pin",
        can_solve: true,
        payment_method: "erc3009",
        to_amount: "990000",
        eip712_data: intent_eip712(anvil_addr()),
        pull_authorization: pull
      }

      request = request(anvil_addr())

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:authorization_mismatch, :pull_to}} =
               Xochi.execute(config, quote_resp, RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "rejects a pull whose envelope or expiry diverges from the claimed method" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      request = request(anvil_addr())

      quote_for = fn pull ->
        %QuoteResponse{
          intent_id: "xi_env",
          quote_id: "xq_env",
          can_solve: true,
          payment_method: "erc3009",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }
      end

      # TransferWithAuthorization has the same field names but no on-chain
      # `msg.sender == to` guard -- the validator must reject the wrong primaryType.
      transfer_fields = [
        %{"name" => "from", "type" => "address"},
        %{"name" => "to", "type" => "address"},
        %{"name" => "value", "type" => "uint256"},
        %{"name" => "validAfter", "type" => "uint256"},
        %{"name" => "validBefore", "type" => "uint256"},
        %{"name" => "nonce", "type" => "bytes32"}
      ]

      transfer_auth =
        canonical_erc3009_pull(%{
          primary_type: "TransferWithAuthorization",
          types: %{"TransferWithAuthorization" => transfer_fields}
        })

      assert {:error, {:authorization_mismatch, :pull_type}} =
               Xochi.execute(config, quote_for.(transfer_auth), RealWallet, request)

      # An extra signable field the validator never inspects.
      extra =
        canonical_erc3009_pull(%{
          types: %{
            "ReceiveWithAuthorization" =>
              Enum.concat(transfer_fields, [%{"name" => "evil", "type" => "address"}])
          }
        })

      assert {:error, {:authorization_mismatch, :pull_type}} =
               Xochi.execute(config, quote_for.(extra), RealWallet, request)

      # Already-expired authorization.
      expired = canonical_erc3009_pull(%{message: %{"validBefore" => "1"}})

      assert {:error, {:authorization_mismatch, :pull_expiry}} =
               Xochi.execute(config, quote_for.(expired), RealWallet, request)

      # Standing / far-future authorization beyond the bounded window.
      far =
        canonical_erc3009_pull(%{
          message: %{"validBefore" => Integer.to_string(System.system_time(:second) + 999_999)}
        })

      assert {:error, {:authorization_mismatch, :pull_expiry}} =
               Xochi.execute(config, quote_for.(far), RealWallet, request)

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end
  end

  # Permit2's DOMAIN_SEPARATOR() as deployed on Base (chain 8453), read from
  # 0x000000000022D473030F116dDEE9F6B43aC78BA3. It is the 3-field
  # EIP712Domain(string name,uint256 chainId,address verifyingContract): Permit2
  # declares no `version`. Hard-coded so this test is an independent oracle
  # rather than a second run of the code under test.
  @permit2_domain_separator "3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07"

  # Permit2 builds the PermitWitnessTransferFrom typehash by concatenating a fixed
  # stub with the caller's witness type string, not by EIP-712's alphabetical
  # encodeType. Reproduce Permit2's construction so the expected digest is the one
  # the contract computes. The witness string is XochiPullPermit2's.
  @permit2_typehash_stub "PermitWitnessTransferFrom(TokenPermissions permitted,address spender,uint256 nonce,uint256 deadline,"
  @permit2_witness_type_string "OriginPullWitness witness)OriginPullWitness(bytes32 orderId)TokenPermissions(address token,uint256 amount)"

  # The signature Permit2 will accept for `pull`: the anvil key over the digest
  # Permit2 itself rebuilds on-chain.
  defp permit2_reference_signature(pull) do
    key = Base.decode16!(String.trim_leading(anvil_key(), "0x"), case: :mixed)
    {:ok, signature} = ExSecp256k1.sign(permit2_reference_digest(pull), key)
    EIP712.pack_signature(signature)
  end

  defp permit2_reference_digest(pull) do
    message = pull["message"]
    permitted = message["permitted"]

    token_permissions =
      ExKeccak.hash_256(
        ExKeccak.hash_256("TokenPermissions(address token,uint256 amount)") <>
          address_word(permitted["token"]) <> uint_word(permitted["amount"])
      )

    witness =
      ExKeccak.hash_256(
        ExKeccak.hash_256("OriginPullWitness(bytes32 orderId)") <>
          bytes32_word(message["witness"]["orderId"])
      )

    struct_hash =
      ExKeccak.hash_256(
        ExKeccak.hash_256(@permit2_typehash_stub <> @permit2_witness_type_string) <>
          token_permissions <>
          address_word(message["spender"]) <>
          uint_word(message["nonce"]) <>
          uint_word(message["deadline"]) <>
          witness
      )

    ExKeccak.hash_256(
      <<0x19, 0x01>> <>
        Base.decode16!(@permit2_domain_separator, case: :lower) <> struct_hash
    )
  end

  defp address_word("0x" <> hex), do: <<0::size(96)>> <> Base.decode16!(hex, case: :mixed)
  defp uint_word(value), do: <<String.to_integer(value)::unsigned-big-256>>
  defp bytes32_word("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
end
