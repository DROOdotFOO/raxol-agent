defmodule Raxol.Payments.Ramp.Peer do
  @moduledoc """
  Read-only Peer Curator v3 quote adapter, pinned to @zkp2p/sdk 0.15.0-rc.11.

  Requires trusted `:user` and `:orchestrator` addresses in context and a validated
  `:intent`. `:req_options` injects Req's transport (e.g. a Plug in unit tests).
  `:now` may supply a deterministic clock. No raw payload is returned or logged.

  HTTP Date must be within 30 seconds, Age must be absent/zero, and expiry
  must be future and at most five minutes away.

  Only direct USD/Base USDC onramps without region constraints are currently supported.
  Offramp execution delegates to `Peer.Maker` with trusted maker I/O and wallet
  dependencies; maker discovery remains unavailable without fresh maker evidence. Browser and payment-account
  enrollment readiness must be attested by the trusted caller (`:interaction_ready` and a per-rail `:ready_rails` allowlist); otherwise
  no executable offers are returned. Availability is quote-specific, so offer bounds
  equal the exact requested amount. Requoting preserves the offer reference but
  changes the revision when amounts, fees, or requirements change.
  """
  @behaviour Raxol.Payments.Ramp.Provider
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Coherence
  @usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"
  @disclosures %{
    "public_state" => ["base_settlement"],
    "identity_visible_to" => ["fiat_counterparty", "payment_platform"],
    "liveness_dependencies" => ["peer", "peer_tee", "base"]
  }

  @impl true
  def capabilities(context) do
    with {:ok, entries} <- fetch(context) do
      {:ok, Enum.map(entries, &elem(&1, 0))}
    end
  end

  @impl true
  def preview(intent, offer_ref, revision, context) do
    with {:ok, entries} <- fetch(Map.put(context, :intent, intent)),
         {offer, values} <- Enum.find(entries, fn {offer, _} -> offer.offer_id == offer_ref end),
         true <- offer.capability_revision == revision do
      preview_message(offer, values, intent)
    else
      nil -> {:error, :capability_changed}
      false -> {:error, :capability_changed}
      {:error, code} -> {:error, code}
    end
  end

  @impl true
  defdelegate approve(operation, quote, command, context), to: __MODULE__.Maker
  @impl true
  defdelegate status(operation, context), to: __MODULE__.Maker
  @impl true
  defdelegate recover(operation, action, command, context), to: __MODULE__.Maker

  defp fetch(%{intent: %Ramp.Intent{} = intent} = context) do
    with :ok <- supported(intent, context),
         {:ok, response} <- request(intent, context) do
      normalize(response, intent, context)
    end
  rescue
    _ -> {:error, :invalid_provider_response}
  catch
    _, _ -> {:error, :provider_unavailable}
  end

  defp fetch(_), do: {:error, :invalid_request}

  defp supported(intent, context) do
    cond do
      not direct_onramp?(intent) ->
        {:error, :not_supported}

      intent.fiat["currency"] != "USD" or intent.fiat["decimals"] != 2 ->
        {:error, :not_supported}

      not base_usdc?(intent.crypto) ->
        {:error, :not_supported}

      not configured_wallets?(context) ->
        {:error, :invalid_request}

      not positive_amount?(intent) ->
        {:error, :invalid_request}

      context[:interaction_ready] != true ->
        {:error, :setup_required}

      true ->
        :ok
    end
  end

  defp configured_wallets?(c), do: address?(c[:user]) and address?(c[:orchestrator])

  defp direct_onramp?(i), do: i.direction == "onramp" and is_nil(i.route) and is_nil(i.region)

  defp base_usdc?(a),
    do:
      a["chain_id"] == "eip155:8453" and Coherence.address(a) == @usdc and
        a["decimals"] == 6 and a["symbol"] == "USDC"

  defp positive_amount?(intent) do
    amount = request_amount(intent)

    byte_size(amount) <= 78 and String.to_integer(amount) > 0 and
      String.to_integer(amount) < Integer.pow(2, 256)
  end

  defp request_amount(intent) do
    amount = String.to_integer(intent.exact["money"]["atomic"])
    factor = if intent.exact["side"] == "fiat", do: 10_000, else: 1
    Integer.to_string(amount * factor)
  end

  defp request(intent, context) do
    exact_fiat = intent.exact["side"] == "fiat"
    endpoint = if exact_fiat, do: "best-by-platform", else: "best-by-platform-exact-token"
    amount_key = if exact_fiat, do: "exactFiatAmount", else: "exactTokenAmount"
    # Curator represents both fiat and USDC at six decimals. Contract USD uses cents.
    body = %{
      "fiatCurrency" => intent.fiat["currency"],
      "user" => context.user,
      "recipient" => intent.recipient,
      "destinationChainId" => 8453,
      "destinationToken" => @usdc,
      amount_key => request_amount(intent),
      "mode" => "eligible",
      "quotePreference" => "EXCLUSIVE_BUYER_TEE"
    }

    options = [
      method: :post,
      url: "https://api.zkp2p.xyz/v3/quote/" <> endpoint,
      json: body,
      headers: [{"cache-control", "no-cache, no-store"}],
      retry: false,
      redirect: false,
      receive_timeout: 5_000,
      connect_options: [timeout: 5_000],
      decode_body: false
    ]

    case Req.request(Keyword.merge(options, Map.get(context, :req_options, []))) do
      {:ok, %{status: 200} = response} -> {:ok, response}
      _ -> {:error, :provider_unavailable}
    end
  end

  defp normalize(response, intent, context) do
    now = Map.get(context, :now, &DateTime.utc_now/0).()

    with true <- fresh_response?(response, now),
         {:ok, body} <- decode_body(response.body),
         %{"success" => true, "responseObject" => data} <- body,
         true <- valid_corridor?(data, intent, context),
         {:ok, expiry, 0} <- DateTime.from_iso8601(data["quoteExpiresAt"]),
         true <- DateTime.compare(expiry, now) == :gt,
         true <- DateTime.diff(expiry, now) <= 300,
         platforms when is_list(platforms) and length(platforms) <= 128 <- data["platformQuotes"] do
      entries = Enum.map(platforms, &normalize_platform(&1, data, intent, now, context))

      if Enum.any?(entries, &(&1 == :error)),
        do: {:error, :invalid_provider_response},
        else: {:ok, Enum.reject(entries, &is_nil/1)}
    else
      _ -> {:error, :invalid_provider_response}
    end
  end

  defp decode_body(body) when is_binary(body) and byte_size(body) <= 262_144,
    do: Jason.decode(body)

  defp decode_body(_), do: :error

  defp fresh_response?(response, now) do
    with [date] <- Req.Response.get_header(response, "date"),
         {:ok, observed} <- Req.Utils.parse_http_date(date) do
      Req.Response.get_header(response, "age") in [[], ["0"]] and
        abs(DateTime.diff(now, observed)) <= 30
    else
      _ -> false
    end
  end

  defp valid_corridor?(d, i, c) do
    d["fiat"]["currencyCode"] == i.fiat["currency"] and
      d["token"]["chainId"] == 8453 and d["token"]["decimals"] == 6 and
      String.downcase(d["token"]["token"]) == @usdc and
      String.downcase(d["orchestratorAddress"]) == String.downcase(c.orchestrator) and
      d["mode"] == "eligible"
  end

  defp normalize_platform(%{"supported" => false}, _, _, _, _), do: nil
  defp normalize_platform(%{"supported" => true, "available" => false}, _, _, _, _), do: nil

  defp normalize_platform(
         %{"supported" => true, "available" => true, "platform" => rail, "bestQuote" => q},
         data,
         intent,
         now,
         context
       ) do
    with true <- valid_quote?(q, rail, intent, data),
         {:ok, values} <- quote_values(q, intent),
         {:ok, offer} <- offer_message(rail, values, data, intent, now) do
      if rail in Map.get(context, :ready_rails, []), do: {offer, values}, else: nil
    else
      _ -> :error
    end
  end

  defp normalize_platform(_, _, _, _, _), do: :error

  defp valid_quote?(q, rail, i, d) do
    method_hash = "0x" <> Base.encode16(ExKeccak.hash_256(rail), case: :lower)
    exact_key = if i.exact["side"] == "fiat", do: "fiatAmount", else: "tokenAmount"

    q[exact_key] == request_amount(i) and
      q["intent"]["processorName"] == rail and q["paymentMethod"] in [rail, method_hash] and
      q["intent"]["fiatCurrencyCode"] == i.fiat["currency"] and
      q["intent"]["chainId"] == "8453" and
      String.downcase(q["intent"]["toAddress"]) == String.downcase(i.recipient) and
      String.downcase(q["intent"]["orchestratorAddress"]) ==
        String.downcase(d["orchestratorAddress"]) and
      eligible_quote?(q)
  end

  defp eligible_quote?(q),
    do: q["whitelistEnabled"] == false and q["disputeProtectionRequiresStake"] == false

  defp quote_values(q, intent) do
    keys = ~w(fiatAmount tokenAmount totalFeeAmount)

    if Enum.all?(keys, &Ramp.atomic?(q[&1])) and
         rem(String.to_integer(q["fiatAmount"]), 10_000) == 0 do
      {:ok,
       %{
         "pay" => %{
           "asset" => intent.fiat,
           "atomic" => to_string(div(String.to_integer(q["fiatAmount"]), 10_000))
         },
         "receive" => %{"asset" => intent.crypto, "atomic" => q["tokenAmount"]},
         "fees" => [
           %{
             "code" => "provider_fee",
             "money" => %{"asset" => intent.crypto, "atomic" => q["totalFeeAmount"]}
           }
         ]
       }}
    else
      :error
    end
  end

  defp offer_message(rail, values, data, intent, now) do
    exact = intent.exact
    ref = digest(%{"intent" => Ramp.to_wire(intent), "rail" => rail})

    revision =
      digest(%{
        "values" => values,
        "rail" => rail,
        "requirements" => ["peer_extension"],
        "orchestrator" => String.downcase(data["orchestratorAddress"])
      })

    Ramp.decode(%{
      "contract_version" => "ramp/1",
      "kind" => "offer",
      "provider_id" => "peer",
      "offer_id" => ref,
      "capability_revision" => revision,
      "direction" => intent.direction,
      "fiat" => intent.fiat,
      "crypto" => intent.crypto,
      "rail" => %{"id" => rail, "label" => rail},
      "bounds" => %{
        "measured_in" => exact["side"],
        "minimum" => exact["money"],
        "maximum" => exact["money"]
      },
      "interaction" => %{"presentation" => "popup", "requirement_codes" => ["peer_extension"]},
      "availability" => %{"state" => "available", "valid_until" => data["quoteExpiresAt"]},
      "disclosures" => @disclosures,
      "observed_at" => DateTime.to_iso8601(now)
    })
  end

  defp preview_message(offer, values, intent) do
    Ramp.decode(
      Map.merge(values, %{
        "contract_version" => "ramp/1",
        "kind" => "preview",
        "operation_id" => "op_" <> random_ref(),
        "quote_id" => "quote_" <> random_ref(),
        "offer_id" => offer.offer_id,
        "capability_revision" => offer.capability_revision,
        "request_digest" => "0x" <> digest(Ramp.to_wire(intent)),
        "leg_order" => ["peer"],
        "expires_at" => offer.availability["valid_until"],
        "disclosures" => @disclosures
      })
    )
  end

  # Deterministic Erlang encoding is local only; no digest preimage leaves here.
  defp digest(value),
    do:
      :crypto.hash(:sha256, :erlang.term_to_binary(value, [:deterministic]))
      |> Base.encode16(case: :lower)

  defp random_ref, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
  defp address?(v), do: is_binary(v) and Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, v)
end
