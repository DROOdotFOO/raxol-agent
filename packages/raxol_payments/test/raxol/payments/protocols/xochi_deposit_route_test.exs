defmodule Raxol.Payments.Protocols.XochiDepositRouteTest do
  # A Tron-origin deposit-route quote returns a bare deposit_address; raxol
  # verifies its v3 deposit_attestation against the pinned signer AND the
  # caller's own request before surfacing it, and fails closed otherwise. raxol
  # never sends the Tron funds.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Test.DepositAttestationFixture, as: Fixture
  alias Raxol.Payments.Xochi.Schemas.{DepositRouteRequest, QuoteResponse}

  @priv <<7::256>>
  @now 1_800_000_000
  @deadline 1_900_000_000

  defp d, do: Fixture.defaults()
  defp signer, do: Fixture.address(@priv)

  defp request(overrides \\ %{}) do
    struct!(
      %DepositRouteRequest{
        wallet: d().tron_wallet,
        from_chain_id: 728_126_428,
        to_chain_id: 8453,
        from_token: d().tron_usdt,
        to_token: d().to_token,
        from_amount: "1000000",
        recipient_address: d().recipient
      },
      overrides
    )
  end

  # The deal the venue signed: by default exactly what request/0 asked for.
  defp signed_fields(overrides \\ %{}),
    do: Fixture.fields(Map.merge(%{deposit_deadline: @deadline}, overrides))

  defp quote_body(fields, overrides \\ %{}) do
    Map.merge(
      %{
        "intent_id" => fields.intent_id,
        "quote_id" => fields.quote_id,
        "can_solve" => true,
        "to_amount" => fields.to_amount,
        "min_to_amount" => fields.min_to_amount,
        "deposit_address" => fields.deposit_address,
        "deposit_attestation" => Fixture.sign(fields, @priv),
        "deposit_deadline" => fields.deposit_deadline
      },
      overrides
    )
  end

  defp config(body) do
    plug = fn conn ->
      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://xochi.test", req_options: [plug: plug]}
  end

  defp opts(overrides \\ []) do
    Keyword.merge(
      [
        deposit_attestation_signer: signer(),
        capabilities: Fixture.capabilities(),
        clock: fn -> @now end
      ],
      overrides
    )
  end

  defp verify(body, req \\ request(), opts \\ opts()) do
    Xochi.verify_deposit_route(
      %{base_url: "https://xochi.test"},
      req,
      QuoteResponse.from_json(body),
      opts
    )
  end

  describe "deposit_route_quote/3" do
    test "verifies the v3 attestation and returns the attested deal" do
      assert {:ok, instructions} =
               Xochi.deposit_route_quote(config(quote_body(signed_fields())), request(), opts())

      assert instructions.intent_id == "xi_dep_1"
      assert instructions.quote_id == "xq_dep_1"
      assert instructions.deposit_address == d().deposit_address
      assert instructions.deposit_deadline == @deadline
      assert instructions.from_chain_id == 728_126_428
      assert instructions.from_token == d().tron_usdt
      assert instructions.from_amount == "1000000"
      assert instructions.to_chain_id == 8453
      assert instructions.to_token == d().to_token
      assert instructions.recipient_address == d().recipient
      assert instructions.to_amount == "995000"
      assert instructions.min_to_amount == "990025"
      assert instructions.refund_address == nil
      assert instructions.settlement_preference == "public"
    end

    test "surfaces an unsolvable quote as an error" do
      body = quote_body(signed_fields(), %{"can_solve" => false, "reason" => "no liquidity"})

      assert {:error, {:not_solvable, "no liquidity"}} =
               Xochi.deposit_route_quote(config(body), request(), opts())
    end
  end

  describe "verify_deposit_route/4 binds every v3 field to the request" do
    # Each row is a genuine attestation the pinned signer issued -- for a deal
    # other than the one this caller asked for. Riddler does not echo the
    # caller-supplied half, so it is rebuilt from the request and mismatches.
    @foreign [
      depositor: %{wallet: "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"},
      recipient: %{recipient: "0x" <> String.duplicate("cd", 20)},
      destination_chain: %{to_chain_id: 1},
      destination_token: %{to_token: "0xa0b86991c6218b36c1d19d4a2e9eb0ce3606eb48"},
      origin_chain: %{from_chain_id: 2_494_104_990},
      origin_token: %{from_token: "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"},
      from_amount: %{from_amount: "2000000"},
      refund: %{refund_address: "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"},
      stealth_key: %{stealth_spending_pub_key: "0x02" <> String.duplicate("ab", 32)},
      settlement: %{settlement_preference: "shielded"}
    ]

    for {name, foreign} <- @foreign do
      @tag foreign: foreign
      test "refuses a genuine attestation for another #{name}", %{foreign: foreign} do
        body = quote_body(signed_fields(foreign))
        assert {:error, :attestation_mismatch} = verify(body)
      end
    end

    # Server-chosen values the quote states but the attestation does not cover.
    @substituted [
      {"deposit_address", "TJYeasTPa6gpEEfYGfp5LQjWXmdZQBpLzX"},
      {"deposit_deadline", @deadline + 1},
      {"intent_id", "xi_other"},
      {"quote_id", "xq_other"},
      {"to_amount", "995001"},
      {"min_to_amount", "990026"}
    ]

    for {key, value} <- @substituted do
      @tag key: key, value: value
      test "refuses a substituted #{key}", %{key: key, value: value} do
        body = quote_body(signed_fields(), %{key => value})
        assert {:error, :attestation_mismatch} = verify(body)
      end
    end

    test "binds an optional refund address and stealth meta-address as sent" do
      refund = d().tron_usdt
      spend = "0x02" <> String.duplicate("ab", 32)
      view = "0x03" <> String.duplicate("cd", 32)

      deal = %{
        refund_address: refund,
        stealth_spending_pub_key: spend,
        stealth_viewing_pub_key: view,
        settlement_preference: "stealth"
      }

      req =
        request(%{
          refund_address: refund,
          stealth_spending_pub_key: spend,
          stealth_viewing_pub_key: view,
          settlement_preference: "stealth"
        })

      assert {:ok, %{refund_address: ^refund}} = verify(quote_body(signed_fields(deal)), req)

      # The same request against an attestation that omits the refund address.
      assert {:error, :attestation_mismatch} =
               verify(quote_body(signed_fields(%{deal | refund_address: nil})), req)
    end

    test "validates the request itself, since it is half the signed message" do
      body = quote_body(signed_fields(%{recipient: d().tron_wallet}))

      assert {:error, {:invalid_recipient_address, _}} =
               verify(body, request(%{recipient_address: nil}))

      canton = "0xAlice::1220" <> String.duplicate("3e", 32)

      assert {:error, {:invalid_recipient_address, _}} =
               verify(
                 quote_body(signed_fields(%{recipient: canton})),
                 request(%{recipient_address: canton})
               )
    end
  end

  describe "verify_deposit_route/4 refusals before recovery" do
    test "refuses a v1 venue by its advertised version" do
      opts = opts(capabilities: Fixture.capabilities(version: "xochi-deposit-attestation:v1"))

      assert {:error, {:unsupported_deposit_attestation_version, "xochi-deposit-attestation:v1"}} =
               verify(quote_body(signed_fields()), request(), opts)
    end

    test "refuses a matrix that advertises no version (the static fallback)" do
      opts = opts(capabilities: Fixture.capabilities(version: nil))

      assert {:error, {:unsupported_deposit_attestation_version, nil}} =
               verify(quote_body(signed_fields()), request(), opts)
    end

    test "refuses an attested deadline at or before the injected clock" do
      body = quote_body(signed_fields(%{deposit_deadline: @now}))

      assert {:error, {:deposit_deadline_passed, %{deadline: @now, now: @now}}} = verify(body)
      assert {:ok, _} = verify(body, request(), opts(clock: fn -> @now - 1 end))
    end

    test "refuses a quote with no deadline" do
      body = quote_body(signed_fields(%{deposit_deadline: nil}))
      assert {:error, :missing_deposit_deadline} = verify(body)
    end

    test "refuses an absent, signed or fractional amount rather than reformatting it" do
      for {key, value} <- [{"min_to_amount", nil}, {"to_amount", "-1"}, {"to_amount", 995_000.5}] do
        field = String.to_existing_atom(key)

        assert {:error, {:invalid_quote_amount, %{field: ^field, value: ^value}}} =
                 verify(quote_body(signed_fields(), %{key => value}))
      end
    end

    test "refuses an amount longer than any uint256 before parsing it" do
      huge = String.duplicate("9", 79)

      assert {:error, {:invalid_quote_amount, %{field: :to_amount, value: ^huge}}} =
               verify(quote_body(signed_fields(), %{"to_amount" => huge}))

      too_big = Integer.pow(10, 78)

      assert {:error, {:invalid_quote_amount, %{field: :min_to_amount}}} =
               verify(quote_body(signed_fields(), %{"min_to_amount" => too_big}))

      max = String.duplicate("9", 78)
      deal = signed_fields(%{to_amount: max, min_to_amount: max})
      assert {:ok, %{to_amount: ^max}} = verify(quote_body(deal))
    end

    test "accepts JSON-integer amounts as their decimal string" do
      body = quote_body(signed_fields(), %{"to_amount" => 995_000, "min_to_amount" => 990_025})
      assert {:ok, %{to_amount: "995000", min_to_amount: "990025"}} = verify(body)
    end

    test "refuses a min_to_amount above to_amount" do
      fields = signed_fields(%{min_to_amount: "995001"})

      assert {:error,
              {:inconsistent_quote_amounts, %{to_amount: "995000", min_to_amount: "995001"}}} =
               verify(quote_body(fields))
    end

    test "refuses a recipient that is the destination token contract" do
      token = d().to_token
      req = request(%{recipient_address: String.downcase(token)})
      body = quote_body(signed_fields(%{recipient: token}))

      assert {:error, :recipient_is_destination_token} = verify(body, req)
    end

    test "refuses an empty intent id" do
      body = quote_body(signed_fields(), %{"intent_id" => ""})
      assert {:error, {:invalid_quote_id, %{field: :intent_id, value: ""}}} = verify(body)
    end

    test "refuses a non-deposit-route quote" do
      body = quote_body(signed_fields(), %{"deposit_address" => nil})
      assert {:error, :not_a_deposit_route} = verify(body)
    end

    test "refuses a quote with no attestation" do
      body = quote_body(signed_fields(), %{"deposit_attestation" => nil})
      assert {:error, :missing_attestation} = verify(body)
    end

    test "refuses another signer" do
      assert {:error, :attestation_mismatch} =
               verify(
                 quote_body(signed_fields()),
                 request(),
                 opts(deposit_attestation_signer: "0x000000000000000000000000000000000000dead")
               )
    end
  end
end
