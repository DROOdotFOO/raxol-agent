defmodule Raxol.Payments.Protocols.MPP do
  @moduledoc """
  Machine Payments Protocol client (Stripe/Tempo).

  Handles the HTTP 402 flow using the MPP challenge/credential scheme.
  The server returns `WWW-Authenticate: Payment` with a challenge; this
  module decodes it, signs a payment credential, and builds the
  `Authorization: Payment` header for the retry request.

  ## Header Flow

  1. Server -> `402` + `WWW-Authenticate: Payment <base64 challenge>`
  2. Client -> retry + `Authorization: Payment <base64 credential>`
  3. Server -> `200` + `Payment-Receipt: <base64 receipt>`

  ## Payment Methods

  MPP supports multiple payment methods per challenge. This implementation
  handles EVM-based methods (Tempo, ETH, ERC-20) and prefers one when the
  challenge offers it. Stripe (fiat) methods are not supported: the credential
  is always signed by the wallet.
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.Headers

  @impl true
  @spec name() :: String.t()
  def name, do: "MPP"

  @impl true
  @spec detect?(integer(), Headers.headers()) :: boolean()
  def detect?(402, headers) do
    case Headers.find(headers, "www-authenticate") do
      nil -> false
      value -> String.contains?(String.downcase(value), "payment")
    end
  end

  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_challenge(headers) do
    with {:ok, auth_header} <- Headers.require(headers, "www-authenticate"),
         {:ok, challenge_data} when is_map(challenge_data) <-
           extract_payment_challenge(auth_header),
         amount when not is_nil(amount) <- challenge_data["amount"],
         :ok <- validate_positive_amount(amount),
         currency = challenge_data["currency"] || "USDC",
         {:ok, unit, decimals} <- currency_unit(currency),
         recipient when not is_nil(recipient) <-
           challenge_data["recipient"] || challenge_data["pay_to"],
         {:ok, methods} <- parse_methods(challenge_data["methods"]) do
      {:ok,
       %{
         amount: amount,
         currency: currency,
         unit: unit,
         decimals: decimals,
         recipient: recipient,
         methods: methods,
         network: challenge_data["network"],
         nonce: challenge_data["nonce"],
         expires: challenge_data["expires"],
         description: challenge_data["description"],
         extra: challenge_data
       }}
    else
      nil -> {:error, :missing_required_field}
      {:error, _} = err -> err
      _ -> {:error, :invalid_challenge}
    end
  end

  @impl true
  @spec build_payment(map(), module()) ::
          {:ok, Headers.headers()} | {:error, term()}
  def build_payment(challenge, wallet) do
    credential =
      %{
        method: select_method(challenge.methods),
        amount: challenge.amount,
        currency: challenge.currency,
        from: wallet.address(),
        to: challenge.recipient,
        network: challenge.network,
        nonce: challenge.nonce,
        timestamp: :os.system_time(:second)
      }

    case wallet.sign_message(Jason.encode!(credential)) do
      {:ok, signature} ->
        signed_credential =
          Map.put(
            credential,
            :signature,
            "0x" <> Base.encode16(signature, case: :lower)
          )

        encoded = Base.encode64(Jason.encode!(signed_credential))
        {:ok, [{"authorization", "Payment " <> encoded}]}

      {:error, reason} ->
        {:error, {:sign_failed, reason}}
    end
  end

  @impl true
  @spec parse_receipt(Headers.headers()) :: {:ok, map()} | {:error, term()}
  def parse_receipt(headers) do
    case Headers.find(headers, "payment-receipt") do
      nil ->
        {:error, :no_receipt}

      encoded ->
        with {:ok, json} <- Base.decode64(encoded),
             {:ok, decoded} <- Jason.decode(json) do
          {:ok,
           %{
             tx_hash: decoded["transactionHash"] || decoded["tx_hash"],
             amount: decoded["amount"],
             method: decoded["method"],
             success: decoded["success"] != false
           }}
        end
    end
  end

  @impl true
  @spec amount(map()) :: Decimal.t()
  # The challenge amount is atomic units of its currency; this is that amount in
  # human units of `challenge.unit` (`"USD"` for dollars and dollar
  # stablecoins), the unit `SpendingPolicy` caps are written in, using the
  # `decimals` `parse_challenge/1` resolved from the currency. The signed
  # credential carries the atomic amount unchanged. It goes through the integer
  # because decimal's string parse rejects more than 34 digits, and a wider
  # amount that parsed must reach the budget gate, not raise here.
  def amount(%{amount: amount, decimals: decimals}) do
    amount
    |> to_string()
    |> String.to_integer()
    |> Raxol.Payments.Assets.to_human(decimals)
  end

  defp extract_payment_challenge(auth_header) do
    case String.split(auth_header, " ", parts: 2) do
      [_scheme, encoded] ->
        with {:ok, json} <- Base.decode64(String.trim(encoded)) do
          Jason.decode(json)
        end

      _ ->
        {:error, :invalid_auth_header}
    end
  end

  # MPP amounts are atomic units of the challenge's currency: a positive
  # integer, or an all-digit string, no wider than a uint256
  # (`Assets.parse_atomic/1`), matching the x402 convention. A float or a
  # decimal string is malformed as atomic units, and a wider amount can never be
  # signed, so the challenge is rejected at parse time -- fail closed rather
  # than guess the unit.
  defp validate_positive_amount(amount) do
    case Raxol.Payments.Assets.parse_atomic(amount) do
      {:ok, _} -> :ok
      :error -> {:error, {:invalid_amount, amount}}
    end
  end

  # ISO 4217 minor units of the fiat currencies raxol prices: the dollar, and
  # the euro and Swiss franc the registered non-USD stablecoins are pegged to.
  @fiat_minor_units %{"USD" => 2, "EUR" => 2, "CHF" => 2}

  # The unit an MPP amount is priced in and its decimals, from the challenge's
  # `currency`: a fiat code by its ISO 4217 minor units (`"usd"` 150 is $1.50),
  # a stablecoin (`Assets.symbol_peg/1`: dollar stablecoins as USD, EURC, EURe
  # and ZCHF as their peg currency) by its registered decimals. Anything else
  # -- a volatile token, a contract address, an unknown code -- has no unit a
  # cap can be written in, so the challenge is refused.
  defp currency_unit(currency) when is_binary(currency) do
    code = Raxol.Payments.Assets.fold_symbol(currency)

    cond do
      Map.has_key?(@fiat_minor_units, code) ->
        {:ok, code, Map.fetch!(@fiat_minor_units, code)}

      peg = Raxol.Payments.Assets.symbol_peg(code) ->
        {:ok, peg, Raxol.Payments.Assets.decimals(code)}

      true ->
        {:error, {:unpriced_currency, currency}}
    end
  end

  defp currency_unit(currency), do: {:error, {:unpriced_currency, currency}}

  # `build_payment/2` walks `methods`, so a non-list is refused here, before
  # any budget is reserved, rather than raising after it.
  defp parse_methods(nil), do: {:ok, []}
  defp parse_methods(methods) when is_list(methods), do: {:ok, methods}
  defp parse_methods(methods), do: {:error, {:invalid_methods, methods}}

  defp select_method([]), do: "evm"

  defp select_method(methods) do
    Enum.find(methods, List.first(methods), fn method ->
      method_type = if is_map(method), do: method["type"], else: method
      method_type in ["tempo", "evm", "eth"]
    end)
    |> then(fn
      method when is_map(method) -> method["type"]
      method -> method
    end)
  end
end
