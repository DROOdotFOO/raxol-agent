defmodule Raxol.Payments.Xochi.DepositAttestation do
  @moduledoc """
  Client-side verification of a Xochi deposit-route quote's `deposit_attestation`
  (`xochi-deposit-attestation:v3`).

  A non-EVM origin (Tron) has no gasless pull, so a deposit-route quote returns a
  bare `deposit_address` the payer funds directly. Riddler signs the whole deal
  with a dedicated, solver-distinct key; raxol pins that key out of band (see
  `Raxol.Payments.Protocols.Xochi.deposit_route_quote/3`) and refuses the quote
  unless the attestation recovers to it, the advertised version is v3 and the
  attested deposit window is still open. Every check fails closed.

  v1 (seven lines, origin leg only) is refused: it proved the venue issued a
  deposit address for *an* intent, not that the intent is the caller's, so a
  genuine v1 attestation is replayable onto someone else's request. Riddler
  issues only v3.

  ## Signed message (byte-exact with Riddler)

  An EIP-191 `personal_sign` over eighteen lines joined by a single `\\n` (no
  trailing newline), UTF-8:

      xochi-deposit-attestation:v3
      <intent_id>
      <quote_id>
      <wallet>
      <from_chain_id>
      <from_token>
      <from_amount>
      <deposit_address>
      <deposit_deadline>
      <refund_address>
      <to_chain_id>
      <to_token>
      <to_amount>
      <min_to_amount>
      <recipient>
      <stealth_spending_pub_key>
      <stealth_viewing_pub_key>
      <settlement_preference>

  Encoding, as pinned by the conformance vectors Riddler publishes at
  `/xochi/vectors/deposit-attestation.json` (vendored under `test/fixtures/`):

    * A value beginning with the case-sensitive prefix `0x` is lowercased; any
      other value is verbatim (base58 is case-sensitive). `0X` is not folded.
    * `to_token` and `recipient` can hold a Canton party
      (`hint::1220<64 hex>`, free case-sensitive hint), so there only a value
      that is entirely `0x` + hex is lowercased.
    * Chain ids, `deposit_deadline` and the three amounts are decimal integers.
    * An absent optional (`deposit_deadline`, `refund_address`, either stealth
      key) is an empty line, never `null` and never an omitted line.
    * `\\n` is the field delimiter and nothing escapes it, so a field containing
      one is refused (`{:newline_in_field, field}`) rather than signed.

  The signature is `0x` + 65 bytes (`r || s || v`), `v` in {0, 1, 27, 28}.
  """

  alias Raxol.Payments.{Eip191, EIP712}

  @version "xochi-deposit-attestation:v3"

  @typedoc "The attested deal, in Riddler's field names."
  @type fields :: %{
          intent_id: String.t(),
          quote_id: String.t(),
          wallet: String.t(),
          from_chain_id: non_neg_integer(),
          from_token: String.t(),
          from_amount: String.t(),
          deposit_address: String.t(),
          deposit_deadline: integer() | nil,
          refund_address: String.t() | nil,
          to_chain_id: non_neg_integer(),
          to_token: String.t(),
          to_amount: String.t(),
          min_to_amount: String.t(),
          recipient: String.t(),
          stealth_spending_pub_key: String.t() | nil,
          stealth_viewing_pub_key: String.t() | nil,
          settlement_preference: String.t()
        }

  @typedoc """
  What a verify is checked against: the operator-pinned `signer`, the
  `deposit_attestation_version` the capability matrix advertises, and `now` in
  unix seconds (injected, so the deadline check is testable).
  """
  @type expectation :: %{
          signer: String.t() | nil,
          version: String.t() | nil,
          now: integer()
        }

  @type error ::
          :missing_attestation
          | :signer_unavailable
          | :attestation_mismatch
          | :invalid_signature
          | :missing_deposit_deadline
          | {:unsupported_deposit_attestation_version, term()}
          | {:deposit_deadline_passed, %{deadline: integer(), now: integer()}}
          | {:invalid_deposit_deadline, term()}
          | {:newline_in_field, atom()}

  @doc "The version tag this client verifies; anything else is refused."
  @spec version() :: String.t()
  def version, do: @version

  @doc """
  The byte-exact v3 message for `fields`, or `{:error, {:newline_in_field,
  field}}` when a value would move a field boundary.
  """
  @spec message(fields()) :: {:ok, String.t()} | {:error, {:newline_in_field, atom()}}
  def message(%{} = fields) do
    parts = parts(fields)

    case Enum.find(parts, fn {_field, value} -> String.contains?(value, "\n") end) do
      nil -> {:ok, Enum.map_join(parts, "\n", &elem(&1, 1))}
      {field, _value} -> {:error, {:newline_in_field, field}}
    end
  end

  @doc "Recover the signer address (lowercased `0x`) of a v3 attestation over `fields`."
  @spec recover(fields(), String.t()) ::
          {:ok, String.t()} | {:error, :invalid_signature | {:newline_in_field, atom()}}
  def recover(%{} = fields, signature) when is_binary(signature) do
    with {:ok, message} <- message(fields),
         {:ok, {r, s, recovery_id}} <- decode_signature(signature),
         {:ok, pubkey} <- ExSecp256k1.recover(Eip191.digest(message), r, s, recovery_id) do
      {:ok, EIP712.address_from_pubkey(pubkey)}
    else
      {:error, {:newline_in_field, _}} = error -> error
      _ -> {:error, :invalid_signature}
    end
  end

  def recover(_fields, _signature), do: {:error, :invalid_signature}

  @doc """
  Refuse anything but a v3 attestation, naming what was advertised.

  `nil` (a matrix that predates `deposit_attestation_version`, or the static
  fallback) is refused too: an unadvertised version is not a v3 one.
  """
  @spec check_version(term()) ::
          :ok | {:error, {:unsupported_deposit_attestation_version, term()}}
  def check_version(@version), do: :ok
  def check_version(other), do: {:error, {:unsupported_deposit_attestation_version, other}}

  @doc """
  Verify `signature` is a v3 attestation over exactly `fields` by the pinned
  signer, with the attested deposit window still open. Fail closed:

    * `{:unsupported_deposit_attestation_version, advertised}` -- not v3.
    * `:missing_attestation` -- the quote carried no signature.
    * `:signer_unavailable` -- nothing is pinned to verify against.
    * `:missing_deposit_deadline` / `{:invalid_deposit_deadline, value}` --
      Riddler always attests a deadline on a deposit route.
    * `{:deposit_deadline_passed, %{deadline: _, now: _}}` -- a held, genuine
      quote replayed after its window would land funds too late to fill.
    * `{:newline_in_field, field}` -- an ambiguous message is never verified.
    * `:invalid_signature` -- not a recoverable signature.
    * `:attestation_mismatch` -- it recovers to someone other than the pin,
      which is also what a v1 signature or any other deal looks like.
  """
  @spec verify(fields(), String.t() | nil, expectation()) :: :ok | {:error, error()}
  def verify(%{} = fields, signature, %{signer: signer, version: version, now: now})
      when is_integer(now) do
    with :ok <- check_version(version),
         :ok <- present(signature, :missing_attestation),
         :ok <- present(signer, :signer_unavailable),
         :ok <- check_deadline(fields.deposit_deadline, now),
         {:ok, recovered} <- recover(fields, signature) do
      if addr_eq?(recovered, signer), do: :ok, else: {:error, :attestation_mismatch}
    end
  end

  defp present(value, _error) when is_binary(value) and value != "", do: :ok
  defp present(_value, error), do: {:error, error}

  defp check_deadline(nil, _now), do: {:error, :missing_deposit_deadline}

  defp check_deadline(deadline, now) when is_integer(deadline) and deadline > now, do: :ok

  defp check_deadline(deadline, now) when is_integer(deadline),
    do: {:error, {:deposit_deadline_passed, %{deadline: deadline, now: now}}}

  defp check_deadline(other, _now), do: {:error, {:invalid_deposit_deadline, other}}

  # Every key is matched, so a caller that forgets a v3 field fails here instead
  # of signing an empty line in its place.
  defp parts(%{
         intent_id: intent_id,
         quote_id: quote_id,
         wallet: wallet,
         from_chain_id: from_chain_id,
         from_token: from_token,
         from_amount: from_amount,
         deposit_address: deposit_address,
         deposit_deadline: deposit_deadline,
         refund_address: refund_address,
         to_chain_id: to_chain_id,
         to_token: to_token,
         to_amount: to_amount,
         min_to_amount: min_to_amount,
         recipient: recipient,
         stealth_spending_pub_key: spending_pub_key,
         stealth_viewing_pub_key: viewing_pub_key,
         settlement_preference: settlement_preference
       })
       when is_integer(from_chain_id) and is_integer(to_chain_id) do
    [
      {:version, @version},
      {:intent_id, to_string(intent_id)},
      {:quote_id, to_string(quote_id)},
      {:wallet, normalize_address(wallet)},
      {:from_chain_id, Integer.to_string(from_chain_id)},
      {:from_token, normalize_address(from_token)},
      {:from_amount, to_string(from_amount)},
      {:deposit_address, normalize_address(deposit_address)},
      {:deposit_deadline, optional_integer(deposit_deadline)},
      {:refund_address, optional_address(refund_address)},
      {:to_chain_id, Integer.to_string(to_chain_id)},
      {:to_token, normalize_party_capable(to_token)},
      {:to_amount, to_string(to_amount)},
      {:min_to_amount, to_string(min_to_amount)},
      {:recipient, normalize_party_capable(recipient)},
      {:stealth_spending_pub_key, optional_address(spending_pub_key)},
      {:stealth_viewing_pub_key, optional_address(viewing_pub_key)},
      {:settlement_preference, to_string(settlement_preference)}
    ]
  end

  # Riddler's `"0x" <> _` fold: case-sensitive prefix, whole value lowercased.
  # Never a checksum helper and never trimmed -- the bytes are the binding.
  defp normalize_address("0x" <> _ = address), do: String.downcase(address)
  defp normalize_address(other), do: to_string(other)

  defp normalize_party_capable("0x" <> digits = address) when digits != "" do
    if hex?(digits), do: String.downcase(address), else: address
  end

  defp normalize_party_capable(other), do: to_string(other)

  defp hex?(<<>>), do: true
  defp hex?(<<c, rest::binary>>) when c in ?0..?9 or c in ?a..?f or c in ?A..?F, do: hex?(rest)
  defp hex?(_other), do: false

  defp optional_address(nil), do: ""
  defp optional_address(address), do: normalize_address(address)

  defp optional_integer(nil), do: ""
  defp optional_integer(value) when is_integer(value), do: Integer.to_string(value)
  defp optional_integer(value), do: to_string(value)

  defp decode_signature("0x" <> hex) when byte_size(hex) == 130 do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<r::binary-size(32), s::binary-size(32), v::8>>} when v in [0, 1, 27, 28] ->
        {:ok, {r, s, Eip191.normalize_recovery_id(v)}}

      _ ->
        :error
    end
  end

  defp decode_signature(_signature), do: :error

  # Exact up to case: a malformed pinned signer must not match.
  defp addr_eq?(a, b), do: String.downcase(a) == String.downcase(b)
end
