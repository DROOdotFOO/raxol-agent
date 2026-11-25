defmodule Raxol.Earn.Test.PullPreflightCase do
  @moduledoc """
  Shared fixtures for the `Raxol.Earn.Xochi.PullPreflight` test files: a fake
  chain that answers the preflight's calls as Permit2 and a 7702 account do
  (recovering the signer for real), the Permit2 and ERC-3009 pulls a quote
  serves, a hostile verifier, and the signatures the buyer emits.
  """

  use ExUnit.CaseTemplate

  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Earn.Xochi.PullPreflight
  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol

  using do
    quote do
      import Raxol.Earn.Test.PullPreflightCase
    end
  end

  # Permit2's live Base DOMAIN_SEPARATOR, and the universal deployment it is
  # read from. Hardcoding the real value is what makes the fake chain below an
  # ORACLE rather than a restatement: it is the 32 bytes the contract actually
  # rebuilds, taken from chain, not from our own domain construction.
  @permit2_separator Base.decode16!(
                       "3b6f35e4fce979ef8eac3bcdc8c3fc38fe7911bb0c69c8fe72bf1fd1a17e6f07",
                       case: :lower
                     )
  @permit2_address "0x000000000022D473030F116dDEE9F6B43aC78BA3"
  @spender "0x000000000000000000000000000000000000dEaD"

  @key Base.decode16!("ac0974bec39a17e36ba4a6b4d238ff944bacb478cbed5efcae784d7bf4f2ff80",
         case: :lower
       )
  @owner "0xf39fd6e51aad88f6f4ce6ab8827279cfffb92266"
  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"

  @magic "0x1626ba7e" <> String.duplicate("00", 28)
  @not_magic "0xffffffff" <> String.duplicate("00", 28)

  # A chain that answers the two calls the preflight makes. `DOMAIN_SEPARATOR()`
  # returns Permit2's real value; `isValidSignature` does what a 7702 account
  # does -- recover the signer from the digest it was ASKED about and answer the
  # magic value only if it is the authorized owner. Recovering for real is the
  # point: a signature over a different digest recovers a different address, so
  # the fake cannot accidentally agree with a wrong digest.
  @spec chain(keyword()) :: Req.Request.t()
  def chain(opts \\ []) do
    code = Keyword.get(opts, :code, "0xef0100" <> String.duplicate("11", 20))
    chain_id = Keyword.get(opts, :chain_id, 8453)
    foreign = Keyword.get(opts, :foreign_separator, @permit2_separator)

    plug = fn conn ->
      {:ok, body, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(body)

      result =
        case req["method"] do
          # Which chain the node speaks for. Permit2 is at one address on every
          # chain with a DIFFERENT separator, so this is the only thing that
          # distinguishes a correct read from a plausible wrong one.
          "eth_chainId" ->
            "0x" <> Integer.to_string(chain_id, 16)

          # A 7702 delegation designator is code; "0x" is a bare EOA.
          "eth_getCode" ->
            code

          "eth_call" ->
            [%{"to" => to, "data" => data} | _] = req["params"]
            dispatch(String.downcase(to), data, foreign)
        end

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(
        200,
        Jason.encode!(%{"jsonrpc" => "2.0", "id" => req["id"], "result" => result})
      )
    end

    RPC.client(url: "http://stub.invalid/rpc", plug: plug)
  end

  defp dispatch(to, _data, _foreign) when to == "0x000000000022d473030f116ddee9f6b43ac78ba3" do
    "0x" <> Base.encode16(@permit2_separator, case: :lower)
  end

  # Any other contract answers DOMAIN_SEPARATOR() with whatever 32 bytes it
  # likes. A verifier nominated by the party under audit answers with the
  # separator for the domain that party SERVED, which is what makes the check
  # agree with the payload instead of testing it.
  defp dispatch(to, "0x3644e515", foreign) when to != @account do
    "0x" <> Base.encode16(foreign, case: :lower)
  end

  defp dispatch(to, data, _foreign) when to == @account do
    <<_selector::binary-size(4), digest::binary-size(32), _offset::binary-size(32),
      len::unsigned-big-256, rest::binary>> = decode!(data)

    <<sig::binary-size(^len), _padding::binary>> = rest
    <<r::binary-size(32), s::binary-size(32), v::8>> = sig

    {:ok, pubkey} = ExSecp256k1.recover(digest, r, s, v - 27)

    if EIP712.address_from_pubkey(pubkey) == @owner, do: @magic, else: @not_magic
  end

  defp decode!("0x" <> hex), do: Base.decode16!(hex, case: :mixed)

  # The Permit2 pull a Xochi quote serves, with the domain Permit2 declares:
  # name/chainId/verifyingContract, and NO version.
  @spec served_pull() :: map()
  def served_pull do
    %{
      "domain" => %{
        "name" => "Permit2",
        "chainId" => 8453,
        "verifyingContract" => @permit2_address
      },
      "primaryType" => "PermitWitnessTransferFrom",
      "types" => %{
        "EIP712Domain" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "chainId", "type" => "uint256"},
          %{"name" => "verifyingContract", "type" => "address"}
        ],
        "PermitWitnessTransferFrom" => [
          %{"name" => "permitted", "type" => "TokenPermissions"},
          %{"name" => "spender", "type" => "address"},
          %{"name" => "nonce", "type" => "uint256"},
          %{"name" => "deadline", "type" => "uint256"},
          %{"name" => "witness", "type" => "OriginPullWitness"}
        ],
        "TokenPermissions" => [
          %{"name" => "token", "type" => "address"},
          %{"name" => "amount", "type" => "uint256"}
        ],
        "OriginPullWitness" => [%{"name" => "orderId", "type" => "bytes32"}]
      },
      "message" => %{
        "permitted" => %{
          "token" => "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913",
          "amount" => "3000000"
        },
        "spender" => @spender,
        "nonce" => "1",
        "deadline" => "1790000000",
        "witness" => %{"orderId" => "0x" <> String.duplicate("11", 32)}
      }
    }
  end

  @usdc_base "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  # The ERC-3009 pull a quote serves for an EOA buyer. Two things differ from the
  # Permit2 fixture and both matter: the verifying contract is the TOKEN rather
  # than one universal address, and the domain carries a `version` -- so the
  # `expect_verifier` pin comes from the caller's own token config, and the
  # domain half has a field the Permit2 domain does not.
  #
  # This is the rail `mix raxol_earn.order --signer eoa` and the live ACP gate
  # take. It had no coverage at all while the preflight was already blocking
  # funded runs on it.
  @spec served_erc3009_pull() :: map()
  def served_erc3009_pull do
    %{
      "domain" => %{
        "name" => "USD Coin",
        "version" => "2",
        "chainId" => 8453,
        "verifyingContract" => @usdc_base
      },
      "primaryType" => "ReceiveWithAuthorization",
      "types" => %{
        "EIP712Domain" => [
          %{"name" => "name", "type" => "string"},
          %{"name" => "version", "type" => "string"},
          %{"name" => "chainId", "type" => "uint256"},
          %{"name" => "verifyingContract", "type" => "address"}
        ],
        "ReceiveWithAuthorization" => [
          %{"name" => "from", "type" => "address"},
          %{"name" => "to", "type" => "address"},
          %{"name" => "value", "type" => "uint256"},
          %{"name" => "validAfter", "type" => "uint256"},
          %{"name" => "validBefore", "type" => "uint256"},
          %{"name" => "nonce", "type" => "bytes32"}
        ]
      },
      "message" => %{
        "from" => @owner,
        "to" => @spender,
        "value" => "3000000",
        "validAfter" => "0",
        "validBefore" => "1790000000",
        "nonce" => "0x" <> String.duplicate("22", 32)
      }
    }
  end

  # A chain where the ERC-3009 token answers DOMAIN_SEPARATOR() with the
  # separator for the domain it declares.
  @spec erc3009_chain(map()) :: Req.Request.t()
  def erc3009_chain(served),
    do: chain(code: "0x", foreign_separator: separator_for(served["domain"]))

  @hostile "0x00000000000000000000000000000000000badc0"

  # A pull whose domain nominates a verifier the worker controls, paired with a
  # chain where that verifier answers DOMAIN_SEPARATOR() with the separator for
  # the domain it served. Nothing in the payload is inconsistent -- that is the
  # point. The signature really does cover the digest that address really will
  # rebuild, so every question this module asks the chain comes back clean while
  # the pull runs somewhere else entirely.
  @spec hostile_verifier() :: {map(), Req.Request.t()}
  def hostile_verifier do
    served =
      served_pull()
      |> Map.put("primaryType", "PermitWitnessTransferFromV2")
      |> update_in(["domain"], &Map.put(&1, "verifyingContract", @hostile))

    {served, chain(foreign_separator: separator_for(served["domain"]))}
  end

  # EIP712Domain(string name,string version,uint256 chainId,address
  # verifyingContract) -- the four-field domain the ERC-3009 tokens declare.
  # Must precede the three-field clause, which matches this map as well.
  @spec separator_for(map()) :: <<_::256>>
  def separator_for(%{"version" => version} = domain) do
    %{"name" => name, "chainId" => chain_id, "verifyingContract" => "0x" <> vc} = domain

    type = "EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)"

    ExKeccak.hash_256(
      ExKeccak.hash_256(type) <>
        ExKeccak.hash_256(name) <>
        ExKeccak.hash_256(version) <>
        <<chain_id::unsigned-big-256>> <>
        <<0::size(96)>> <> Base.decode16!(vc, case: :mixed)
    )
  end

  # EIP712Domain(string name,uint256 chainId,address verifyingContract), built
  # the long way so the fake does not borrow the code under test to lie with.
  def separator_for(%{"name" => name, "chainId" => chain_id, "verifyingContract" => "0x" <> vc}) do
    type = "EIP712Domain(string name,uint256 chainId,address verifyingContract)"

    ExKeccak.hash_256(
      ExKeccak.hash_256(type) <>
        ExKeccak.hash_256(name) <>
        <<chain_id::unsigned-big-256>> <>
        <<0::size(96)>> <> Base.decode16!(vc, case: :mixed)
    )
  end

  # Every call needs the pin now, and these tests are about the other arguments.
  # `put_new` so a test that IS about the pin can still name its own. The two
  # tests about the requirement itself call `PullPreflight.verify/4` directly.
  @spec verify(map(), String.t(), String.t(), keyword()) :: term()
  def verify(served, signature, account, opts) do
    PullPreflight.verify(
      served,
      signature,
      account,
      Keyword.put_new(opts, :expect_verifier, @permit2_address)
    )
  end

  @spec sign_over(<<_::256>>) :: String.t()
  def sign_over(digest) do
    {:ok, raw} = ExSecp256k1.sign(digest, @key)
    "0x" <> Base.encode16(EIP712.pack_signature(raw), case: :lower)
  end

  # What the buyer emits today: the domain projected from the served map, which
  # for this payload is exactly the three fields Permit2 declares.
  @spec current_signature(map()) :: String.t()
  def current_signature(served) do
    domain = Raxol.Payments.Protocols.Xochi.eip712_domain(served)
    {:ok, digest} = EIP712.hash(domain, XochiProtocol.eip712_types(served), served["message"])
    sign_over(digest)
  end

  # A signature over name/version/chainId/verifyingContract, with a version
  # Permit2 never declares. Permit2 reverts it with InvalidContractSignature().
  @spec versioned_domain_signature(map()) :: String.t()
  def versioned_domain_signature(served) do
    d = served["domain"]

    # The key is present and holds nil, which is exactly what the old
    # eip712_domain/1 produced: EIP712 derives the EIP712Domain field list with
    # Map.has_key?, so this still declares `string version` and encodes it as
    # the empty string.
    domain = %{
      name: d["name"],
      version: nil,
      chainId: d["chainId"],
      verifyingContract: d["verifyingContract"]
    }

    {:ok, digest} = EIP712.hash(domain, XochiProtocol.eip712_types(served), served["message"])
    sign_over(digest)
  end
end
