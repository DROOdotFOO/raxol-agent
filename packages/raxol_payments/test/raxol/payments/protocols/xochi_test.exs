defmodule Raxol.Payments.Protocols.XochiTest do
  # Writes the global solver-pin settings, which other modules read.
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Payments.Protocols.Xochi
  import Raxol.Payments.Test.XochiProtocolFixture

  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Test.XochiProtocolFixture.RealWallet
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  @signer_addr "0x1111111111111111111111111111111111111111"

  # Signs with a fixed 65-byte signature (520 bits). The signature value is
  # irrelevant to the nonce behaviour under test; this is a signing-boundary
  # stub, not a mock of an internal module.
  defmodule SignerWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_domain, _types, _message), do: {:ok, <<7::size(520)>>}
  end

  # Reports every signature to the test process, so a refusal can prove the
  # wallet was never asked to sign.
  defmodule NotifyingWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453

    def sign_typed_data(_domain, _types, _message) do
      send(self(), :signed)
      {:ok, <<7::size(520)>>}
    end
  end

  describe "Protocol behaviour stubs" do
    test "name returns Xochi" do
      assert Xochi.name() == "Xochi"
    end

    test "detect? always returns false" do
      refute Xochi.detect?(402, [{"payment-required", "test"}])
      refute Xochi.detect?(200, [])
    end

    test "parse_challenge returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_challenge([])
    end

    test "build_payment returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.build_payment(%{}, MockWallet)
    end

    test "parse_receipt returns not_a_402_protocol" do
      assert {:error, :not_a_402_protocol} = Xochi.parse_receipt([])
    end
  end

  describe "amount/1" do
    test "extracts to_amount as Decimal" do
      assert Decimal.equal?(
               Xochi.amount(%{to_amount: "1000000"}),
               Decimal.new("1000000")
             )
    end

    test "falls back to xochi_fee" do
      assert Decimal.equal?(
               Xochi.amount(%{xochi_fee: "3000"}),
               Decimal.new("3000")
             )
    end

    test "returns zero for unknown shape" do
      assert Decimal.equal?(Xochi.amount(%{}), Decimal.new(0))
    end
  end

  describe "validate_quote (via execute)" do
    test "rejects quotes that cannot be solved" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: false,
        error: "no liquidity"
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, {:cannot_solve, "no liquidity"}} =
               Xochi.execute(config, quote_resp, MockWallet, request(@signer_addr))
    end

    test "rejects quotes without eip712 data" do
      quote_resp = %Raxol.Payments.Xochi.Schemas.QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: true,
        eip712_data: nil
      }

      config = %{base_url: "https://test", auth_token: "t"}

      assert {:error, :no_eip712_data} =
               Xochi.execute(config, quote_resp, MockWallet, request(@signer_addr))
    end
  end

  describe "execute/4 nonce" do
    test "refuses an intent message carrying a field the v3 struct does not sign" do
      # SPEC §2.1: XochiIntent v3 has no `nonce`; an extra message key is a field
      # the signature would not cover, so the payload is refused before signing.
      quote_resp = intent_quote(request(@signer_addr), message: %{"nonce" => 42})

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:error, {:intent_mismatch, :intent_fields}} =
               Xochi.execute(config, quote_resp, NotifyingWallet, request(@signer_addr))

      refute_received :signed
      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end

    test "defaults to 0 when the signed message carries no nonce" do
      # The served XochiIntent type declares no nonce field.
      quote_resp = intent_quote(request(@signer_addr))

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet, request(@signer_addr))
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 0
    end
  end

  describe "validate_intent/2" do
    @attacker "0x000000000000000000000000000000000000dEaD"

    # Each served message diverges from `request(@signer_addr)` in one signed
    # field; the check refuses it before the wallet signs anything.
    test "refuses a served intent whose signed terms diverge from the request" do
      now = System.system_time(:second)

      cases = [
        wallet: %{"wallet" => @attacker},
        from_chain_id: %{"fromChainId" => 1},
        to_chain_id: %{"toChainId" => 10},
        from_token: %{"fromToken" => @attacker},
        to_token: %{"toToken" => @attacker},
        recipient: %{"recipient" => @attacker},
        settlement_preference: %{"settlementPreference" => "private"},
        deadline: %{"deadline" => now + 7200},
        deadline: %{"deadline" => "soon"},
        quoted_to_amount: %{"toAmount" => "1"},
        from_amount: %{"fromAmount" => "2000000"}
      ]

      for {field, message} <- cases do
        quote_resp = intent_quote(request(@signer_addr), message: message)
        assert_refused(quote_resp, request(@signer_addr), field)
      end
    end

    test "refuses an intent that is not a XochiIntent declaring every bound field" do
      honest = intent_quote(request(@signer_addr))

      wrong_type = put_in(honest.eip712_data["primaryType"], "Intent")

      undeclared =
        update_in(
          honest.eip712_data["types"]["XochiIntent"],
          &Enum.reject(&1, fn f -> f["name"] == "recipient" end)
        )

      for quote_resp <- [wrong_type, undeclared, %{honest | eip712_data: "not a map"}] do
        assert_refused(quote_resp, request(@signer_addr), :intent_type)
      end
    end

    test "accepts the honest intent, with the recipient defaulting to the wallet" do
      quote_resp = intent_quote(request(@signer_addr))
      assert quote_resp.eip712_data["message"]["recipient"] == @signer_addr
      assert :ok = Xochi.validate_intent(quote_resp, request(@signer_addr))
    end

    test "matches checksum-cased EVM addresses against the lowercased intent" do
      checksummed =
        request("0xF39Fd6e51aad88F6F4ce6aB8827279cffFb92266",
          from_token: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
          to_token: "0xaf88d065e77c8cC2239327C5EDb3A432268e5831"
        )

      quote_resp = intent_quote(checksummed)
      assert quote_resp.eip712_data["message"]["wallet"] == String.downcase(checksummed.wallet)
      assert :ok = Xochi.validate_intent(quote_resp, checksummed)
    end

    test "compares a cross-VM base58 recipient verbatim" do
      tron = "TJRabPrwbZy45sbavfcjinPJC18kjpRTv8"
      req = request(@signer_addr, recipient_address: tron)

      assert :ok = Xochi.validate_intent(intent_quote(req), req)

      lowered = intent_quote(req, message: %{"recipient" => String.downcase(tron)})
      assert_refused(lowered, req, :recipient)
    end

    test "exact_output binds toAmount to output_amount and caps fromAmount at max_from_amount" do
      req =
        request(@signer_addr,
          swap_kind: "exact_output",
          from_amount: nil,
          output_amount: "990000",
          max_from_amount: "1100000"
        )

      assert :ok = Xochi.validate_intent(intent_quote(req, from_amount: "1050000"), req)
      assert :ok = Xochi.validate_intent(intent_quote(req, from_amount: "1100000"), req)

      assert_refused(intent_quote(req, from_amount: "1100001"), req, :from_amount)

      # Top-level and signed toAmount agree, but not with what was asked for.
      short = intent_quote(req, from_amount: "1050000", to_amount: "980000")
      assert_refused(short, req, :to_amount)

      no_max = %{req | max_from_amount: nil}
      assert_refused(intent_quote(req, from_amount: "1050000"), no_max, :max_from_amount)
    end

    test "exact_output caps the origin pull value at max_from_amount" do
      req =
        request(@signer_addr,
          swap_kind: "exact_output",
          from_amount: nil,
          output_amount: "990000",
          max_from_amount: "1100000"
        )

      pull_quote = fn value ->
        %{
          intent_quote(req, from_amount: "1050000")
          | payment_method: "erc3009",
            pull_authorization:
              canonical_erc3009_pull(%{message: %{"from" => @signer_addr, "value" => value}})
        }
      end

      assert {:ok, %{pull_signature: "0x" <> _}} =
               Xochi.sign_intent(pull_quote.("1100000"), SignerWallet, req)

      assert {:error, {:authorization_mismatch, :pull_value}} =
               Xochi.sign_intent(pull_quote.("1100001"), NotifyingWallet, req)

      refute_received :signed
    end
  end

  describe "execute_signed/2 (storefront relay)" do
    # raxol as pure storefront: it relays the BUYER's pre-signed intent without
    # re-signing. There is no wallet argument -- raxol never touches the transfer
    # funds; Riddler verifies the signature against its own persisted quote.
    test "relays the buyer's signed bundle verbatim, without a wallet" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute_signed(config, signed_bundle())
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)

      assert body["intent_id"] == "xi_" <> String.duplicate("a", 32)
      assert body["quote_id"] == "xq_" <> String.duplicate("b", 32)
      assert body["signature"] == "0x" <> String.duplicate("11", 65)
      assert body["pull_signature"] == "0x" <> String.duplicate("22", 65)
      assert body["nonce"] == 7
    end

    test "omits pull_signature for a non-pull bundle" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = Map.delete(signed_bundle(), :pull_signature)

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      refute Map.has_key?(Jason.decode!(raw_body), "pull_signature")
    end

    test "accepts a string-keyed bundle (as decoded from an ACP requirement)" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = %{
        "intent_id" => "xi_str",
        "quote_id" => "xq_str",
        "signature" => "0x" <> String.duplicate("33", 65),
        "nonce" => 9
      }

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      body = Jason.decode!(raw_body)
      assert body["intent_id"] == "xi_str"
      assert body["nonce"] == 9
    end

    test "passes through an aztec_proof for a shielded claim" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      bundle = signed_bundle(%{aztec_proof: "0x" <> String.duplicate("ab", 64)})

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw_body}
      assert Jason.decode!(raw_body)["aztec_proof"] == "0x" <> String.duplicate("ab", 64)
    end

    test "fails closed on a missing or malformed field, before any network call" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      for field <- [:intent_id, :quote_id, :signature] do
        bundle = Map.delete(signed_bundle(), field)
        assert {:error, {:invalid_signed_intent, ^field}} = Xochi.execute_signed(config, bundle)
      end

      # nonce must be a non-negative integer (the worker's replay-dedup key); a
      # numeric string or a negative value is rejected, not coerced.
      assert {:error, {:invalid_signed_intent, :nonce}} =
               Xochi.execute_signed(config, signed_bundle(%{nonce: -1}))

      assert {:error, {:invalid_signed_intent, :nonce}} =
               Xochi.execute_signed(config, signed_bundle(%{nonce: "7"}))

      # an empty signature is not a signature
      assert {:error, {:invalid_signed_intent, :signature}} =
               Xochi.execute_signed(config, signed_bundle(%{signature: ""}))

      refute_received {:req, "POST", "/api/intent/execute", _h, _b}
    end
  end

  describe "sign_intent/3 (buyer-side: quote -> sign -> bundle, no execute)" do
    test "returns a relayable bundle and does not POST execute" do
      quote_resp = intent_quote(request(@signer_addr))

      # No config, no network -- sign_intent never talks to the worker.
      assert {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet, request(@signer_addr))
      assert bundle.intent_id == quote_resp.intent_id
      assert bundle.quote_id == quote_resp.quote_id
      assert bundle.nonce == 0
      assert is_binary(bundle.signature)
      assert String.starts_with?(bundle.signature, "0x")
      # No pull authorization in this quote -> no pull_signature key.
      refute Map.has_key?(bundle, :pull_signature)
    end

    test "the signed bundle relays verbatim through execute_signed" do
      quote_resp = intent_quote(request(@signer_addr))
      {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet, request(@signer_addr))

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, raw}
      body = Jason.decode!(raw)
      assert body["signature"] == bundle.signature
      assert body["nonce"] == 0
      assert body["intent_id"] == quote_resp.intent_id
      assert body["quote_id"] == quote_resp.quote_id
    end

    test "sign_intent + execute_signed produces the same POST as execute" do
      # The extracted sign half composes back into the full execute: relaying the
      # signed bundle yields byte-for-byte the request execute/4 would send.
      quote_resp = intent_quote(request(@signer_addr))

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, SignerWallet, request(@signer_addr))
      assert_receive {:req, "POST", "/api/intent/execute", _h, direct_body}

      {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet, request(@signer_addr))
      assert {:ok, _} = Xochi.execute_signed(config, bundle)
      assert_receive {:req, "POST", "/api/intent/execute", _h, relayed_body}

      assert Jason.decode!(direct_body) == Jason.decode!(relayed_body)
    end

    test "includes pull_signature when the quote carries an origin pull" do
      pull = canonical_erc3009_pull(%{message: %{"from" => @signer_addr}})

      quote_resp = %QuoteResponse{
        intent_id: "xi_pull",
        quote_id: "xq_pull",
        can_solve: true,
        payment_method: "erc3009",
        to_amount: "990000",
        eip712_data: intent_eip712(@signer_addr),
        pull_authorization: pull
      }

      request = request(@signer_addr)

      assert {:ok, bundle} = Xochi.sign_intent(quote_resp, SignerWallet, request)
      assert is_binary(bundle.pull_signature)
      assert String.starts_with?(bundle.pull_signature, "0x")
    end

    test "rejects a quote that cannot be solved, without signing" do
      quote_resp = %QuoteResponse{
        intent_id: "i",
        quote_id: "q",
        can_solve: false,
        error: "no liquidity"
      }

      assert {:error, {:cannot_solve, "no liquidity"}} =
               Xochi.sign_intent(quote_resp, SignerWallet, request(@signer_addr))
    end
  end

  describe "quote_and_sign/3 (buyer-side one-shot)" do
    test "fetches a quote then signs it into a relayable bundle" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [
          plug: fn conn ->
            {body, conn} = XochiIntentFixture.quote_body(conn)

            json_plug(%{
              "intentId" => "xi_qs",
              "quoteId" => "xq_qs",
              "canSolve" => true,
              "toAmount" => "990000",
              "eip712Data" => XochiIntentFixture.eip712(body, "990000")
            }).(conn)
          end
        ]
      }

      request = request(@signer_addr)

      assert {:ok, bundle} = Xochi.quote_and_sign(config, request, SignerWallet)
      assert bundle.intent_id == "xi_qs"
      assert bundle.quote_id == "xq_qs"
      assert bundle.nonce == 0
      assert is_binary(bundle.signature)
    end

    test "refuses to sign a quote whose intent diverges from the request" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [
          plug: fn conn ->
            {body, conn} = XochiIntentFixture.quote_body(conn)

            json_plug(%{
              "intentId" => "xi_qs",
              "quoteId" => "xq_qs",
              "canSolve" => true,
              "toAmount" => "990000",
              "eip712Data" =>
                XochiIntentFixture.eip712(body, "990000",
                  message: %{"recipient" => "0x000000000000000000000000000000000000dEaD"}
                )
            }).(conn)
          end
        ]
      }

      assert {:error, {:intent_mismatch, :recipient}} =
               Xochi.quote_and_sign(config, request(@signer_addr), NotifyingWallet)

      refute_received :signed
    end
  end

  describe "execute/4 domain parity" do
    setup :put_real_wallet_key

    test "derives a unique execute nonce from the pull authorization's bytes32 nonce" do
      # The served XochiIntent carries no nonce, and the worker dedups replays on
      # the execute nonce, so it must be unique per intent -- a constant 0 makes the
      # worker reject the wallet's second non-terminal intent. Derived from the low
      # 48 bits of the pull's server-issued nonce. High bytes 0xaa with low 6 bytes
      # 0xffffffffffff prove only the low 48 bits are taken.
      pull =
        canonical_erc3009_pull(%{
          message: %{"nonce" => "0x" <> String.duplicate("aa", 26) <> "ffffffffffff"}
        })

      quote_resp = %QuoteResponse{
        intent_id: "xi_pullnonce",
        quote_id: "xq_pullnonce",
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
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      assert Jason.decode!(raw_body)["nonce"] == 281_474_976_710_655
    end

    test "derives the execute nonce from a Permit2 pull's decimal uint256 nonce" do
      # Permit2 serves its nonce as a decimal uint256 string; read as hex it
      # would decode to nothing or to the wrong value and lose the uniqueness
      # the worker's dedup needs.
      Application.put_env(:raxol_payments, :pull_solver_allowlist, [permit2_spender()])
      on_exit(fn -> Application.delete_env(:raxol_payments, :pull_solver_allowlist) end)

      for nonce <- [
            "112114396471705291941186730714163110958588040774957772672265374070195054391013",
            "11211439647170529194118673071416311095858804077495777267226537407019505439101"
          ] do
        pull =
          canonical_permit2_pull(%{
            message: %{"spender" => permit2_spender(), "nonce" => nonce}
          })

        quote_resp = %QuoteResponse{
          intent_id: "xi_p2nonce",
          quote_id: "xq_p2nonce",
          can_solve: true,
          payment_method: "permit2",
          to_amount: "990000",
          eip712_data: intent_eip712(anvil_addr()),
          pull_authorization: pull
        }

        config = %{
          base_url: "https://api.xochi.fi",
          auth: :none,
          req_options: [plug: echo_plug(self())]
        }

        assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request(anvil_addr()))
        assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}

        assert Jason.decode!(raw_body)["nonce"] ==
                 Bitwise.band(String.to_integer(nonce), Bitwise.bsl(1, 48) - 1)
      end
    end

    test "signs the served v3 domain verbatim: name, version, chainId, salt" do
      # Canonical XochiIntent domain (SPEC §2.2) has no verifyingContract and a
      # salt of keccak256(version); a deployment-scoped version keeps the v3 major.
      domain = %{
        "name" => "Xochi",
        "version" => "3-prod",
        "chainId" => 8453,
        "salt" => "0x9367b434237c76dd65474f6b3400f245656f312be16268d772cec464857dc759"
      }

      quote_resp = intent_quote(request(anvil_addr()), domain: domain)

      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request(anvil_addr()))
      assert_receive {:req, "POST", "/api/intent/execute", _headers, raw_body}
      sent_sig = Jason.decode!(raw_body)["signature"]

      {:ok, raw} =
        RealWallet.sign_typed_data(
          build_domain(domain),
          intent_types(quote_resp),
          intent_message(quote_resp)
        )

      assert sent_sig == "0x" <> Base.encode16(raw, case: :lower)
    end

    test "refuses a domain that is not the v3 XochiIntent domain" do
      salt3 = "0x2a80e1ef1d7842f27f2e6be0972bb708b9a135c38860dbe73c27c3486c34f4de"
      base = %{"name" => "Xochi", "version" => "3", "chainId" => 8453, "salt" => salt3}
      vc = "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

      for {domain, field} <- [
            {Map.put(base, "verifyingContract", vc), :fields},
            {Map.delete(base, "salt"), :fields},
            {%{base | "name" => "USD Coin"}, :name},
            {%{base | "version" => "2"}, :version},
            {%{base | "chainId" => 1}, :chain_id},
            {%{base | "salt" => "0x" <> String.duplicate("00", 32)}, :salt}
          ] do
        quote_resp = intent_quote(request(anvil_addr()), domain: domain)

        assert {:error, {:intent_mismatch, {:intent_domain, got}}} =
                 Xochi.sign_intent(quote_resp, NotifyingWallet, request(anvil_addr()))

        assert got == field or (field == :version and got == :salt),
               "domain #{inspect(domain)}: expected #{field}, got #{got}"

        refute_received :signed
      end
    end

    property "signs the canonical typed data for any served v3 domain" do
      config = %{
        base_url: "https://api.xochi.fi",
        auth: :none,
        req_options: [plug: echo_plug(self())]
      }

      check all(
              domain <- domain_gen(),
              intent_id <- StreamData.map(hex_gen(32), &("xi_" <> &1)),
              wallet <- address_gen()
            ) do
        request = request(wallet)

        quote_resp = intent_quote(request, domain: domain, intent_id: intent_id)

        assert {:ok, _} = Xochi.execute(config, quote_resp, RealWallet, request)
        assert_receive {:req, "POST", "/api/intent/execute", _h, body}
        decoded = Jason.decode!(body)

        # 1. the execute nonce is 0: v3 signs none and the quote has no pull
        assert decoded["nonce"] == 0

        # 2. the signature is over the canonically-rebuilt typed data (the exact
        #    domain/types/message the worker and solver hash). Built independently
        #    of the protocol's own construction so a regression diverges the sig.
        {:ok, raw} =
          RealWallet.sign_typed_data(
            build_domain(domain),
            intent_types(quote_resp),
            intent_message(quote_resp)
          )

        assert decoded["signature"] == "0x" <> Base.encode16(raw, case: :lower)
      end
    end
  end

  defp hex_gen(len), do: StreamData.string([?0..?9, ?a..?f], length: len)

  defp address_gen, do: StreamData.map(hex_gen(40), &("0x" <> &1))

  # SPEC §2.2 v3 domains: a v3 version, bare or deployment-scoped, its salt
  # keccak256(version), on the request's origin chain (8453 in `request/1`).
  defp domain_gen do
    StreamData.map(StreamData.member_of(["3", "3-prod", "3-staging", "3-axol-prod"]), fn v ->
      %{
        "name" => "Xochi",
        "version" => v,
        "chainId" => 8453,
        "salt" => "0x" <> Base.encode16(ExKeccak.hash_256(v), case: :lower)
      }
    end)
  end

  # Canonical EIP-712 domain: only the keys the server actually served, atom-keyed.
  defp build_domain(d) do
    base = %{name: d["name"], version: d["version"], chainId: d["chainId"]}

    base
    |> then(
      &if(d["verifyingContract"],
        do: Map.put(&1, :verifyingContract, d["verifyingContract"]),
        else: &1
      )
    )
    |> then(&if(d["salt"], do: Map.put(&1, :salt, d["salt"]), else: &1))
  end

  # validate_intent/2 and sign_intent/3 both refuse with `field`; nothing signed.
  defp assert_refused(quote_resp, request, field) do
    assert {:error, {:intent_mismatch, ^field}} = Xochi.validate_intent(quote_resp, request)

    assert {:error, {:intent_mismatch, ^field}} =
             Xochi.sign_intent(quote_resp, NotifyingWallet, request)

    refute_received :signed
  end

  # A solvable quote whose signed intent matches `request` (`opts` are
  # XochiIntentFixture.eip712/3 options plus :to_amount).
  defp intent_quote(%QuoteRequest{} = request, opts \\ []) do
    to_amount = Keyword.get(opts, :to_amount, request.output_amount || "990000")

    %QuoteResponse{
      intent_id: Keyword.get(opts, :intent_id, "xi_" <> String.duplicate("a", 32)),
      quote_id: "xq_" <> String.duplicate("b", 32),
      can_solve: true,
      to_amount: to_amount,
      eip712_data: XochiIntentFixture.eip712(request, to_amount, Keyword.delete(opts, :to_amount))
    }
  end

  defp intent_types(%QuoteResponse{eip712_data: eip712}) do
    %{"XochiIntent" => Enum.map(eip712["types"]["XochiIntent"], &{&1["name"], &1["type"]})}
  end

  defp intent_message(%QuoteResponse{eip712_data: eip712}), do: eip712["message"]

  # A buyer-signed intent bundle, as handed to the storefront relay. raxol
  # relays it verbatim; there is no wallet in execute_signed/2. Signature values
  # are opaque (Riddler verifies them against its persisted quote).
  defp signed_bundle(overrides \\ %{}) do
    Map.merge(
      %{
        intent_id: "xi_" <> String.duplicate("a", 32),
        quote_id: "xq_" <> String.duplicate("b", 32),
        signature: "0x" <> String.duplicate("11", 65),
        nonce: 7,
        pull_signature: "0x" <> String.duplicate("22", 65)
      },
      overrides
    )
  end

  # Serves a fixed JSON body on any path (used to stub a quote response).
  defp json_plug(json) do
    fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(json))
    end
  end
end
