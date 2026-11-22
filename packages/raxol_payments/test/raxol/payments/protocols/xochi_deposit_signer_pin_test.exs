defmodule Raxol.Payments.Protocols.XochiDepositSignerPinTest do
  # async: false -- sets the global :deployment and
  # :xochi_deposit_attestation_signer.
  use ExUnit.Case, async: false

  alias Raxol.Payments.EIP712
  alias Raxol.Payments.Protocols.Xochi
  alias Raxol.Payments.Test.DepositAttestationFixture, as: Fixture
  alias Raxol.Payments.Xochi.Capabilities
  alias Raxol.Payments.Xochi.Schemas.{DepositRouteRequest, QuoteResponse}

  @deposit_addr "TWd4WrZ9wn84f5x1hZhL4DHvk738ns5jwb"
  @priv <<7::256>>
  @now 1_800_000_000
  @config %{base_url: "https://xochi.test"}

  setup do
    for key <- [:deployment, :xochi_deposit_attestation_signer] do
      previous = Application.fetch_env(:raxol_payments, key)
      Application.delete_env(:raxol_payments, key)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_payments, key, value)
          :error -> Application.delete_env(:raxol_payments, key)
        end
      end)
    end

    :ok
  end

  describe "verify_deposit_route/4 signer resolution" do
    test "an operator pin verifies, from opts or from config" do
      assert {:ok, %{deposit_address: @deposit_addr}} =
               verify(deposit_attestation_signer: signer())

      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())
      assert {:ok, _} = verify([])
    end

    test "unpinned is refused in every deployment" do
      for deployment <- [:development, :test, :production] do
        Application.put_env(:raxol_payments, :deployment, deployment)
        assert {:error, :deposit_signer_unpinned} = verify([])
      end
    end

    test "a live matrix publishing the genuine signer is never trusted for it" do
      Capabilities.reset()
      on_exit(&Capabilities.reset/0)
      test_pid = self()

      wire = %{
        "chains" => [%{"chain_id" => 8453, "chain_name" => "Base"}],
        "tokens" => [],
        "deposit_attestation_signer" => signer(),
        "deposit_attestation_version" => "xochi-deposit-attestation:v3"
      }

      config = %{
        base_url: "https://xochi.test",
        req_options: [
          plug: fn conn ->
            send(test_pid, {:fetched, conn.request_path})

            conn
            |> Plug.Conn.put_resp_content_type("application/json")
            |> Plug.Conn.send_resp(200, Jason.encode!(wire))
          end
        ]
      }

      quote_resp = QuoteResponse.from_json(quote_body())

      # Unpinned: refused before the matrix is even fetched.
      assert {:error, :deposit_signer_unpinned} =
               Xochi.verify_deposit_route(config, request(), quote_resp, clock: &now/0)

      refute_received {:fetched, _}

      # Pinned: the same matrix is read, for its version only.
      assert {:ok, _} =
               Xochi.verify_deposit_route(config, request(), quote_resp,
                 deposit_attestation_signer: signer(),
                 clock: &now/0
               )

      assert_received {:fetched, "/api/capabilities"}
    end

    test "a pinned run against an unreachable matrix has no advertised version" do
      Capabilities.reset()
      on_exit(&Capabilities.reset/0)

      config = %{
        base_url: "https://xochi.test",
        req_options: [plug: fn conn -> Plug.Conn.send_resp(conn, 500, "") end]
      }

      assert {:error, {:unsupported_deposit_attestation_version, nil}} =
               Xochi.verify_deposit_route(
                 config,
                 request(),
                 QuoteResponse.from_json(quote_body()),
                 deposit_attestation_signer: signer(),
                 clock: &now/0
               )
    end

    test "a pin for another signer is a mismatch" do
      assert {:error, :attestation_mismatch} =
               verify(deposit_attestation_signer: "0x000000000000000000000000000000000000dEaD")
    end

    test "a malformed operator pin is refused, not trusted or skipped" do
      "0x" <> bare = signer()

      for pin <- [bare, signer() <> "\n", " " <> signer(), "0x" <> signer(), "not-an-address"] do
        assert {:error, :invalid_deposit_signer_pin} = verify(deposit_attestation_signer: pin)
      end
    end
  end

  describe "operator pin edge cases" do
    test "an empty opts pin does not mask a configured pin" do
      Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())

      for pin <- ["", nil] do
        assert {:ok, _} = verify(deposit_attestation_signer: pin)
      end
    end

    test "a checksummed or 0X pin verifies" do
      "0x" <> hex = signer()

      for pin <- ["0X" <> hex, "0x" <> String.upcase(hex)] do
        assert {:ok, _} = verify(deposit_attestation_signer: pin)
      end
    end

    test "a pin with a wrong EIP-55 checksum is refused" do
      # Lowercase with one letter upcased: mixed case that is not the EIP-55
      # form, whichever letter it is.
      [{index, _}] = Regex.run(~r/[a-f]/, signer(), return: :index) |> Enum.take(1)

      wrong_case =
        String.slice(signer(), 0, index) <>
          String.upcase(String.at(signer(), index)) <> String.slice(signer(), (index + 1)..-1//1)

      refute EIP712.address?(wrong_case)

      assert {:error, :invalid_deposit_signer_pin} =
               verify(deposit_attestation_signer: wrong_case)
    end
  end

  describe "assert_deposit_signer_pinned!/1" do
    test "raises when no pin is set" do
      for pin <- [nil, ""] do
        assert_raise ArgumentError, ~r/deposit-attestation signer is not pinned/, fn ->
          Xochi.assert_deposit_signer_pinned!(pin)
        end
      end
    end

    test "raises on a set but malformed pin" do
      for pin <- ["0x1234", 42] do
        assert_raise ArgumentError, ~r/not a valid 0x address/, fn ->
          Xochi.assert_deposit_signer_pinned!(pin)
        end
      end
    end

    test "passes with a valid pin" do
      assert :ok = Xochi.assert_deposit_signer_pinned!(signer())
    end
  end

  describe "assert_deposit_signer_pinned!/0" do
    test "reads the configured pin, in every deployment" do
      for deployment <- [:development, :production] do
        Application.put_env(:raxol_payments, :deployment, deployment)
        Application.delete_env(:raxol_payments, :xochi_deposit_attestation_signer)

        assert_raise ArgumentError, ~r/not pinned/, fn ->
          Xochi.assert_deposit_signer_pinned!()
        end

        Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, "0xbad")

        assert_raise ArgumentError, ~r/not a valid 0x address/, fn ->
          Xochi.assert_deposit_signer_pinned!()
        end

        Application.put_env(:raxol_payments, :xochi_deposit_attestation_signer, signer())
        assert :ok = Xochi.assert_deposit_signer_pinned!()
      end
    end
  end

  defp verify(opts) do
    Xochi.verify_deposit_route(
      @config,
      request(),
      QuoteResponse.from_json(quote_body()),
      opts
      |> Keyword.put_new(:clock, &now/0)
      |> Keyword.put_new(:capabilities, Fixture.capabilities())
    )
  end

  defp now, do: @now

  defp request do
    %DepositRouteRequest{
      wallet: Fixture.defaults().tron_wallet,
      from_chain_id: 728_126_428,
      to_chain_id: 8453,
      from_token: Fixture.defaults().tron_usdt,
      to_token: Fixture.defaults().to_token,
      from_amount: "1000000",
      recipient_address: Fixture.defaults().recipient
    }
  end

  defp deal, do: Fixture.fields(%{intent_id: "xi_dep_pin", quote_id: "xq_dep_pin"})

  defp quote_body do
    deal = deal()

    %{
      "intent_id" => deal.intent_id,
      "quote_id" => deal.quote_id,
      "can_solve" => true,
      "to_amount" => deal.to_amount,
      "min_to_amount" => deal.min_to_amount,
      "deposit_address" => deal.deposit_address,
      "deposit_deadline" => deal.deposit_deadline,
      "deposit_attestation" => Fixture.sign(deal, @priv)
    }
  end

  defp signer, do: Fixture.address(@priv)
end
