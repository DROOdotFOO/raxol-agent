defmodule Raxol.Payments.Ramp.Coherence do
  @moduledoc false
  @ended ~w(completed failed refunded skipped)

  def same_asset?(%{"kind" => "fiat"} = a, %{"kind" => "fiat"} = b),
    do: a["currency"] == b["currency"] and a["decimals"] == b["decimals"]

  def same_asset?(%{"kind" => "crypto"} = a, %{"kind" => "crypto"} = b) do
    a["chain_id"] == b["chain_id"] and address(a) == address(b) and
      a["decimals"] == b["decimals"] and a["symbol"] == b["symbol"]
  end

  def same_asset?(_, _), do: false
  def address(a), do: a["asset_id"] |> String.split(":") |> List.last() |> String.downcase()

  def valid?(value), do: Enum.all?(assets(value), &on_chain?/1) and coherent?(value)

  def terminal?(s) do
    s |> legs() |> Enum.all?(fn leg -> leg["state"] in @ended and not recoverable?(leg) end)
  end

  def recoverable?(leg), do: leg["state"] == "failed" and leg["recoverable"] == true
  def legs(s), do: Enum.reject([s["peer"], s["xochi"]], &is_nil/1)

  defp on_chain?(%{"kind" => "crypto", "asset_id" => id, "chain_id" => chain}),
    do: not String.contains?(id, "/") or hd(String.split(id, "/")) == chain

  defp on_chain?(_), do: true

  defp assets(%{"kind" => "offer"} = v),
    do: [v["fiat"], v["crypto"], v["bounds"]["minimum"]["asset"], v["bounds"]["maximum"]["asset"]]

  defp assets(%{"kind" => "intent"} = v),
    do:
      [v["fiat"], v["crypto"], v["exact"]["money"]["asset"]] ++
        if(v["route"], do: [v["route"]["from"], v["route"]["to"]], else: [])

  defp assets(%{"kind" => "preview"} = v),
    do: [v["pay"]["asset"], v["receive"]["asset"]] ++ Enum.map(v["fees"], & &1["money"]["asset"])

  defp assets(_), do: []

  defp coherent?(%{"kind" => "offer"} = v) do
    b = v["bounds"]
    a = v[b["measured_in"]]

    same_asset?(a, b["minimum"]["asset"]) and same_asset?(a, b["maximum"]["asset"]) and
      String.to_integer(b["minimum"]["atomic"]) <= String.to_integer(b["maximum"]["atomic"]) and
      (v["availability"]["state"] != "available" or
         after?(v["availability"]["valid_until"], v["observed_at"]))
  end

  defp coherent?(%{"kind" => "intent"} = v) do
    same_asset?(v["exact"]["money"]["asset"], v[v["exact"]["side"]]) and route_valid?(v)
  end

  defp coherent?(%{"kind" => "preview"} = v) do
    pay = v["pay"]["asset"]
    receive = v["receive"]["asset"]

    pay["kind"] != receive["kind"] and
      (length(v["leg_order"]) != 2 or
         hd(v["leg_order"]) == "peer" == (pay["kind"] == "fiat")) and
      Enum.all?(v["fees"], fn f ->
        same_asset?(f["money"]["asset"], pay) or same_asset?(f["money"]["asset"], receive)
      end)
  end

  defp coherent?(%{"kind" => "snapshot"} = v) do
    actions = v["allowed_actions"]

    v["leg_order"] == expected_order(v) and v["terminal"] == terminal?(v) and
      length(actions) == length(Enum.uniq(actions)) and snapshot_actions?(v, actions)
  end

  defp coherent?(%{"kind" => "command"} = v),
    do: v["action"] not in ~w(approve execute_route) or Map.has_key?(v, "quote_id")

  defp coherent?(%{"kind" => "error"}), do: true

  defp expected_order(%{"xochi" => _, "direction" => "onramp"}), do: ["peer", "xochi"]
  defp expected_order(%{"xochi" => _}), do: ["xochi", "peer"]
  defp expected_order(_), do: ["peer"]

  defp snapshot_actions?(v, actions) do
    (v["xochi"] != nil or not Enum.any?(actions, &String.ends_with?(&1, "route"))) and
      (not Enum.any?(legs(v), &(&1["state"] == "in_doubt")) or
         Enum.all?(actions, &(&1 == "check_status"))) and
      (not v["terminal"] or actions == [])
  end

  defp route_valid?(%{"route" => route} = v) do
    side = if v["direction"] == "onramp", do: "from", else: "to"

    same_asset?(route[side], v["crypto"]) and
      String.downcase(route["recipient"]) == String.downcase(v["recipient"])
  end

  defp route_valid?(_), do: true

  defp after?(left, right) do
    with {:ok, a, _} <- DateTime.from_iso8601(left),
         {:ok, b, _} <- DateTime.from_iso8601(right),
         do: DateTime.compare(a, b) == :gt
  end
end
