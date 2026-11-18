defmodule Raxol.Payments.Ramp.Peer.Discovery do
  @moduledoc "Fresh approximate maker estimates from public protocol/oracle/indexer data."
  alias Raxol.Payments.{Checkpoint, Ramp}
  alias Raxol.Payments.Ramp.Peer.{ABI, LiveIO, LiveReads, Mapping}

  @disclosures %{
    "public_state" => ["base_settlement", "maker_estimate", "asynchronous_partial_fills"],
    "identity_visible_to" => ["fiat_counterparty", "peer"],
    "liveness_dependencies" => ["peer", "peer_tee", "base"]
  }

  def capabilities(%{intent: %Ramp.Intent{direction: "offramp"} = intent} = context) do
    with {:ok, _} <- Ramp.decode(Ramp.to_wire(intent)),
         true <- not is_nil(context[:maker_indexer]) do
      rails = Map.get(context, :maker_rails, Map.keys(ABI.config()["rails"]))
      {:ok, Enum.map(rails, &offer(intent, &1, context)) |> Enum.filter(&is_struct/1)}
    else
      _ -> {:error, :capability_unavailable}
    end
  rescue
    _ -> {:error, :capability_unavailable}
  end

  def preview(intent, offer_id, revision, context) do
    operation = operation_ref(context)
    context = Map.put(context, :intent, intent)

    context =
      if context[:resume_operation_ref],
        do: Map.put(context, :maker_operation, operation),
        else: context

    with {:ok, offers} <- capabilities(context),
         %Ramp.Offer{} = offer <- Enum.find(offers, &(&1.offer_id == offer_id)),
         true <- offer.capability_revision == revision,
         "available" <- offer.availability["state"],
         rail <- offer.rail["id"],
         terms <- LiveReads.terms!(context, intent, rail),
         true <- revision(terms, "available") == revision,
         {pay, receive} <- amounts(intent, terms),
         true <- pay >= terms.minimum and pay <= terms.maximum and receive > 0 do
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "preview",
        "operation_id" => operation,
        "quote_id" => "quote_" <> random(),
        "offer_id" => offer_id,
        "capability_revision" => revision,
        "request_digest" => "0x" <> LiveIO.digest(Ramp.to_wire(intent)),
        "pay" => money(intent.crypto, pay),
        "receive" => money(intent.fiat, receive),
        "fees" => [],
        "expires_at" => DateTime.to_iso8601(terms.expires_at),
        "leg_order" => ["peer"],
        "disclosures" => @disclosures
      })
    else
      _ -> {:error, :capability_changed}
    end
  rescue
    _ -> {:error, :capability_unavailable}
  end

  defp operation_ref(%{resume_operation_ref: operation} = context) do
    {:ok, %{snapshot: %{peer: %{"state" => "action_required"}}}} =
      Checkpoint.fetch(context.checkpoint, "peer_maker:" <> operation)

    {:ok, mapping} = Mapping.fetch_maker(context, operation)

    true =
      mapping[:approval_confirmed] == true and is_nil(mapping[:deposit_id]) and
        is_nil(mapping[:creation_tx_hash])

    operation
  end

  defp operation_ref(_), do: "op_" <> random()

  defp offer(intent, rail, context) do
    terms = LiveReads.terms!(context, intent, rail)
    {pay, receive} = amounts(intent, terms)
    true = pay >= terms.minimum and pay <= terms.maximum and receive > 0
    registration = get_in(context, [:maker_registrations, rail]) || %{}

    ready =
      registration[:own_account_verified] == true and
        LiveReads.same?(registration[:wallet], intent.recipient) and
        rail not in ["wise", "paypal", "alipay", "venmo", "cashapp", "xmoney"]

    availability =
      if ready,
        do: %{"state" => "available", "valid_until" => DateTime.to_iso8601(terms.expires_at)},
        else: %{"state" => "setup_required", "requirement_codes" => ["maker_own_account_setup"]}

    build_offer(intent, rail, context, terms, availability)
  rescue
    _ ->
      build_offer(intent, rail, context, %{minimum: 0, maximum: 0, rate: 0}, %{
        "state" => "availability_unknown",
        "reason_code" => "capability_unavailable"
      })
  end

  defp build_offer(intent, rail, context, terms, availability) do
    revision = revision(terms, availability["state"])

    {:ok, offer} =
      Ramp.decode(%{
        "contract_version" => "ramp/1",
        "kind" => "offer",
        "provider_id" => "peer",
        "offer_id" => LiveIO.offer_ref(intent, rail),
        "capability_revision" => revision,
        "direction" => "offramp",
        "fiat" => intent.fiat,
        "crypto" => intent.crypto,
        "rail" => %{"id" => rail, "label" => rail},
        "bounds" => %{
          "measured_in" => "crypto",
          "minimum" => money(intent.crypto, terms.minimum),
          "maximum" => money(intent.crypto, terms.maximum)
        },
        "interaction" => %{
          "presentation" => "manual",
          "requirement_codes" => ["own_account", "wallet_approval"]
        },
        "availability" => availability,
        "disclosures" => @disclosures,
        "observed_at" => DateTime.to_iso8601(LiveReads.now(context))
      })

    offer
  end

  @doc false
  def revision(terms, state), do: LiveIO.digest([Map.drop(terms, [:expires_at]), state])

  defp amounts(intent, terms) do
    exact = LiveReads.uint!(intent.exact["money"]["atomic"])
    scale = Integer.pow(10, 6 - intent.fiat["decimals"])

    pay =
      if intent.exact["side"] == "crypto",
        do: exact,
        else: div(exact * scale * Integer.pow(10, 18) + terms.rate - 1, terms.rate)

    {pay, String.to_integer(LiveIO.expected_receive(intent, pay, terms.rate))}
  end

  defp money(asset, value), do: %{"asset" => asset, "atomic" => to_string(value)}
  defp random, do: :crypto.strong_rand_bytes(16) |> Base.url_encode64(padding: false)
end
