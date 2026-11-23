defmodule Raxol.Payments.Actions.Payments.ExecuteDepositRouteTest do
  # The deposit-route action fetches a Tron-origin quote and verifies its
  # deposit_attestation before returning the deposit instructions. raxol never
  # sends the funds; the agent's own Tron wallet funds the verified address.
  use ExUnit.Case, async: true

  alias Raxol.Payments.Actions.Payments
  alias Raxol.Payments.Actions.Payments.ExecuteDepositRoute
  alias Raxol.Payments.Checkpoint
  alias Raxol.Payments.Test.DepositAttestationFixture, as: Fixture
  alias Raxol.Payments.Xochi.SettlementState

  @tron_usdt "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @tron_wallet "TLa2f6VPqDgRE67v1736s7bJ8Ray5wYjU7"
  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @evm_recipient "0x" <> String.duplicate("ab", 20)
  @base_usdc "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  @intent_id "xi_dep_1"
  @quote_id "xq_dep_1"
  @amount "1000000"
  @priv <<9::256>>
  @now 1_800_000_000

  defp params(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: @tron_wallet,
        from_chain_id: 728_126_428,
        to_chain_id: 8453,
        from_token: @tron_usdt,
        to_token: @base_usdc,
        amount_atomic: @amount,
        recipient_address: @evm_recipient,
        slippage_bps: 50
      },
      overrides
    )
  end

  defp signer_address, do: Fixture.address(@priv)

  # Context every verifying run needs: a v3 matrix and a clock before the
  # attested deadline.
  defp ctx(overrides) do
    Map.merge(%{capabilities: Fixture.capabilities(), clock: fn -> @now end}, overrides)
  end

  # A stub venue that does what Riddler does: attest the deal it was asked
  # for -- the request's own fields plus the quote's server-chosen values.
  # `quote` overrides the served body, and the venue signs what it serves.
  defp config(quote \\ %{}) do
    test = self()

    plug = fn conn ->
      send(test, :quote_requested)
      {:ok, raw, conn} = Plug.Conn.read_body(conn)
      req = Jason.decode!(raw)
      body = quote_body(req, quote)

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://xochi.test", req_options: [plug: plug]}
  end

  defp quote_body(req, quote) do
    served =
      Map.merge(
        %{
          "intent_id" => @intent_id,
          "quote_id" => @quote_id,
          "can_solve" => true,
          "to_amount" => "995000",
          "min_to_amount" => "990025",
          "deposit_address" => @deposit_addr,
          "deposit_deadline" => 1_900_000_000
        },
        quote
      )

    deal = %{
      intent_id: served["intent_id"],
      quote_id: served["quote_id"],
      wallet: req["wallet"],
      from_chain_id: req["from_chain_id"],
      from_token: req["from_token"],
      from_amount: req["from_amount"],
      deposit_address: served["deposit_address"],
      deposit_deadline: served["deposit_deadline"],
      refund_address: req["refund_address"],
      to_chain_id: req["to_chain_id"],
      to_token: req["to_token"],
      to_amount: decimal(served["to_amount"]),
      min_to_amount: decimal(served["min_to_amount"]),
      recipient: req["recipient_address"] || req["wallet"],
      stealth_spending_pub_key: req["stealth_spending_pub_key"],
      stealth_viewing_pub_key: req["stealth_viewing_pub_key"],
      settlement_preference: req["settlement_preference"]
    }

    Map.put(served, "deposit_attestation", Fixture.sign(deal, @priv))
  end

  # Riddler signs the decimal string of the amount it serves.
  defp decimal(n) when is_float(n), do: n |> trunc() |> Integer.to_string()
  defp decimal(n), do: to_string(n)

  describe "run/2" do
    test "verifies the attestation and returns the deposit instructions" do
      ctx = ctx(%{xochi_config: config(), deposit_attestation_signer: signer_address()})

      assert {:ok, result} = ExecuteDepositRoute.run(params(), ctx)
      assert result.intent_id == @intent_id
      assert result.deposit_address == @deposit_addr
      assert result.deposit_deadline == 1_900_000_000
      assert result.from_amount == @amount
      assert result.recipient_address == @evm_recipient
    end

    test "binds an atom agent principal for the later poll action" do
      store = Checkpoint.ETS.new()

      ctx =
        ctx(%{
          xochi_config: config(),
          deposit_attestation_signer: signer_address(),
          checkpoint: store,
          agent_id: :route_agent
        })

      assert {:ok, %{intent_id: @intent_id}} = ExecuteDepositRoute.run(params(), ctx)

      assert {:ok, %{principal: "agent:route_agent"}} =
               SettlementState.owner(
                 store,
                 config().base_url,
                 "agent:route_agent",
                 @intent_id,
                 1_800_000_000
               )
    end

    test "fails closed when the attestation does not recover to the pinned signer" do
      ctx =
        ctx(%{
          xochi_config: config(),
          deposit_attestation_signer: "0x000000000000000000000000000000000000dead"
        })

      assert {:error, :attestation_mismatch} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "fails closed when no signer is pinned" do
      ctx = ctx(%{xochi_config: config()})
      assert {:error, :deposit_signer_unpinned} = ExecuteDepositRoute.run(params(), ctx)
    end

    test "refuses a v1 venue by its advertised version" do
      ctx =
        ctx(%{
          xochi_config: config(),
          deposit_attestation_signer: signer_address(),
          capabilities: Fixture.capabilities(version: "xochi-deposit-attestation:v1")
        })

      assert {:error, {:unsupported_deposit_attestation_version, "xochi-deposit-attestation:v1"}} =
               ExecuteDepositRoute.run(params(), ctx)
    end

    test "refuses once the attested deadline has passed on the context clock" do
      ctx =
        ctx(%{
          xochi_config: config(),
          deposit_attestation_signer: signer_address(),
          clock: fn -> 1_900_000_000 end
        })

      assert {:error, {:deposit_deadline_passed, %{deadline: 1_900_000_000}}} =
               ExecuteDepositRoute.run(params(), ctx)
    end

    test "rejects an EVM origin (deposit routes are non-EVM only)" do
      ctx = ctx(%{xochi_config: config(), deposit_attestation_signer: signer_address()})

      assert {:error, {:unsupported_origin_vm, _}} =
               ExecuteDepositRoute.run(params(%{from_chain_id: 8453}), ctx)
    end

    test "errors when :xochi_config is absent from the context" do
      assert {:error, {:missing_context, :xochi_config}} =
               ExecuteDepositRoute.run(params(), %{})
    end

    # ADR-0040 decision 6: no FX rate gates a conversion yet, so a non-USD
    # destination has no par to floor against and must carry its own.
    @eure_base "0xbf6e2966A9C3D99C9E4D069E04f7Bdb9C8aa762C"

    test "a non-USD destination without a positive min_to_amount is refused before any quote" do
      ctx = ctx(%{xochi_config: config(), deposit_attestation_signer: signer_address()})

      for floor <- [nil, "0", " 0 "] do
        assert {:error, {:unpriced_asset, %{side: :destination, chain_id: 8453, peg: "EUR"}}} =
                 ExecuteDepositRoute.run(
                   params(%{to_token: @eure_base, min_to_amount: floor}),
                   ctx
                 )
      end

      refute_received :quote_requested
    end

    # 1 USDT (6 decimals) into EURe (18 decimals): 0.87 EURe estimated, 0.865
    # stated as the minimum.
    @eure_quote %{
      "to_amount" => "870000000000000000",
      "min_to_amount" => "865000000000000000"
    }

    test "a quote is judged on the lowest amount it states" do
      ctx =
        ctx(%{xochi_config: config(@eure_quote), deposit_attestation_signer: signer_address()})

      run = &ExecuteDepositRoute.run(params(%{to_token: @eure_base, min_to_amount: &1}), ctx)

      assert {:ok, %{deposit_address: @deposit_addr, min_to_amount: "865000000000000000"}} =
               run.("865000000000000000")

      # Below the estimate, above the stated minimum.
      assert {:error,
              {:delivery_below_floor,
               %{floor: 866_000_000_000_000_000, lowest: 865_000_000_000_000_000}}} =
               run.("866000000000000000")

      # Authoritative for a dollar destination too, judged on the stated minimum.
      ctx = ctx(%{xochi_config: config(), deposit_attestation_signer: signer_address()})

      assert {:error,
              {:delivery_below_floor,
               %{to_amount: "995000", min_to_amount: "990025", lowest: 990_025}}} =
               ExecuteDepositRoute.run(params(%{min_to_amount: "990026"}), ctx)
    end

    test "a stated minimum above the estimate is refused, even when genuinely signed" do
      # A hostile quote: 1 wei estimated, a reassuring minimum beside it.
      quote = %{"to_amount" => "1", "min_to_amount" => "900000000000000000"}
      ctx = ctx(%{xochi_config: config(quote), deposit_attestation_signer: signer_address()})

      assert {:error,
              {:inconsistent_quote_amounts,
               %{to_amount: "1", min_to_amount: "900000000000000000"}}} =
               ExecuteDepositRoute.run(
                 params(%{to_token: @eure_base, min_to_amount: "850000000000000000"}),
                 ctx
               )
    end

    test "a low estimate below the floor is refused" do
      quote = %{"to_amount" => "1", "min_to_amount" => "1"}
      ctx = ctx(%{xochi_config: config(quote), deposit_attestation_signer: signer_address()})

      assert {:error, {:delivery_below_floor, %{lowest: 1}}} =
               ExecuteDepositRoute.run(
                 params(%{to_token: @eure_base, min_to_amount: "850000000000000000"}),
                 ctx
               )
    end

    test "amounts served as JSON numbers come back as the strings the output declares" do
      quote = %{
        "to_amount" => 870_000_000_000_000_000,
        "min_to_amount" => 865_000_000_000_000_000
      }

      ctx = ctx(%{xochi_config: config(quote), deposit_attestation_signer: signer_address()})

      # Through `call/2`, which validates the output schema: an integer
      # `min_to_amount` passed the floor and then failed `:string`.
      assert {:ok, %{to_amount: "870000000000000000", min_to_amount: "865000000000000000"}} =
               ExecuteDepositRoute.call(
                 params(%{to_token: @eure_base, min_to_amount: "865000000000000000"}),
                 ctx
               )
    end

    test "an integral JSON float comes back as its integer string" do
      ctx =
        ctx(%{
          xochi_config: config(%{"to_amount" => 960_000.0, "min_to_amount" => 955_200}),
          deposit_attestation_signer: signer_address()
        })

      assert {:ok, %{to_amount: "960000"}} = ExecuteDepositRoute.call(params(), ctx)
    end

    test "a fractional or inexact JSON float amount is refused, not reformatted" do
      for amount <- [960_000.5, 1.0e30] do
        ctx =
          ctx(%{
            xochi_config: config(%{"to_amount" => amount}),
            deposit_attestation_signer: signer_address()
          })

        assert {:error, {:invalid_quote_amount, %{field: :to_amount, value: ^amount}}} =
                 ExecuteDepositRoute.call(params(), ctx)
      end
    end

    test "a floor in the source's units on a non-USD destination is refused before any quote" do
      ctx =
        ctx(%{xochi_config: config(@eure_quote), deposit_attestation_signer: signer_address()})

      # 0.99 written at USDT's 6 decimals: about 10^-12 EURe at EURe's 18.
      assert {:error, {:implausible_min_to_amount, %{par_to_amount: 1_000_000_000_000_000_000}}} =
               ExecuteDepositRoute.run(
                 params(%{to_token: @eure_base, min_to_amount: "990000"}),
                 ctx
               )

      refute_received :quote_requested
    end

    test "a floor that is not an integer of atomic units is refused, not ignored" do
      # This quote would deliver 0.000001 USDC for 1 USDT.
      ctx =
        ctx(%{
          xochi_config: config(%{"to_amount" => "1"}),
          deposit_attestation_signer: signer_address()
        })

      # 79 digits is past any uint256; a million took a quarter second to parse,
      # and a few million raised `SystemLimitError` rather than a refusal.
      too_long = String.duplicate("9", 79)
      huge = String.duplicate("9", 1_000_000)

      for floor <-
            ["1e6", "995000.0", "1,000,000", "1_000_000", "-1", "abc", -5, 995_000.0] ++
              [too_long, huge] do
        assert {:error, {:invalid_min_to_amount, ^floor}} =
                 ExecuteDepositRoute.run(params(%{min_to_amount: floor}), ctx)
      end

      refute_received :quote_requested
    end
  end

  describe "registration" do
    test "is registered in the payment action set" do
      assert ExecuteDepositRoute in Payments.actions()
    end

    test "exposes the payment_execute_deposit_route tool name" do
      assert ExecuteDepositRoute.__action_meta__().name == "payment_execute_deposit_route"
    end
  end
end
