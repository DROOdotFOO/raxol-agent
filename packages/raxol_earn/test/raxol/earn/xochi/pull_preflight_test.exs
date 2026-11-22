defmodule Raxol.Earn.Xochi.PullPreflightTest do
  # The Permit2 rail: verify/4, a reverting isValidSignature, and a types map
  # the encoder cannot take. Fixtures in Raxol.Earn.Test.PullPreflightCase.
  use Raxol.Earn.Test.PullPreflightCase, async: true

  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Earn.Xochi.PullPreflight

  # Permit2's live Base DOMAIN_SEPARATOR, and the universal deployment it is
  # read from. Hardcoding the real value is what makes the fake chain (PullPreflightCase) an
  # ORACLE rather than a restatement: it is the 32 bytes the contract actually
  # rebuilds, taken from chain, not from our own domain construction.
  @permit2_separator Base.decode16!(
                       "3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07",
                       case: :lower
                     )
  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"

  @owner "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"

  @hostile "0x00000000000000000000000000000000000badc0"

  describe "verify/4" do
    test "accepts a pull signed over Permit2's own domain separator" do
      served = served_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @account, rpc: chain())

      assert details.separator == @permit2_separator
      assert details.verifying_contract == @permit2_address
      assert details.signer_kind == :contract
    end

    test "verifies an EOA buyer by recovery, since it has no isValidSignature to call" do
      # The live ACP gate's buyer is a plain funded key, where Permit2 does
      # ecrecover rather than an ERC-1271 call. Same digest, different check.
      served = served_pull()

      assert {:ok, details} =
               verify(served, current_signature(served), @owner, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
    end

    test "rejects an EOA signature that recovers to someone else, naming who" do
      served = served_pull()

      assert {:rejected, details} =
               verify(served, current_signature(served), @account, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
      assert details.returned == @owner
    end

    test "rejects the pre-#878 signature for an EOA buyer too" do
      # The domain defect was never specific to smart accounts. It only
      # SURFACED there, because EOA buyers resolved to erc3009 and never took
      # the Permit2 path at all.
      served = served_pull()

      assert {:rejected, details} =
               verify(served, pre_878_signature(served), @owner, rpc: chain(code: "0x"))

      assert details.signer_kind == :eoa
      refute details.returned == @owner
    end

    test "rejects the pre-#878 signature that reverted InvalidContractSignature on Base" do
      # The regression that matters. The old projection declared a `version`
      # Permit2's domain does not carry, so the buyer signed a 4-field separator
      # against Permit2's 3-field one. Nothing in the buyer's own suite could see
      # it, because every check rebuilt the domain the same wrong way. Reading
      # the separator from the contract is what makes it visible here.
      served = served_pull()

      assert {:rejected, details} =
               verify(served, pre_878_signature(served), @account, rpc: chain())

      assert details.returned == <<0xFF, 0xFF, 0xFF, 0xFF>>
      assert details.separator == @permit2_separator
    end

    test "the two signatures genuinely differ, so the pass above is not vacuous" do
      served = served_pull()
      refute current_signature(served) == pre_878_signature(served)
    end

    test "a served domain with no verifyingContract is a rejection, not a gap" do
      # Nothing on chain claims to verify this, so no signature over it can pass.
      # Reporting that as inconclusive is what let #772's defect class through a
      # gate built to catch it: the run read "could not check" and funded anyway.
      served = Map.put(served_pull(), "domain", %{"name" => "Xochi", "chainId" => 8453})

      assert {:rejected, %{reason: :no_verifying_contract}} =
               verify(served, "0x00", @account, rpc: chain())
    end

    test "a permit2 pull is refused when the quote nominates its own verifier" do
      # The oracle must not be chosen by the party under audit. A hostile worker
      # serving a contract it controls could answer DOMAIN_SEPARATOR() with
      # whatever makes our own projection agree -- and the allowance being spent
      # was granted to the canonical Permit2, which is where the pull runs.
      hostile = "0x00000000000000000000000000000000000badc0"

      served =
        update_in(served_pull(), ["domain"], &Map.put(&1, "verifyingContract", hostile))

      assert {:rejected, %{reason: {:verifier_mismatch, ^hostile, _expected}}} =
               verify(served, current_signature(served), @account, rpc: chain())
    end

    # Every default available here would be drawn from the payload under audit,
    # so there is no default. Omitting the pin used to fall back to one keyed on
    # the served `primaryType` -- also chosen by the party that served it -- and
    # a payload declaring some other primary type walked straight past it.
    test "refuses to run at all without :expect_verifier" do
      {served, chain} = hostile_verifier()

      assert_raise ArgumentError, ~r/:expect_verifier is required/, fn ->
        PullPreflight.verify(served, current_signature(served), @account, rpc: chain)
      end
    end

    test "refuses an :expect_verifier that is not an address" do
      {served, chain} = hostile_verifier()

      for bad <- [:permit2, nil, 42, "permit2"] do
        assert_raise ArgumentError, ~r/must be a 0x address/, fn ->
          PullPreflight.verify(served, current_signature(served), @account,
            rpc: chain,
            expect_verifier: bad
          )
        end
      end
    end

    # The whole payload is internally consistent -- the signature really does
    # cover the digest that address really will rebuild. Only the caller's pin
    # tells the two apart.
    test ":expect_verifier pins the oracle regardless of what the payload declares" do
      {served, chain} = hostile_verifier()

      assert {:rejected, %{reason: {:verifier_mismatch, @hostile, @permit2_address}}} =
               verify(served, current_signature(served), @account,
                 rpc: chain,
                 expect_verifier: @permit2_address
               )
    end

    test ":expect_verifier accepts the address the rail actually pulls through" do
      served = served_pull()

      assert {:ok, _details} =
               verify(served, current_signature(served), @account,
                 rpc: chain(),
                 expect_verifier: String.downcase(@permit2_address)
               )
    end

    # `normalize_address/1` trims and downcases, so a served verifyingContract
    # can pass the pin while differing from it byte for byte. Carrying the
    # SERVED spelling forward meant `eth_call` was asked about the payload's copy
    # of the address -- and a served `"0x…BA3 "` reached the node as an invalid
    # `to:`, stopping every funded run INCONCLUSIVE while blaming an endpoint
    # that was fine. The pin is what gets dialed.
    test "the pinned verifier is what gets dialed, not the served spelling of it" do
      {:ok, asked} = Agent.start_link(fn -> [] end)

      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        result =
          case req["method"] do
            "eth_chainId" ->
              "0x2105"

            "eth_getCode" ->
              "0x"

            "eth_call" ->
              [%{"to" => to} | _] = req["params"]
              Agent.update(asked, &[to | &1])
              "0x" <> Base.encode16(@permit2_separator, case: :lower)
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
        )
      end

      # Same address, different spelling: passes the pin, is not the pin.
      served =
        update_in(
          served_pull(),
          ["domain"],
          &Map.put(&1, "verifyingContract", String.downcase(@permit2_address))
        )

      assert {:ok, details} =
               verify(served, current_signature(served), @owner,
                 rpc: RPC.client(url: "http://stub.invalid/rpc", plug: plug),
                 expect_verifier: @permit2_address
               )

      assert details.verifying_contract == @permit2_address
      assert Agent.get(asked, & &1) == [@permit2_address]
    end

    # A chainId that is present but unreadable is a different defect from one
    # that is absent, and describing it as absent sends the operator looking for
    # a field that is right there in the payload they captured.
    test "a chainId that is present but unreadable is its own rejection" do
      for bad <- [-1, "not-a-chain", 1.5, %{}] do
        served = update_in(served_pull(), ["domain"], &Map.put(&1, "chainId", bad))

        assert {:rejected, %{reason: {:invalid_chain_id, ^bad}}} =
                 verify(served, "0x00", @account, rpc: chain())
      end
    end

    test "a chainId that is absent is still reported as absent" do
      served = update_in(served_pull(), ["domain"], &Map.delete(&1, "chainId"))

      assert {:rejected, %{reason: :no_chain_id}} =
               verify(served, "0x00", @account, rpc: chain())
    end

    # This module and `Protocols.Xochi` both parse domain.chainId, and they now
    # agree on what a value is. Nothing reaches here that they disagree about --
    # `EIP712` refuses a padded uint256 at signing, several steps earlier -- so
    # this pins the agreement rather than a live divergence.
    test "a chainId string parses the way the signing gate parses it" do
      served = update_in(served_pull(), ["domain"], &Map.put(&1, "chainId", "8453"))

      assert {:ok, _details} =
               verify(served, current_signature(served), @account, rpc: chain())
    end

    test "an unrecoverable signature on a codeless account is a rejection" do
      # Permit2 recovers this same signature against this same account, so a
      # signature that cannot be recovered here cannot be recovered there. This
      # is the 7702 case: a wrapped envelope on an account whose delegation is
      # not actually set has nothing to unwrap it.
      served = served_pull()
      wrapped = "0x" <> String.duplicate("ab", 72)

      assert {:rejected, %{reason: {:recover_failed, {:not_a_canonical_signature, 72}}}} =
               verify(served, wrapped, @owner, rpc: chain(code: "0x"))
    end

    test "a 65-byte signature with a non-canonical v is its own rejection reason" do
      # Distinct from the wrapped-envelope case above, and reported separately:
      # collapsing both into a byte count produced "this signature is 65 bytes
      # rather than a canonical 65", which says nothing and then pointed the
      # operator at a 7702 delegation that is not the problem. Solidity's
      # ecrecover yields the zero address for any v outside 27/28, so the pull
      # rejects this too -- for the reason named here.
      served = served_pull()

      "0x" <> hex = current_signature(served)
      <<rs::binary-size(64), _v::8>> = Base.decode16!(hex, case: :lower)
      bad_v = "0x" <> Base.encode16(rs <> <<1>>, case: :lower)

      assert {:rejected, %{reason: {:recover_failed, {:non_canonical_v, 1}}}} =
               verify(served, bad_v, @owner, rpc: chain(code: "0x"))
    end

    test "a signature that is not hex is a rejection, not a gap" do
      served = served_pull()

      assert {:rejected, %{reason: {:invalid_hex, :signature}}} =
               verify(served, "0xnothex", @account, rpc: chain())
    end

    test "an RPC answering for the wrong chain is inconclusive, never a rejection" do
      # Permit2 lives at the same address on every chain with a different
      # separator, so an RPC pointed at the wrong network returns 32 plausible
      # bytes and a CORRECT signature fails to match them. Calling that a
      # rejection would tell the operator their signing is broken when their
      # ORDER_RPC_<chain> is -- and that env var falls back to Base when unset.
      served = served_pull()

      assert {:inconclusive, {:wrong_chain, declared: 8453, node: 42_161}} =
               verify(served, current_signature(served), @account, rpc: chain(chain_id: 42_161))
    end

    test "an unreachable RPC is inconclusive, not a rejection" do
      # A failed check must never read as a verdict: reporting "signature bad"
      # when the node was down would send the next debugging round after the
      # wrong thing, which is how this issue lost two of its four attempts.
      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "upstream down") end
      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:inconclusive, {:chain_id_unavailable, _reason}} =
               verify(served, current_signature(served), @account, rpc: client)
    end

    # EIP-2098: `r || vs`, with the recovery bit in the top position of `vs`.
    # Permit2's SignatureVerification takes this alongside the 65-byte form and
    # the ERC-3009 tokens go through the same library, so refusing it here would
    # be a false REJECTED on a signature the pull would accept -- and the message
    # would point at a 7702 delegation that is not the problem.
    test "accepts a compact 64-byte signature, which the verifier also accepts" do
      served = served_pull()

      "0x" <> hex = current_signature(served)
      <<r::binary-size(32), s::binary-size(32), v::8>> = Base.decode16!(hex, case: :lower)
      <<0::1, s_rest::bitstring>> = s
      compact = "0x" <> Base.encode16(<<r::binary, v - 27::1, s_rest::bitstring>>, case: :lower)

      assert byte_size(Base.decode16!(String.trim_leading(compact, "0x"), case: :lower)) == 64

      assert {:ok, details} = verify(served, compact, @owner, rpc: chain(code: "0x"))
      assert details.signer_kind == :eoa
    end

    test "a compact signature over the WRONG digest is still rejected" do
      served = served_pull()

      "0x" <> hex = pre_878_signature(served)
      <<r::binary-size(32), s::binary-size(32), v::8>> = Base.decode16!(hex, case: :lower)
      <<0::1, s_rest::bitstring>> = s
      compact = "0x" <> Base.encode16(<<r::binary, v - 27::1, s_rest::bitstring>>, case: :lower)

      assert {:rejected, details} = verify(served, compact, @owner, rpc: chain(code: "0x"))
      refute details.returned == @owner
    end

    # `RPC.get_code/3` head-matches `"0x" <> _`, so this used to leave `verify/4`
    # as a FunctionClauseError out of a function that documents three outcomes.
    test "a buyer address that is not an 0x address leaves by one of the three doors" do
      served = served_pull()

      for bad <- ["not-an-address", "", nil, :buyer] do
        assert {:rejected, %{reason: {:invalid_account, ^bad}}} =
                 verify(served, current_signature(served), bad, rpc: chain())
      end
    end

    # A node that ANSWERS with something that is not a separator is a different
    # gap from one that never answered, and folding the two reported garbage on
    # the wire as an endpoint that was down -- sending the operator to check
    # connectivity that is fine.
    test "a separator that comes back unreadable is inconclusive, and says so" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        result = if req["method"] == "eth_chainId", do: "0x2105", else: nil

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
        )
      end

      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:inconclusive, {:domain_separator_malformed, _}} =
               verify(served, current_signature(served), @account, rpc: client)
    end

    test "a separator the endpoint never answers for is its own gap" do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        payload =
          if req["method"] == "eth_chainId" do
            %{"result" => "0x2105"}
          else
            %{"error" => %{"code" => -32_603, "message" => "internal error"}}
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => req["id"]}, payload))
        )
      end

      client = RPC.client(url: "http://stub.invalid/rpc", plug: plug)
      served = served_pull()

      assert {:inconclusive, {:domain_separator_unavailable, _vc, _reason}} =
               verify(served, current_signature(served), @account, rpc: client)
    end
  end

  # The default shape for the account this module was built for. A smart account
  # that REVERTS on a bad signature rather than returning 0xffffffff was read as
  # "the check could not run" -- which stays soft under `--dry-run` and soft in
  # the live gate, so the rehearsal scored PASS on exactly the defect it exists
  # to find. A revert is the account refusing the signature, and the pull calls
  # it the same way, so the pull reverts too.
  describe "an isValidSignature that reverts" do
    # `eth_call` erroring rather than returning: what a reverting contract
    # actually looks like on the wire.
    defp erc1271_error_chain(error) do
      plug = fn conn ->
        {:ok, body, conn} = Plug.Conn.read_body(conn)
        req = Jason.decode!(body)

        payload =
          case req["method"] do
            "eth_chainId" ->
              %{"result" => "0x2105"}

            "eth_getCode" ->
              %{"result" => "0xef0100" <> String.duplicate("11", 20)}

            "eth_call" ->
              [%{"to" => to} | _] = req["params"]

              if String.downcase(to) == String.downcase(@account) do
                %{"error" => error}
              else
                %{"result" => "0x" <> Base.encode16(@permit2_separator, case: :lower)}
              end
          end

        conn
        |> Plug.Conn.put_resp_content_type("application/json")
        |> Plug.Conn.send_resp(
          200,
          Jason.encode!(Map.merge(%{"jsonrpc" => "2.0", "id" => req["id"]}, payload))
        )
      end

      RPC.client(url: "http://stub.invalid/rpc", plug: plug)
    end

    test "is a REJECTION, so the rehearsal fails on it" do
      served = served_pull()

      chain =
        erc1271_error_chain(%{"code" => 3, "message" => "execution reverted", "data" => "0x"})

      assert {:rejected, %{reason: {:erc1271_reverted, _detail}}} =
               verify(served, current_signature(served), @account, rpc: chain)
    end

    # The -32000 range is server-defined, so the message is what says which kind
    # of failure it was.
    test "is recognized in the server-defined error range too" do
      served = served_pull()

      chain =
        erc1271_error_chain(%{
          "code" => -32_000,
          "message" => "execution reverted: InvalidContractSignature()"
        })

      assert {:rejected, %{reason: {:erc1271_reverted, _}}} =
               verify(served, current_signature(served), @account, rpc: chain)
    end

    # The other direction, and the reason this converts only an execution
    # revert. A rate limit is still an RPC error and still says nothing about
    # the signature; a false REJECTED there sends an operator after a signing
    # defect that is not present.
    test "but a rate limit is not a verdict and stays inconclusive" do
      served = served_pull()

      chain =
        erc1271_error_chain(%{"code" => -32_005, "message" => "rate limit exceeded"})

      assert {:inconclusive, {:erc1271_call_failed, _account, _reason}} =
               verify(served, current_signature(served), @account, rpc: chain)
    end

    test "and a node that cannot be reached at all stays inconclusive" do
      served = served_pull()

      plug = fn conn -> Plug.Conn.send_resp(conn, 503, "upstream down") end

      assert {:inconclusive, _} =
               verify(served, current_signature(served), @account,
                 rpc: RPC.client(url: "http://stub.invalid/rpc", plug: plug)
               )
    end

    test "the rejection line names the payload, not the endpoint" do
      line =
        PullPreflight.describe({:rejected, %{reason: {:erc1271_reverted, "execution reverted"}}})

      assert line =~ "REJECTED"
      assert line =~ "REVERTED"
      assert line =~ "this is the payload, not the endpoint"
    end
  end

  # `verify/4` documents exactly three outcomes, and a served payload could
  # break that by RAISING: `EIP712`'s primary-type detection raises when the
  # types map has more than one unreferenced root. The order task never saw it
  # (signing runs the same encoder first), but the live gate calls this once per
  # cell with no rescue, so one malformed payload took down a ninety-cell matrix
  # instead of failing its own cell.
  describe "a served types map the encoder cannot handle" do
    test "leaves by one of the three doors rather than raising" do
      served =
        update_in(served_pull(), ["types"], fn types ->
          Map.put(types, "Orphan", [%{"name" => "x", "type" => "uint256"}])
        end)

      assert {:rejected, %{reason: {:digest_failed, :no_primary_type}}} =
               verify(served, current_signature(served_pull()), @account, rpc: chain())
    end

    test "and the other eighty-nine cells could still run" do
      # Same payload, called twice: the point is that it returns rather than
      # unwinding the caller, so a sibling cell is unaffected.
      served = update_in(served_pull(), ["types"], &Map.put(&1, "Orphan", []))

      assert {:rejected, _} = verify(served, "0x00", @account, rpc: chain())

      assert {:ok, _} =
               verify(served_pull(), current_signature(served_pull()), @account, rpc: chain())
    end
  end
end
