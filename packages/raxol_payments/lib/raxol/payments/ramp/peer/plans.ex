defmodule Raxol.Payments.Ramp.Peer.Plans do
  @moduledoc "Unsigned Base USDC plans matching @zkp2p/sdk 0.15.0-rc.11; no keys or submissions."
  alias Raxol.Payments.Ramp.Peer.ABI
  @max Integer.pow(2, 256)
  @zero "0x0000000000000000000000000000000000000000"

  def approval(amount) when is_integer(amount) and amount > 0 and amount < @max,
    do:
      transaction(
        ABI.address("usdc"),
        "0x095ea7b3" <>
          String.pad_leading(String.slice(ABI.address("escrowV2"), 2..-1//1), 64, "0") <>
          Base.encode16(<<amount::256>>, case: :lower),
        :approve_usdc,
        amount
      )

  def deposit(amount, rail, payee_hash, terms)
      when is_integer(amount) and amount > 0 and amount < @max do
    true =
      terms.minimum > 0 and terms.minimum <= amount and amount <= terms.maximum and terms.rate > 0

    true = payee_hash != "0x" <> String.duplicate("0", 64)
    method = ABI.config()["rails"][rail]["paymentMethodHash"]

    currency = %{
      "code" => ABI.config()["currencyHash"],
      "minConversionRate" => terms.rate,
      "oracleRateConfig" => %{
        "adapter" => @zero,
        "adapterConfig" => "0x",
        "spreadBps" => 0,
        "maxStaleness" => 0
      }
    }

    params = %{
      "token" => ABI.address("usdc"),
      "amount" => amount,
      "intentAmountRange" => %{"min" => terms.minimum, "max" => min(terms.maximum, amount)},
      "paymentMethods" => [method],
      "paymentMethodData" => [
        %{
          "intentGatingService" => ABI.config()["gatingService"],
          "payeeDetails" => payee_hash,
          "data" => "0x"
        }
      ],
      "currencies" => [[currency]],
      "delegate" => @zero,
      "intentGuardian" => ABI.address("intentGuardian"),
      "retainOnEmpty" => false
    }

    transaction(
      ABI.address("escrowV2"),
      attributed(ABI.call("escrowV2", "createDeposit", [params])),
      :create_deposit,
      amount
    )
  end

  def withdrawal(id, amount, full)
      when is_integer(id) and id >= 0 and id < @max and is_integer(amount) and amount > 0 and
             amount < @max and is_boolean(full) do
    {name, args} = if full, do: {"withdrawDeposit", [id]}, else: {"removeFunds", [id, amount]}

    transaction(
      ABI.address("escrowV2"),
      attributed(ABI.call("escrowV2", name, args)),
      :withdraw_unmatched,
      amount
    )
  end

  defp attributed(data), do: data <> String.slice(ABI.config()["attribution"], 2..-1//1)

  defp transaction(to, data, action, amount),
    do: %{chain_id: 8453, to: to, data: data, value: 0, action: action, amount: to_string(amount)}
end
