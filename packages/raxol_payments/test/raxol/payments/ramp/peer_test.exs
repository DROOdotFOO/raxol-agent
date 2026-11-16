defmodule Raxol.Payments.Ramp.PeerTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.Actions.Payments
  alias Raxol.Payments.Actions.Payments.{DiscoverRamps, PreviewRamp}
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Peer
  alias Raxol.Payments.Ramps
  @fixture Path.expand("../../../fixtures/ramp/peer_quote.json", __DIR__)
  @body @fixture |> File.read!() |> Jason.decode!()
  @now ~U[2026-11-16 12:00:00Z]

  defmodule TimeoutAdapter do
    @moduledoc false
    def run(request), do: {request, %Req.TransportError{reason: :timeout}}
  end

  defp intent do
    fiat = %{"kind" => "fiat", "currency" => "USD", "decimals" => 2}

    %{
      "contract_version" => "ramp/1",
      "kind" => "intent",
      "direction" => "onramp",
      "fiat" => fiat,
      "crypto" => %{
        "kind" => "crypto",
        "chain_id" => "eip155:8453",
        "asset_id" => @body["responseObject"]["token"]["token"],
        "symbol" => "USDC",
        "decimals" => 6
      },
      "exact" => %{"side" => "fiat", "money" => %{"asset" => fiat, "atomic" => "10000"}},
      "recipient" => "0x0000000000000000000000000000000000000001"
    }
  end

  defp context(body \\ @body, opts \\ []) do
    %{
      user: "0x0000000000000000000000000000000000000001",
      orchestrator: "0x0000000000000000000000000000000000000002",
      interaction_ready: true,
      ready_rails: ["wise"],
      now: fn -> @now end,
      req_options: [
        plug: fn conn ->
          {:ok, raw, conn} = Plug.Conn.read_body(conn)
          sent = Jason.decode!(raw)

          assert conn.request_path ==
                   if(opts[:exact_token],
                     do: "/v3/quote/best-by-platform-exact-token",
                     else: "/v3/quote/best-by-platform"
                   )

          assert sent[if(opts[:exact_token], do: "exactTokenAmount", else: "exactFiatAmount")] ==
                   if(opts[:exact_token], do: "99000000", else: "100000000")

          assert sent["quotePreference"] == "EXCLUSIVE_BUYER_TEE"
          assert not Map.has_key?(sent, "amount")

          conn =
            Plug.Conn.put_resp_header(
              conn,
              "date",
              opts[:date] || "Mon, 16 Nov 2026 12:00:00 GMT"
            )

          conn = if opts[:age], do: Plug.Conn.put_resp_header(conn, "age", opts[:age]), else: conn
          Plug.Conn.send_resp(conn, opts[:status] || 200, Jason.encode!(body))
        end
      ]
    }
  end

  test "fresh discovery and preview requote with exact cents and atomic fees" do
    ctx = context()
    assert {:ok, [offer]} = Ramps.discover(intent(), ctx)
    assert offer.bounds["maximum"]["atomic"] == "10000"

    assert {:ok, preview} =
             Ramps.preview(intent(), offer.offer_id, offer.capability_revision, ctx)

    assert preview.pay["atomic"] == "10000"
    assert preview.receive["atomic"] == "99000000"
    assert preview.fees |> hd() |> get_in(["money", "atomic"]) == "1000000"
    assert preview.leg_order == ["peer"]
    assert {:ok, _} = Ramp.encode(preview)
  end

  test "exact crypto discovery uses the exact-token endpoint without rescaling USDC" do
    base = intent()

    i =
      Map.put(base, "exact", %{
        "side" => "crypto",
        "money" => %{"asset" => base["crypto"], "atomic" => "99000000"}
      })

    assert {:ok, [offer]} = Ramps.discover(i, context(@body, exact_token: true))
    assert offer.bounds["minimum"]["atomic"] == "99000000"

    assert {:ok, preview} =
             Ramps.preview(
               i,
               offer.offer_id,
               offer.capability_revision,
               context(@body, exact_token: true)
             )

    assert preview.pay["atomic"] == "10000"
    assert preview.receive["atomic"] == "99000000"
  end

  test "changed price or fees invalidates revision" do
    assert {:ok, [offer]} = Ramps.discover(intent(), context())

    changed =
      put_in(
        @body,
        ["responseObject", "platformQuotes", Access.at(0), "bestQuote", "tokenAmount"],
        "98000000"
      )

    assert {:error, :capability_changed} =
             Ramps.preview(intent(), offer.offer_id, offer.capability_revision, context(changed))
  end

  for {name, path, value} <- [
        {"expired", ["quoteExpiresAt"], "2026-11-16T11:59:00Z"},
        {"undated", ["quoteExpiresAt"], nil},
        {"wrong token", ["token", "token"], "0x0000000000000000000000000000000000000000"},
        {"wrong decimals", ["token", "decimals"], 18},
        {"wrong currency", ["fiat", "currencyCode"], "EUR"},
        {"unknown eligibility", ["mode"], "future"},
        {"malformed rows", ["platformQuotes"], %{}}
      ] do
    @path path
    @value value
    test "rejects #{name}" do
      body = update_in(@body, ["responseObject"], &put_in(&1, @path, @value))
      assert {:error, :invalid_provider_response} = Ramps.discover(intent(), context(body))
    end
  end

  test "unknown availability, exact mismatch and gated requirements fail closed" do
    for patch <- [
          %{"available" => "unknown"},
          %{
            "bestQuote" =>
              put_in(
                hd(@body["responseObject"]["platformQuotes"])["bestQuote"],
                ["fiatAmount"],
                "100000001"
              )
          },
          %{
            "bestQuote" =>
              put_in(
                hd(@body["responseObject"]["platformQuotes"])["bestQuote"],
                ["disputeProtectionRequiresStake"],
                true
              )
          }
        ] do
      body =
        update_in(
          @body,
          ["responseObject", "platformQuotes", Access.at(0)],
          &Map.merge(&1, patch)
        )

      assert {:error, :invalid_provider_response} = Ramps.discover(intent(), context(body))
    end
  end

  test "unavailable liquidity does not produce an offer" do
    body = put_in(@body, ["responseObject", "platformQuotes", Access.at(0), "available"], false)
    assert {:ok, []} = Ramps.discover(intent(), context(body))
  end

  test "cached and failed responses produce bounded errors" do
    assert {:error, :invalid_provider_response} =
             Ramps.discover(intent(), context(@body, age: "5"))

    assert {:error, :provider_unavailable} = Ramps.discover(intent(), context(@body, status: 503))

    ctx = %{
      context()
      | req_options: [adapter: __MODULE__.TimeoutAdapter]
    }

    assert {:error, :provider_unavailable} = Ramps.discover(intent(), ctx)
  end

  test "caller cannot enable unsupported region, route, asset or browser requirements" do
    assert {:error, :not_supported} = Ramps.discover(Map.put(intent(), "region", "US"), context())

    assert {:error, :not_supported} =
             Ramps.discover(Map.put(intent(), "direction", "offramp"), context())

    assert {:error, :setup_required} =
             Ramps.discover(intent(), %{context() | interaction_ready: false})

    assert {:error, :invalid_request} =
             Ramps.discover(Map.put(intent(), "secret", "discard_me"), context())
  end

  test "actions expose only normalized fields and never echo provider extensions" do
    # Synthetic sentinel has no real credential, handle, URL, or proof content.
    body = Map.put(@body, "private_extension", "MUST_BE_DROPPED")
    ctx = %{ramps: context(body)}
    assert {:ok, %{offers: [offer]}} = DiscoverRamps.run(%{intent: intent()}, ctx)

    assert {:ok, result} =
             PreviewRamp.run(
               %{
                 intent: intent(),
                 offer_ref: offer["offer_id"],
                 revision: offer["capability_revision"]
               },
               ctx
             )

    output = Jason.encode!(result)
    refute output =~ "MUST_BE_DROPPED"
    refute output =~ "bestQuote"
    refute output =~ "toAddress"
    assert DiscoverRamps in Payments.actions()
    assert PreviewRamp in Payments.actions()
  end

  test "recorded public failure remains a bounded unavailable result" do
    recording =
      Path.expand("../../../fixtures/ramp/peer_failure_recording.json", __DIR__)
      |> File.read!()
      |> Jason.decode!()

    assert {:error, :provider_unavailable} =
             Ramps.discover(intent(), context(recording["body"], status: recording["status"]))
  end

  test "stale HTTP observation is rejected even if quote expiry is in the future" do
    assert {:error, :invalid_provider_response} =
             Ramps.discover(intent(), context(@body, date: "Mon, 16 Nov 2026 11:00:00 GMT"))
  end

  test "fractional fiat cents, zero and enormous amounts fail closed" do
    body =
      put_in(
        @body,
        ["responseObject", "platformQuotes", Access.at(0), "bestQuote", "fiatAmount"],
        "100000001"
      )

    assert {:error, :invalid_provider_response} = Ramps.discover(intent(), context(body))

    for atomic <- ["0", String.duplicate("9", 79)] do
      assert {:error, :invalid_request} =
               Ramps.discover(put_in(intent(), ["exact", "money", "atomic"], atomic), context())
    end
  end

  test "live availability cannot upgrade an unready rail" do
    assert {:ok, []} = Ramps.discover(intent(), Map.put(context(), :ready_rails, []))
  end

  test "execution fails closed without trusted runtime dependencies" do
    assert Peer.approve(nil, nil, nil, %{}) == {:error, :provider_unavailable}
    assert Peer.status(nil, %{}) == {:error, :provider_unavailable}
    assert Peer.recover(nil, nil, nil, %{}) == {:error, :invalid_request}
  end
end
