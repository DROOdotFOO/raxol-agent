defmodule Raxol.Payments.Actions.Payments.ExecuteXochiIntent.Floor do
  @moduledoc false
  # The pre-signature quote checks for `ExecuteXochiIntent`: the server's
  # payment method, the intent binding, and the delivery floor.
  #
  # The spend gate sees only the human `amount` that leaves the wallet, not the
  # served `to_amount` that arrives, so a hostile quote could deliver ~0 while
  # pulling the full origin amount. A same-asset corridor always gets an
  # automatic floor of `:min_delivery_bps` of par (default 8000 = 80%); this is
  # a theft backstop, not a pricing check. An explicit `min_to_amount` can only
  # raise it, since the caller setting it is the agent the backstop bounds. A
  # cross-asset corridor is bound only by an explicit `min_to_amount`, and a
  # non-USD stablecoin destination without one is refused by `DeliveryFloor`.
  # The quote is judged on the lowest amount it states (`toAmount`, its own
  # `minToAmount`, and the signed `toAmount`).

  alias Raxol.Payments.{Assets, DeliveryFloor}
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Xochi.Schemas.{QuoteRequest, QuoteResponse}

  @type t :: DeliveryFloor.floor()

  @doc """
  Every quote that may be signed passes this: the first one, and the re-quote
  an expired execute leads to.
  """
  @spec assert_quote(QuoteResponse.t(), QuoteRequest.t(), t()) :: :ok | {:error, term()}
  def assert_quote(%QuoteResponse{} = quote, %QuoteRequest{} = request, floor) do
    with :ok <- assert_method(quote, request),
         :ok <- Xochi.validate_intent(quote, request),
         do: DeliveryFloor.check(quote, floor)
  end

  @doc """
  The floor for `request`. `exact_output` pins the delivered amount exactly
  (`Xochi.validate_intent/2`), so only an explicit `min_to_amount` applies.
  """
  @spec delivery_floor(QuoteRequest.t(), map()) :: {:ok, t()} | {:error, term()}
  def delivery_floor(%QuoteRequest{swap_kind: "exact_output"} = request, params) do
    case DeliveryFloor.parse(Map.get(params, :min_to_amount)) do
      {:ok, nil} -> {:ok, :none}
      {:ok, min_out} -> DeliveryFloor.for_route(min_out, Map.from_struct(request))
      {:error, _} = error -> error
    end
  end

  def delivery_floor(%QuoteRequest{} = request, params) do
    with {:ok, min_out} <- DeliveryFloor.parse(Map.get(params, :min_to_amount)),
         {:ok, floor} <- DeliveryFloor.for_route(min_out, Map.from_struct(request)) do
      {:ok, tighten(floor, same_asset_floor(request))}
    end
  end

  @doc """
  Refuse a caller-written `min_to_amount` that bounds nothing. `DeliveryFloor`
  reads `0` and `""` as absent; here they are errors.
  """
  @spec validate_min_to_amount(map()) :: :ok | {:error, term()}
  def validate_min_to_amount(params) do
    case Map.get(params, :min_to_amount) do
      nil -> :ok
      value -> positive_floor(value, DeliveryFloor.parse(value))
    end
  end

  defp positive_floor(_value, {:ok, n}) when is_integer(n), do: :ok
  defp positive_floor(value, {:ok, nil}), do: {:error, {:invalid_min_to_amount, value}}
  defp positive_floor(_value, {:error, _} = error), do: error

  # ERC-3009 is USDC-only (it signs against the USDC contract as the EIP-712
  # verifying contract), so an ERC-3009 quote for another token is refused.
  defp assert_method(%QuoteResponse{payment_method: "erc3009"}, %QuoteRequest{
         from_chain_id: chain,
         from_token: token
       }) do
    if Assets.usdc?(chain, token),
      do: :ok,
      else: {:error, {:method_mismatch, :erc3009_requires_usdc}}
  end

  defp assert_method(_quote, _request), do: :ok

  defp tighten(:none, auto), do: auto
  defp tighten(floor, :none), do: floor
  defp tighten({:floor, explicit}, {:floor, auto}), do: {:floor, max(explicit, auto)}

  defp same_asset_floor(%QuoteRequest{} = request) do
    from_symbol = Assets.symbol_for(request.from_chain_id, request.from_token)
    to_symbol = Assets.symbol_for(request.to_chain_id, request.to_token)

    with true <- not is_nil(from_symbol) and from_symbol == to_symbol,
         {:ok, from_decimals} <- Assets.fetch_decimals(request.from_chain_id, request.from_token),
         {:ok, to_decimals} <- Assets.fetch_decimals(request.to_chain_id, request.to_token) do
      par_out = Assets.to_atomic(Assets.to_human(request.from_amount, from_decimals), to_decimals)
      bps = Application.get_env(:raxol_payments, :min_delivery_bps, 8000)
      {:floor, div(par_out * bps, 10_000)}
    else
      _ -> :none
    end
  end
end
