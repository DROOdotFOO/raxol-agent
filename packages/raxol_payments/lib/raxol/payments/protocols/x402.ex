defmodule Raxol.Payments.Protocols.X402 do
  @moduledoc """
  x402 payment protocol client (Coinbase/Linux Foundation).

  Handles the HTTP 402 flow using EIP-712 signed ERC-3009
  `transferWithAuthorization` messages. The server returns a
  `payment-required` header with Base64-encoded payment requirements;
  this module decodes it, signs with the wallet, and builds the
  `x-payment` header for the retry request.

  ## Header Flow

  1. Server -> `402` + `payment-required: <base64 JSON>`
  2. Client -> retry + `x-payment: <base64 signed payload>`
  3. Server -> `200` + `x-payment-response: <base64 receipt>`
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Headers

  @impl true
  @spec name() :: String.t()
  def name, do: "x402"

  @impl true
  @spec detect?(integer(), Headers.headers()) :: boolean()
  def detect?(402, headers) do
    Headers.find(headers, "payment-required") |> is_binary()
  end

  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_challenge(headers) do
    with {:ok, encoded} <- Headers.require(headers, "payment-required"),
         {:ok, json} <- Base.decode64(encoded),
         {:ok, decoded} when is_map(decoded) <- Jason.decode(json),
         price when not is_nil(price) <-
           decoded["maxAmountRequired"] || decoded["price"],
         :ok <- validate_positive_amount(price),
         pay_to when not is_nil(pay_to) <- decoded["payTo"] || decoded["pay_to"],
         :ok <- validate_address(pay_to),
         currency = decoded["asset"] || decoded["currency"],
         :ok <- reject_fx_asset(decoded["network"], currency),
         {:ok, chain_id} <- parse_network(decoded["network"]),
         :ok <- require_usdc(chain_id, currency),
         valid_before = decoded["validBefore"] || decoded["valid_before"],
         :ok <- validate_valid_before(valid_before),
         {:ok, valid_after} <-
           parse_valid_after(decoded["validAfter"] || decoded["valid_after"], valid_before),
         nonce = decoded["nonce"],
         :ok <- validate_nonce(nonce) do
      {:ok,
       %{
         price: price,
         currency: currency,
         # `require_usdc/2` admits only USDC, counted at par.
         unit: "USD",
         network: decoded["network"],
         chain_id: chain_id,
         pay_to: pay_to,
         nonce: nonce,
         valid_after: valid_after,
         valid_before: valid_before,
         extra: decoded
       }}
    else
      nil -> {:error, :missing_required_field}
      {:error, _} = err -> err
      _ -> {:error, :invalid_challenge}
    end
  end

  # The longest an x402 authorization may stay redeemable: one hour, the
  # validity this module already signs when the challenge names none. A server
  # that asks for longer (or for an expiry already past, or one that is not a
  # whole-second integer) is refused at parse, before any budget is reserved,
  # so a signed payment the server withholds expires within the hour.
  @max_validity_seconds 3600

  defp validate_valid_before(nil), do: :ok

  defp validate_valid_before(value) do
    now = System.system_time(:second)

    case to_seconds(value) do
      t when is_integer(t) and t > now and t <= now + @max_validity_seconds -> :ok
      _ -> {:error, {:invalid_valid_before, value}}
    end
  end

  # `validAfter` is signed as a uint256 of whole seconds: absent means 0, and
  # otherwise it must be a non-negative integer (or a string of digits) no
  # later than the `validBefore` that will be signed. Anything else would make
  # the encoder raise inside the wallet, after the budget is reserved.
  defp parse_valid_after(nil, _valid_before), do: {:ok, 0}

  defp parse_valid_after(value, valid_before) do
    with t when is_integer(t) <- whole_seconds(value),
         true <- t <= signed_valid_before(valid_before) do
      {:ok, t}
    else
      _ -> {:error, {:invalid_valid_after, value}}
    end
  end

  defp whole_seconds(value) when is_integer(value) and value >= 0, do: value

  defp whole_seconds(value) when is_binary(value) do
    if Regex.match?(~r/\A[0-9]{1,20}\z/, value), do: String.to_integer(value)
  end

  defp whole_seconds(_value), do: nil

  defp signed_valid_before(nil), do: System.system_time(:second) + @max_validity_seconds
  defp signed_valid_before(value), do: to_seconds(value)

  # The ERC-3009 `nonce` is a `bytes32`: `0x` and 64 hex digits, or absent
  # (a random one is generated). Anything else would make the encoder raise
  # inside the wallet.
  defp validate_nonce(nil), do: :ok

  defp validate_nonce(nonce) when is_binary(nonce) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{64}\z/, nonce),
      do: :ok,
      else: {:error, {:invalid_nonce, nonce}}
  end

  defp validate_nonce(nonce), do: {:error, {:invalid_nonce, nonce}}

  defp to_seconds(value) when is_integer(value), do: value

  defp to_seconds(value) when is_binary(value) do
    case Integer.parse(value) do
      {t, ""} -> t
      _ -> nil
    end
  end

  defp to_seconds(_value), do: nil

  # `amount/1` scales by the asset's registered decimals and the spend gate caps
  # in dollars, so a non-USD stablecoin would be reserved and charged at par.
  # Refuse the challenge (ADR-0040 decision 6) until an FX rate gates the
  # conversion (decision 7).
  defp reject_fx_asset(network, asset) do
    case Raxol.Payments.Assets.fx_peg(network, asset) do
      nil -> :ok
      peg -> {:error, {:unpriced_asset, %{network: network, asset: asset, peg: peg}}}
    end
  end

  # The wallet signs a USDC `TransferWithAuthorization` under USDC's own EIP-712
  # domain for the chain (`Assets.UsdcDomains`), with the asset as the
  # verifying contract. So the asset must be the registered USDC contract on a
  # chain whose USDC domain is known; anything else would be signed under a
  # domain that is not its own. The chain comes from `network`, which must be
  # `eip155:<chain id>` (or absent, meaning Base).
  defp require_usdc(chain_id, asset) do
    if Raxol.Payments.Assets.symbol_for(chain_id, asset) == "USDC" and
         chain_id in Raxol.Payments.Assets.UsdcDomains.known_chain_ids(),
       do: :ok,
       else: {:error, {:unsupported_asset, %{chain_id: chain_id, asset: asset}}}
  end

  defp parse_network(nil), do: {:ok, 8453}
  defp parse_network(chain_id) when is_integer(chain_id) and chain_id > 0, do: {:ok, chain_id}

  defp parse_network("eip155:" <> digits = network) do
    case Integer.parse(digits) do
      {chain_id, ""} when chain_id > 0 -> {:ok, chain_id}
      _ -> {:error, {:invalid_network, network}}
    end
  end

  defp parse_network(network), do: {:error, {:invalid_network, network}}

  @impl true
  @spec build_payment(map(), module()) ::
          {:ok, Headers.headers()} | {:error, term()}
  def build_payment(challenge, wallet) do
    with {:ok, value} <- atomic_value(challenge.price),
         {:ok, chain_id} <- parse_network(Map.get(challenge, :network)),
         :ok <- require_usdc(chain_id, challenge.currency) do
      build_signed_payment(challenge, wallet, value, chain_id)
    end
  end

  # The signed ERC-3009 `value` is the atomic token amount the gate approved.
  # x402 `maxAmountRequired` is atomic units (an integer); the spend gate reads
  # the same field via `amount/1` as atomic. A float or decimal-string price is
  # malformed as atomic units and would let the signed value diverge from the
  # gated amount (a gate-bypass), so it is rejected before signing rather than
  # coerced.
  defp build_signed_payment(challenge, wallet, value, chain_id) do
    %{name: name, version: version} = Raxol.Payments.Assets.UsdcDomains.lookup(chain_id)

    domain = %{
      name: name,
      version: version,
      chainId: chain_id,
      verifyingContract: challenge.currency
    }

    types = %{
      "TransferWithAuthorization" => [
        {"from", "address"},
        {"to", "address"},
        {"value", "uint256"},
        {"validAfter", "uint256"},
        {"validBefore", "uint256"},
        {"nonce", "bytes32"}
      ]
    }

    message = %{
      from: wallet.address(),
      to: challenge.pay_to,
      value: value,
      validAfter: challenge.valid_after,
      validBefore: challenge.valid_before || :os.system_time(:second) + @max_validity_seconds,
      nonce: challenge.nonce || generate_nonce()
    }

    case wallet.sign_typed_data(domain, types, message) do
      {:ok, signature} ->
        payload =
          Jason.encode!(%{
            signature: "0x" <> Base.encode16(signature, case: :lower),
            message: message,
            network: challenge.network
          })

        encoded = Base.encode64(payload)
        {:ok, [{"x-payment", encoded}]}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  @impl true
  @spec parse_receipt(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_receipt(headers) do
    case Headers.find(headers, "x-payment-response") do
      nil ->
        {:error, :no_receipt}

      encoded ->
        with {:ok, json} <- Base.decode64(encoded),
             {:ok, decoded} <- Jason.decode(json) do
          {:ok,
           %{
             tx_hash: decoded["transactionHash"] || decoded["tx_hash"],
             network: decoded["network"],
             success: decoded["success"] != false
           }}
        end
    end
  end

  @impl true
  @spec amount(map()) :: Decimal.t()
  # Human units of `challenge.unit` ("USD"): the atomic price scaled by the
  # asset's registered decimals on the challenge's chain.
  def amount(challenge) do
    decimals =
      Raxol.Payments.Assets.decimals(
        Map.get(challenge, :chain_id, challenge.network),
        challenge.currency
      )

    Raxol.Payments.Assets.to_human(challenge.price, decimals)
  end

  # Parse the challenge price strictly as non-negative atomic units. Only an
  # integer or an all-digit string is a valid atomic amount; a float or a
  # decimal string is rejected (fail closed) so the signed `value` is always the
  # exact atomic amount the gate read via `amount/1`.
  defp atomic_value(price) when is_integer(price) and price >= 0, do: {:ok, price}

  defp atomic_value(price) when is_binary(price) do
    case Integer.parse(price) do
      {int, ""} when int >= 0 -> {:ok, int}
      _ -> {:error, {:invalid_price, price}}
    end
  end

  defp atomic_value(price), do: {:error, {:invalid_price, price}}

  defp generate_nonce do
    :crypto.strong_rand_bytes(32)
    |> Base.encode16(case: :lower)
    |> then(&("0x" <> &1))
  end

  # x402 `maxAmountRequired` is atomic token units: a positive integer, or an
  # all-digit string, no wider than a uint256 (`Assets.parse_atomic/1`). A float
  # or a decimal string is malformed as atomic units (and would crash the
  # atomic->human conversion in `amount/1`), and a wider amount can never be
  # signed, so the challenge is rejected at parse time -- fail closed rather
  # than guess or crash.
  defp validate_positive_amount(amount) do
    case Raxol.Payments.Assets.parse_atomic(amount) do
      {:ok, _} -> :ok
      :error -> {:error, {:invalid_amount, amount}}
    end
  end

  @address_regex ~r/\A0x[0-9a-fA-F]{40}\z/

  defp validate_address(addr) when is_binary(addr) do
    if Regex.match?(@address_regex, addr),
      do: :ok,
      else: {:error, {:invalid_address, addr}}
  end

  defp validate_address(addr), do: {:error, {:invalid_address, addr}}
end
