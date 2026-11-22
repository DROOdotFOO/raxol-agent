defmodule Raxol.Payments.Test.DepositAttestationFixture do
  @moduledoc """
  Signs v3 deposit attestations the way Riddler does, with a real secp256k1
  key: an EIP-191 `personal_sign` over `DepositAttestation.message/1`, `v` in
  {27, 28}. The encoding itself is pinned by the vendored Riddler vectors
  (`deposit_attestation_conformance_test.exs`), so signing through
  `message/1` here does not let a wrong encoding pass.
  """

  alias Raxol.Payments.{Eip191, EIP712}
  alias Raxol.Payments.Xochi.{Capabilities, DepositAttestation}

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @base_usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  @evm_recipient "0x" <> String.duplicate("ab", 20)

  @doc "Defaults shared by the deposit-route tests."
  @spec defaults() :: map()
  def defaults do
    %{
      tron_usdt: @tron_usdt,
      tron_wallet: @tron_wallet,
      deposit_address: @deposit_addr,
      to_token: @base_usdc,
      recipient: @evm_recipient
    }
  end

  @doc "A full v3 field set for a Tron USDT -> Base USDC deal, with `overrides`."
  @spec fields(map()) :: DepositAttestation.fields()
  def fields(overrides \\ %{}) do
    Map.merge(
      %{
        intent_id: "xi_dep_1",
        quote_id: "xq_dep_1",
        wallet: @tron_wallet,
        from_chain_id: 728_126_428,
        from_token: @tron_usdt,
        from_amount: "1000000",
        deposit_address: @deposit_addr,
        deposit_deadline: 1_900_000_000,
        refund_address: nil,
        to_chain_id: 8453,
        to_token: @base_usdc,
        to_amount: "995000",
        min_to_amount: "990025",
        recipient: @evm_recipient,
        stealth_spending_pub_key: nil,
        stealth_viewing_pub_key: nil,
        settlement_preference: "public"
      },
      overrides
    )
  end

  @doc "The lowercased `0x` address of `priv`."
  @spec address(binary()) :: String.t()
  def address(priv) do
    {:ok, pubkey} = ExSecp256k1.create_public_key(priv)
    EIP712.address_from_pubkey(pubkey)
  end

  @doc "Sign the v3 attestation over `fields` with `priv`."
  @spec sign(map(), binary()) :: String.t()
  def sign(fields, priv) do
    {:ok, message} = DepositAttestation.message(fields)
    sign_message(message, priv)
  end

  @doc "Sign an arbitrary message (e.g. a v1 preimage) as `personal_sign`."
  @spec sign_message(String.t(), binary()) :: String.t()
  def sign_message(message, priv) do
    {:ok, sig} = ExSecp256k1.sign(Eip191.digest(message), priv)
    "0x" <> Base.encode16(EIP712.pack_signature(sig), case: :lower)
  end

  @doc """
  A capability matrix advertising `version` (default v3) and, optionally, a
  matrix signer.
  """
  @spec capabilities(keyword()) :: Capabilities.t()
  def capabilities(opts \\ []) do
    Capabilities.fallback()
    |> Map.put(:deposit_attestation_signer, Keyword.get(opts, :signer))
    |> Map.put(
      :deposit_attestation_version,
      Keyword.get(opts, :version, DepositAttestation.version())
    )
  end
end
