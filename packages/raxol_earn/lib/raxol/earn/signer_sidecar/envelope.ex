defmodule Raxol.Earn.SignerSidecar.Envelope do
  @moduledoc """
  Mutual authentication between the BEAM and the Node signing sidecar. The
  Node side is `priv/signer_sidecar/envelope.mjs`; `signer_sidecar_envelope_test.exs`
  checks the two against each other (skipped when `node` is not on PATH).

  Both processes hold the sidecar's P-256 authorization key
  (`RAXOL_ACP_SIGNER_PRIVATE_KEY`, inherited by the sidecar from the BEAM's
  env), so both derive the MAC key `K = HMAC-SHA256(key, "raxol-earn-sidecar/v1")`.
  Nothing secret crosses the wire.

  Request headers:

      x-raxol-ts     unix milliseconds
      x-raxol-nonce  16 random bytes, lowercase hex
      x-raxol-sig    hex HMAC(K, "req\\nMETHOD\\npath\\nts\\nnonce\\nsha256hex(body)")

  `path` is the request path without query string; the sidecar URL may not
  carry a path of its own (`Raxol.Earn.SignerSidecar.check_url!/2`). The
  sidecar refuses a bad signature, a timestamp more than 30s off, or a nonce
  it has already accepted, with an unsigned 401.

  It signs every response to an authenticated request:

      x-raxol-sig    hex HMAC(K, "res\\nrequest_sig\\nstatus\\naddress\\nsha256hex(body)")

  with `address` its wallet, lowercased. Binding the request signature means
  only the holder of `K` can produce a response the BEAM accepts, and only for
  the request it actually received. Requests and responses are authenticated,
  not encrypted.
  """

  @context "raxol-earn-sidecar/v1"

  @typedoc "The derived MAC key."
  @type key :: <<_::256>>

  @doc "The MAC key both sides derive from the authorization key."
  @spec derive_key(String.t()) :: key()
  def derive_key(signer_private_key) when is_binary(signer_private_key),
    do: hmac(String.trim(signer_private_key), @context)

  @doc """
  Fresh headers for `method` and `path` over the exact `body` bytes, and the
  request signature the response must be bound to.
  """
  @spec request_headers(key(), String.t(), String.t(), binary()) ::
          {String.t(), [{String.t(), String.t()}]}
  def request_headers(key, method, path, body) do
    ts = Integer.to_string(System.system_time(:millisecond))
    nonce = Base.encode16(:crypto.strong_rand_bytes(16), case: :lower)
    sig = request_sig(key, method, path, body, ts, nonce)
    {sig, [{"x-raxol-ts", ts}, {"x-raxol-nonce", nonce}, {"x-raxol-sig", sig}]}
  end

  @doc "HMAC over method, path, timestamp, nonce and body hash."
  @spec request_sig(key(), String.t(), String.t(), binary(), String.t(), String.t()) ::
          String.t()
  def request_sig(key, method, path, body, ts, nonce),
    do:
      hex_hmac(
        key,
        Enum.join(["req", String.upcase(method), path, ts, nonce, sha256(body)], "\n")
      )

  @doc "HMAC over the request signature, status, wallet and body hash."
  @spec response_sig(key(), String.t(), non_neg_integer(), String.t(), binary()) :: String.t()
  def response_sig(key, request_sig, status, address, body),
    do:
      hex_hmac(
        key,
        Enum.join(
          ["res", request_sig, Integer.to_string(status), String.downcase(address), sha256(body)],
          "\n"
        )
      )

  @doc """
  Check a response's `x-raxol-sig` headers against the request signature and
  the wallet the caller expects the sidecar to sign for.
  """
  @spec verify_response(key(), String.t(), String.t(), non_neg_integer(), binary(), [String.t()]) ::
          :ok | {:error, :sidecar_unauthenticated}
  def verify_response(key, request_sig, address, status, body, [sig]) when is_binary(sig) do
    expected = response_sig(key, request_sig, status, address, body)

    if byte_size(sig) == byte_size(expected) and :crypto.hash_equals(sig, expected),
      do: :ok,
      else: {:error, :sidecar_unauthenticated}
  end

  def verify_response(_key, _request_sig, _address, _status, _body, _sigs),
    do: {:error, :sidecar_unauthenticated}

  defp hex_hmac(key, data), do: Base.encode16(hmac(key, data), case: :lower)
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)
  defp sha256(body), do: Base.encode16(:crypto.hash(:sha256, body), case: :lower)
end
