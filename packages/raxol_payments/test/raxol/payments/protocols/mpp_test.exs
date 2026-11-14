defmodule Raxol.Payments.Protocols.MPPTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Protocols.MPP

  describe "detect?/2" do
    test "detects WWW-Authenticate Payment header" do
      headers = [{"www-authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      assert MPP.detect?(402, headers)
    end

    test "detects case-insensitive header" do
      headers = [{"WWW-Authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      assert MPP.detect?(402, headers)
    end

    test "returns false for non-Payment auth scheme" do
      headers = [{"www-authenticate", "Bearer realm=test"}]
      refute MPP.detect?(402, headers)
    end

    test "returns false for non-402 status" do
      headers = [{"www-authenticate", "Payment eyJ0ZXN0IjogdHJ1ZX0="}]
      refute MPP.detect?(200, headers)
    end

    test "returns false without auth header" do
      headers = [{"content-type", "application/json"}]
      refute MPP.detect?(402, headers)
    end
  end

  describe "parse_challenge/1" do
    test "decodes challenge from auth header" do
      payload =
        Jason.encode!(%{
          "amount" => "100",
          "currency" => "USDC",
          "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12",
          "methods" => ["tempo", "stripe"],
          "network" => "tempo:mainnet",
          "nonce" => "abc123"
        })

      encoded = Base.encode64(payload)
      headers = [{"www-authenticate", "Payment " <> encoded}]

      assert {:ok, challenge} = MPP.parse_challenge(headers)
      assert challenge.amount == "100"
      assert challenge.currency == "USDC"
      assert challenge.recipient == "0xabcdef1234567890abcdef1234567890abcdef12"
      assert challenge.methods == ["tempo", "stripe"]
      assert challenge.nonce == "abc123"
    end

    test "returns error for missing header" do
      assert {:error, {:missing_header, "www-authenticate"}} = MPP.parse_challenge([])
    end

    test "refuses a methods field that is not a list" do
      for methods <- ["tempo", %{"type" => "tempo"}, 1] do
        assert {:error, {:invalid_methods, ^methods}} =
                 MPP.parse_challenge(challenge_headers(%{"methods" => methods}))
      end
    end

    test "accepts an integer atomic amount" do
      assert {:ok, %{amount: 100}} = MPP.parse_challenge(challenge_headers(%{"amount" => 100}))
    end

    test "rejects a float amount as malformed atomic units" do
      assert {:error, {:invalid_amount, 1.5}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => 1.5}))
    end

    test "rejects a decimal-string amount as malformed atomic units" do
      assert {:error, {:invalid_amount, "1.50"}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => "1.50"}))
    end

    test "rejects a zero amount" do
      assert {:error, {:invalid_amount, 0}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => 0}))
    end

    test "accepts the largest uint256 amount, as a string or an integer" do
      max = Integer.pow(2, 256) - 1

      assert {:ok, _} =
               MPP.parse_challenge(challenge_headers(%{"amount" => Integer.to_string(max)}))

      assert {:ok, _} = MPP.parse_challenge(challenge_headers(%{"amount" => max}))
    end

    test "rejects an amount wider than a uint256, however it is sent" do
      over = Integer.pow(2, 256)

      assert {:error, {:invalid_amount, _}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => Integer.to_string(over)}))

      assert {:error, {:invalid_amount, _}} =
               MPP.parse_challenge(challenge_headers(%{"amount" => over}))

      assert {:error, {:invalid_amount, _}} =
               MPP.parse_challenge(
                 challenge_headers(%{"amount" => "1" <> String.duplicate("0", 7_000)})
               )
    end
  end

  describe "amount/1 is in human units of the challenge's currency" do
    test "a dollar stablecoin by its decimals, as USD" do
      {:ok, challenge} = MPP.parse_challenge(challenge_headers(%{"amount" => "5"}))
      assert challenge.unit == "USD"
      assert Decimal.equal?(MPP.amount(challenge), Decimal.new("0.000005"))

      {:ok, challenge} = MPP.parse_challenge(challenge_headers(%{"amount" => 1_500_000}))
      assert Decimal.equal?(MPP.amount(challenge), Decimal.new("1.5"))
    end

    test "fiat by its ISO 4217 minor units" do
      for {currency, amount, unit, human} <- [
            {"usd", "150", "USD", "1.50"},
            {"USD", 5, "USD", "0.05"},
            {"eur", "250", "EUR", "2.50"},
            {"CHF", "1", "CHF", "0.01"}
          ] do
        {:ok, challenge} =
          MPP.parse_challenge(challenge_headers(%{"currency" => currency, "amount" => amount}))

        assert challenge.unit == unit
        assert Decimal.equal?(MPP.amount(challenge), Decimal.new(human))
      end
    end

    test "a non-USD stablecoin as its peg currency" do
      {:ok, challenge} =
        MPP.parse_challenge(challenge_headers(%{"currency" => "EURC", "amount" => "2000000"}))

      assert challenge.unit == "EUR"
      assert Decimal.equal?(MPP.amount(challenge), Decimal.new("2"))
    end

    test "a currency with no unit a cap can be written in is refused" do
      for currency <- ["WETH", "ETH", "JPY", "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913", 840] do
        assert {:error, {:unpriced_currency, ^currency}} =
                 MPP.parse_challenge(challenge_headers(%{"currency" => currency}))
      end
    end

    test "an all-digit amount past 34 digits equals its integer form" do
      atomic = Integer.pow(10, 40)

      assert Decimal.equal?(
               MPP.amount(%{amount: Integer.to_string(atomic), decimals: 6}),
               MPP.amount(%{amount: atomic, decimals: 6})
             )
    end
  end

  describe "gate amount and signed amount are the same quantity" do
    defmodule StubWallet do
      def address, do: "0x1111111111111111111111111111111111111111"
      def sign_message(_message), do: {:ok, <<0::256>>}
    end

    test "the credential carries the atomic amount amount/1 scales" do
      {:ok, challenge} =
        MPP.parse_challenge(
          challenge_headers(%{"amount" => 150, "currency" => "usd", "methods" => ["tempo"]})
        )

      assert Decimal.equal?(MPP.amount(challenge), Decimal.new("1.50"))

      assert {:ok, [{"authorization", "Payment " <> encoded}]} =
               MPP.build_payment(challenge, StubWallet)

      {:ok, json} = Base.decode64(encoded)
      {:ok, credential} = Jason.decode(json)
      assert credential["amount"] == 150
      assert credential["currency"] == "usd"
    end
  end

  describe "parse_receipt/1" do
    test "decodes base64 JSON receipt" do
      payload =
        Jason.encode!(%{
          "transactionHash" => "0xcafebabe",
          "amount" => "100",
          "method" => "tempo",
          "success" => true
        })

      encoded = Base.encode64(payload)
      headers = [{"payment-receipt", encoded}]

      assert {:ok, receipt} = MPP.parse_receipt(headers)
      assert receipt.tx_hash == "0xcafebabe"
      assert receipt.amount == "100"
      assert receipt.method == "tempo"
      assert receipt.success == true
    end

    test "returns error for missing header" do
      assert {:error, :no_receipt} = MPP.parse_receipt([])
    end
  end

  # Build a `www-authenticate: Payment <base64>` header from a base challenge
  # merged with `overrides`, so a test can vary a single field (e.g. amount).
  defp challenge_headers(overrides) do
    payload =
      %{
        "amount" => 100,
        "currency" => "USDC",
        "recipient" => "0xabcdef1234567890abcdef1234567890abcdef12",
        "network" => "tempo:mainnet",
        "nonce" => "abc123"
      }
      |> Map.merge(overrides)
      |> Jason.encode!()

    [{"www-authenticate", "Payment " <> Base.encode64(payload)}]
  end
end
