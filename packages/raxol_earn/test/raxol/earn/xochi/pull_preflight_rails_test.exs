defmodule Raxol.Earn.Xochi.PullPreflightRailsTest do
  # The ERC-3009 rail, a bundle the production signer produced, and
  # describe/1. Fixtures in Raxol.Earn.Test.PullPreflightCase.
  use Raxol.Earn.Test.PullPreflightCase, async: true

  alias Raxol.Earn.Xochi.PullPreflight
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  # Permit2's live Base DOMAIN_SEPARATOR, and the universal deployment it is
  # read from. Hardcoding the real value is what makes the fake chain (PullPreflightCase) an
  # ORACLE rather than a restatement: it is the 32 bytes the contract actually
  # rebuilds, taken from chain, not from our own domain construction.
  @permit2_separator Base.decode16!(
                       "3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07",
                       case: :lower
                     )
  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @spender "0x000000000000000000000000000000000000dEaD"

  @owner "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @usdc_arbitrum "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  @hostile "0x00000000000000000000000000000000000badc0"

  # The other rail. `Mix.Tasks.RaxolEarn.Order.expected_verifier/2` pins this one
  # to `cfg.src_token` rather than to a universal address, and the live ACP gate
  # reaches it with a funded EOA -- so a gate that blocks funded runs on it had
  # no test for it at all until these.
  describe "the ERC-3009 rail" do
    test "accepts a pull whose verifier is the origin token itself" do
      served = served_erc3009_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_base
               )

      assert details.verifying_contract == @usdc_base
      assert details.signer_kind == :eoa
    end

    # The versioned-domain defect on this rail, in the direction it would appear:
    # the token declares a `version` and the signer drops it, so the separator
    # the token rebuilds is not the one the signature covers. Nothing in the
    # payload looks wrong -- only the chain-sourced separator tells them apart.
    test "rejects a signature that dropped the version the token declares" do
      served = served_erc3009_pull()

      versionless =
        served["domain"]
        |> Map.delete("version")
        |> then(
          &%{name: &1["name"], chainId: &1["chainId"], verifyingContract: &1["verifyingContract"]}
        )

      {:ok, digest} =
        EIP712.hash(versionless, XochiProtocol.eip712_types(served), served["message"])

      assert {:rejected, details} =
               verify(served, sign_over(digest), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_base
               )

      refute details.returned == @owner
    end

    # The pin is the destination token, not the origin one. Getting the leg
    # backwards is a plausible caller bug, and it must not read as a signing
    # defect: the served address is named, so the log says which is which.
    test "refuses a pull pinned to the wrong side of the corridor" do
      served = served_erc3009_pull()

      assert {:rejected, %{reason: {:verifier_mismatch, @usdc_base, @usdc_arbitrum}}} =
               verify(served, current_signature(served), @owner,
                 rpc: erc3009_chain(served),
                 expect_verifier: @usdc_arbitrum
               )
    end

    # An ERC-3009 pull on a contract buyer goes through ERC-1271 exactly as the
    # Permit2 one does -- the branch is decided by the ACCOUNT's code, never by
    # the rail.
    test "a contract buyer on this rail is asked via ERC-1271, not recovery" do
      served = served_erc3009_pull()

      chain =
        chain(
          code: "0xef0100" <> String.duplicate("11", 20),
          foreign_separator: separator_for(served["domain"])
        )

      assert {:ok, details} =
               verify(served, current_signature(served), @account,
                 rpc: chain,
                 expect_verifier: @usdc_base
               )

      assert details.signer_kind == :contract
    end
  end

  # Every other test in this file signs with a digest the test builds. That is
  # fine for proving the checker distinguishes two digests, and useless for
  # proving it agrees with the thing that will actually sign in production.
  # Here the bundle comes out of
  # `Xochi.sign_intent/3` itself, so a divergence anywhere in the real signing
  # path (domain projection, types projection, pull selection) fails this.
  describe "against a bundle the production signer produced" do
    defmodule ProdWallet do
      @moduledoc false
      use Raxol.Payments.Wallets.Env, env_var: "RAXOL_PULL_PREFLIGHT_TEST_KEY"
    end

    setup do
      System.put_env(
        "RAXOL_PULL_PREFLIGHT_TEST_KEY",
        "0xac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80"
      )

      Application.put_env(:raxol_payments, :pull_solver_allowlist, [@spender])

      on_exit(fn ->
        System.delete_env("RAXOL_PULL_PREFLIGHT_TEST_KEY")
        Application.delete_env(:raxol_payments, :pull_solver_allowlist)
      end)

      :ok
    end

    test "accepts the pull signature sign_intent/3 actually emits" do
      served = live_pull()

      {:ok, bundle} =
        XochiProtocol.sign_intent(quote_response(served), ProdWallet, quote_request())

      assert {:ok, details} =
               verify(served, bundle[:pull_signature], @owner,
                 rpc: chain(code: "0x"),
                 expect_verifier: @permit2_address
               )

      assert details.separator == @permit2_separator
      assert details.signer_kind == :eoa
    end

    # The same bundle, checked against a separator that is not Permit2's. If this
    # passed, the one above would be proving nothing about the domain.
    test "and rejects it against a verifier that rebuilds a different domain" do
      served = live_pull()

      {:ok, bundle} =
        XochiProtocol.sign_intent(quote_response(served), ProdWallet, quote_request())

      other = %{served["domain"] | "chainId" => 8453, "name" => "NotPermit2"}

      assert {:rejected, _} =
               verify(served, bundle[:pull_signature], @owner,
                 rpc: chain(code: "0x", foreign_separator: separator_for(other)),
                 expect_verifier: @hostile
               )
    end

    # The fixture's fixed deadline is months out and would silently start failing
    # `valid_window?` on its own schedule. Only this describe block signs through
    # the validator, so only this block needs a live one.
    defp live_pull do
      deadline = Integer.to_string(System.system_time(:second) + 3600)
      update_in(served_pull(), ["message"], &Map.put(&1, "deadline", deadline))
    end

    defp intent_fields do
      for {name, type} <- [
            {"intentId", "string"},
            {"quoteId", "string"},
            {"wallet", "address"},
            {"recipient", "string"},
            {"fromChainId", "uint256"},
            {"toChainId", "uint256"},
            {"fromToken", "string"},
            {"toToken", "string"},
            {"fromAmount", "uint256"},
            {"toAmount", "uint256"},
            {"settlementPreference", "string"},
            {"deadline", "uint256"}
          ],
          do: %{"name" => name, "type" => type}
    end

    defp quote_response(served) do
      req = quote_request()

      %QuoteResponse{
        intent_id: "xi_prod",
        quote_id: "xq_prod",
        can_solve: true,
        payment_method: "permit2",
        to_amount: "2990000",
        eip712_data: %{
          "domain" => %{
            "name" => "Xochi",
            "version" => "3",
            "chainId" => 8453,
            "salt" => "0x" <> Base.encode16(ExKeccak.hash_256("3"), case: :lower)
          },
          "primaryType" => "XochiIntent",
          "types" => %{
            "XochiIntent" => intent_fields()
          },
          "message" => %{
            "intentId" => "xi_prod",
            "quoteId" => "xq_prod",
            "wallet" => String.downcase(req.wallet),
            "recipient" => req.wallet,
            "fromChainId" => req.from_chain_id,
            "toChainId" => req.to_chain_id,
            "fromToken" => req.from_token,
            "toToken" => req.to_token,
            "fromAmount" => req.from_amount,
            "toAmount" => "2990000",
            "settlementPreference" => "public",
            "deadline" => System.system_time(:second) + 300
          }
        },
        pull_authorization: served
      }
    end

    defp quote_request do
      %QuoteRequest{
        wallet: @owner,
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
        to_token: "0xaf88d065e77c8cc2239327c5edb3a432268e5831",
        from_amount: "3000000",
        settlement_preference: "public"
      }
    end
  end

  describe "describe/1" do
    test "a rejection says the pull would revert and funding would strand a fee" do
      served = served_pull()

      line =
        served
        |> verify(versioned_domain_signature(served), @account, rpc: chain())
        |> PullPreflight.describe()

      assert line =~ "REJECTED"
      assert line =~ "would revert"
    end

    test "a payload defect reads as a rejection, not as a check that could not run" do
      line = PullPreflight.describe({:rejected, %{reason: :no_verifying_contract}})

      assert line =~ "REJECTED"
      assert line =~ "declares no domain.verifyingContract"
      refute line =~ "could not run"
    end

    test "an unreadable chainId is not described as a missing one" do
      line = PullPreflight.describe({:rejected, %{reason: {:invalid_chain_id, -1}}})

      assert line =~ "REJECTED"
      assert line =~ "domain.chainId is not a chain id"
      refute line =~ "declares no domain.chainId"
    end

    test "a bad recovery id is not described as a length problem" do
      line =
        PullPreflight.describe({:rejected, %{reason: {:recover_failed, {:non_canonical_v, 1}}}})

      assert line =~ "recovery id is 1"
      # The defect that DOES warrant the 7702 advice is the wrapped envelope,
      # and conflating the two sent operators after the wrong thing.
      refute line =~ "7702"
      refute line =~ "bytes rather than"
    end

    test "a wrapped envelope still reads as a length problem worth checking 7702 for" do
      line =
        PullPreflight.describe(
          {:rejected, %{reason: {:recover_failed, {:not_a_canonical_signature, 72}}}}
        )

      assert line =~ "72 bytes rather than"
      assert line =~ "7702"
      # Both accepted lengths are named. Saying "a canonical 65" alone was wrong
      # once the compact 64-byte form started being accepted, and an operator
      # holding a 64-byte signature would have read it as confirmation.
      assert line =~ "65"
      assert line =~ "64"
    end

    test "an inconclusive check does not claim the signature is bad" do
      line =
        PullPreflight.describe({:inconclusive, {:domain_separator_unavailable, "0x0", :timeout}})

      assert line =~ "INCONCLUSIVE"
      assert line =~ "not a verdict"
    end

    test "a wrong-chain RPC names the CHAIN to fix rather than blaming the signature" do
      line = PullPreflight.describe({:inconclusive, {:wrong_chain, declared: 8453, node: 42_161}})

      assert line =~ "INCONCLUSIVE"
      assert line =~ "not a verdict"
      assert line =~ "chain 8453"
      assert line =~ "ORIGIN-chain endpoint"
    end

    # Two callers reach this with different variables -- `mix raxol_earn.order`
    # reads ORDER_RPC_<chain>, the live gate reads XOCHI_ORDER_RPC_<chain> -- so
    # a name hardcoded here is wrong in one of them. It named ORDER_RPC_<chain>,
    # which is the one the live gate does NOT use, and pointing an operator at a
    # variable that does not exist is the exact failure this module was built to
    # stop. Each caller names its own knob in its own error text.
    test "no gap message hardcodes a caller's environment variable" do
      gaps = [
        {:wrong_chain, declared: 8453, node: 42_161},
        {:chain_id_unavailable, :timeout},
        {:domain_separator_unavailable, "0x0", :timeout},
        {:domain_separator_length, 8},
        {:signer_kind_unavailable, "0x0", :timeout},
        {:erc1271_call_failed, "0x0", :timeout}
      ]

      for gap <- gaps do
        line = PullPreflight.describe({:inconclusive, gap})
        refute line =~ "ORDER_RPC", "#{inspect(gap)} names an env var only one caller has"
      end
    end
  end
end
