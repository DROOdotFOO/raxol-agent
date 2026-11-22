defmodule Raxol.Web3.Backend.Canton.Holdings do
  @moduledoc """
  `POST /v0/holdings/state` paging and the Amulet holding shape for
  `Raxol.Web3.Backend.Canton`. A cursor carries the snapshot it was minted
  against (`migration_id`, `record_time`) beside the `after` offset, so a
  held cursor keeps walking that snapshot; `page_size` is ours and is never
  taken from a cursor.
  """

  import Raxol.Web3.Backend.Decode, only: [dig: 2, page_rows: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Canton.Scan
  alias Raxol.Web3.Backend.Paging
  alias Raxol.Web3.Cursor

  # Splice's Daml `Decimal`, and measured: every amulet figure in every response
  # probed carries exactly ten fractional digits.
  @amulet_decimals 10

  # `page_size` is a REQUIRED field on `POST /v0/holdings/state`, measured
  # 2026-09-14: omitting it answers 400 with `DecodingFailure at .page_size:
  # Missing required field`, which is the one field a specification reader
  # would assume optional. The upstream's own ceiling is 1000, measured the
  # same way: 1001 answers 400 naming the limit. 100 is this backend's choice
  # inside that ceiling, and it is a judgement rather than a measurement: a
  # party typically holds ONE consolidated Amulet contract, so a page rarely
  # fills, and the cost of a larger one is bytes for a walk that will not
  # happen. The ceiling enforces itself below rather than being a comment, so
  # raising the page size past what the upstream accepts fails the build rather
  # than a request.
  @page_size 100
  @max_page_size 1000

  if @page_size > @max_page_size do
    raise "page_size #{@page_size} exceeds the upstream ceiling of #{@max_page_size}, " <>
            "measured 2026-09-14 on POST /v0/holdings/state"
  end

  # Without a cursor the snapshot is resolved live; with one it comes from
  # inside the signed payload, which is what pins a walk to the snapshot it
  # started against rather than letting it drift onto today's. `page_size` is
  # added here rather than carried in the cursor, deliberately: it is a
  # required field and it is ours, so a held cursor cannot choose how much of
  # somebody else's budget the next request spends.
  @doc "The `holdings/state` request body for page one (live snapshot) or a held cursor."
  @spec request(Scan.state(), String.t(), Cursor.t() | nil) ::
          {:ok, map()} | {:error, Backend.error()}
  def request(state, party, nil) do
    with {:ok, snapshot} <- Scan.snapshot(state) do
      {:ok, holdings_body(snapshot, party)}
    end
  end

  def request(state, party, cursor) do
    with {:ok, params} <-
           Paging.cursor_params(cursor, Paging.origin_id(state.scan_url), :canton_holdings_state) do
      {:ok, holdings_body(params, party)}
    end
  end

  defp holdings_body(params, party) do
    params
    |> Map.put("owner_party_ids", [party])
    |> Map.put("page_size", @page_size)
  end

  # `next` is minted from the token's presence and never from whether the page
  # had items: measured 2026-09-14, a page with zero `created_events` came back
  # with a non-null `next_page_token`, and reading that as the end of the walk
  # would report a party as holding nothing while its holdings were one page
  # further on.
  @doc "A `holdings/state` response as a page; `next` follows the token, not the item count."
  @spec page(Scan.state(), map(), map(), %{symbol: term(), name: term()}) ::
          {:ok, Backend.page(Backend.token_balance())} | {:error, Backend.error()}
  def page(state, request, body, symbol) do
    with {:ok, rows} <- page_rows(body["created_events"]),
         {:ok, items} <- Backend.map_rows(rows, &token_balance(&1, symbol), :token_balance_row) do
      {:ok, %{items: items, next: next_cursor(state, request, body["next_page_token"])}}
    end
  end

  defp next_cursor(_state, _request, nil), do: nil

  defp next_cursor(state, request, token) do
    request
    |> Map.take(["migration_id", "record_time"])
    |> Map.put("after", token)
    |> Cursor.encode(Paging.origin_id(state.scan_url), :canton_holdings_state)
  end

  # The asset catalog, `:catalog` class: the amulet's name and acronym are an
  # upstream release's worth of stable and the cost of a stale row is a label
  # rather than a number.
  @doc "The amulet's acronym and name, `:catalog` cached."
  @spec names(Scan.state()) :: {:ok, %{symbol: term(), name: term()}} | {:error, Backend.error()}
  def names(state) do
    with {:ok, body} <- Scan.get(state, :instance_names, %{}, :catalog) do
      {:ok, %{symbol: body["amulet_name_acronym"], name: body["amulet_name"]}}
    end
  end

  # The Amulet contract's own recorded amount. A caller summing a page gets the
  # gross holding, which the upstream's `total_coin_holdings` agrees with to the
  # digit; the accrued holding fee is a party-level figure and is not netted out
  # here. `template_id` is the asset's identity on this chain, which is a Daml
  # template rather than a contract address.
  defp token_balance(event, names) when is_map(event) do
    {:ok,
     %{
       token: %{
         address: event["template_id"],
         symbol: names.symbol,
         name: names.name,
         decimals: @amulet_decimals,
         type: event["package_name"]
       },
       amount: event |> dig(["create_arguments", "amount", "initialAmount"]) |> amulet(),
       token_id: event["contract_id"]
     }}
  end

  defp token_balance(_event, _names), do: {:error, {:decode_failed, :token_balance_row}}

  # Reported in the smallest unit, the way wei and lamports are. A figure with
  # more than ten fractional digits is a shape change rather than a rounding
  # opportunity, so it is `nil`.
  @doc "A ten-decimal amulet figure in the smallest unit, or `nil`."
  @spec amulet(term()) :: non_neg_integer() | nil
  def amulet(nil), do: nil

  def amulet(value) when is_binary(value) do
    case String.split(value, ".", parts: 2) do
      [whole] -> units(whole, "")
      [whole, fraction] -> units(whole, fraction)
    end
  end

  def amulet(_other), do: nil

  defp units(whole, fraction) when byte_size(fraction) <= @amulet_decimals do
    padding = String.duplicate("0", @amulet_decimals - byte_size(fraction))

    case Integer.parse(whole <> fraction <> padding) do
      {units, ""} when units >= 0 -> units
      _unparseable -> nil
    end
  end

  defp units(_whole, _fraction), do: nil
end
