defmodule Raxol.Payments.Test.ExecuteXochiIntentCase do
  @moduledoc """
  Shared setup for the `ExecuteXochiIntent` test files: a `Req.Test` stub
  named after this module, a Xochi config pointing at it, a spending policy,
  request params, a quote server that binds the served intent to the posted
  request, and test wallets.
  """

  use ExUnit.CaseTemplate

  alias Raxol.Payments.{Checkpoint, SpendingPolicy}
  alias Raxol.Payments.Test.XochiIntentFixture
  alias Raxol.Payments.Xochi.Stealth

  using do
    quote do
      import Raxol.Payments.Test.ExecuteXochiIntentCase

      alias Raxol.Payments.Test.ExecuteXochiIntentCase.{EncodingWallet, LostRaceStore, SpyWallet},
        warn: false
    end
  end

  defmodule LostRaceStore do
    @moduledoc """
    Two runs of the same payment share its key: this run's `put_new` loses
    (`:exists`), and the winner's checkpoint is gone before this run reads it.
    """
    @behaviour Checkpoint

    @impl true
    def fetch(_handle, _key), do: :error

    @impl true
    def put(_handle, _key, _record), do: :ok

    @impl true
    def put_new(_handle, _key, _record), do: {:error, :exists}

    @impl true
    def delete(_handle, _key), do: :ok

    @impl true
    def sweep_expired(_handle, _now), do: :ok
  end

  defmodule SpyWallet do
    @moduledoc "Wallet that sends `:wallet_signed` when it signs, so a test can order the gate first."
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453

    def sign_typed_data(_domain, _types, _message) do
      send(self(), :wallet_signed)
      {:ok, <<7::size(520)>>}
    end

    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  defmodule EncodingWallet do
    @moduledoc """
    Wallet that hashes through the real EIP-712 encoder before "signing", so a
    malformed quote message reaches the encoder exactly as in production.
    """
    alias Raxol.Payments.EIP712

    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453

    def sign_typed_data(domain, types, message) do
      with {:ok, _hash} <- EIP712.hash(domain, types, message),
           do: {:ok, <<7::size(520)>>}
    end

    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  def usdc_base, do: "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"
  def usdc_arb, do: "0xaf88d065e77c8cc2239327c5edb3a432268e5831"
  def usdt_tron, do: "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"

  @doc "Stub the Xochi endpoint for the calling test process."
  def stub(fun), do: Req.Test.stub(__MODULE__, fun)

  def config do
    %{
      base_url: "https://xochi.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  def policy(overrides \\ %{}) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        lifetime_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["xochi.test"]
      },
      overrides
    )
  end

  @doc "A valid ERC-6538 meta-address, so the stealth path has keys to send."
  def recipient_meta do
    {:ok, %{spending: {_, spending_pub}, viewing: {_, viewing_pub}}} =
      Stealth.derive_keys("0x" <> String.duplicate("11", 65))

    Stealth.encode_meta_address(%{
      spending_pub_key: spending_pub,
      viewing_pub_key: viewing_pub
    })
  end

  def base_params(overrides) do
    Map.merge(
      %{
        amount: "0.50",
        from_chain_id: 8453,
        to_chain_id: 42_161,
        from_token: usdc_base(),
        to_token: usdc_arb(),
        settlement: "stealth",
        recipient_meta_address: recipient_meta()
      },
      overrides
    )
  end

  @doc """
  Serve the quote Xochi would for the posted request: the intent binds the
  request's terms and signs the served toAmount. The decoded body is sent to
  the test as `{:quote_body, body}`. Options:

    * `:to_amount` -- served toAmount (default the request's output_amount,
      else "499000"); `:signed_to_amount` -- signed toAmount (default the same).
    * `:quote_id`, `:from_amount`, `:message` -- passed to the fixture.
    * `:types` -- replaces the served types; `:extra` -- merged at top level.
  """
  def serve_quote(conn, opts \\ []) do
    {body, conn} = XochiIntentFixture.quote_body(conn)
    send(self(), {:quote_body, body})

    to_amount = Keyword.get(opts, :to_amount, body["output_amount"] || "499000")
    signed = Keyword.get(opts, :signed_to_amount, to_amount)
    quote_id = Keyword.get(opts, :quote_id, "q_1")

    Req.Test.json(
      conn,
      Map.merge(
        %{
          "intentId" => "int_1",
          "quoteId" => quote_id,
          "canSolve" => true,
          "toAmount" => to_amount,
          "xochiFee" => "1000",
          "eip712Data" => served_eip712(body, signed, quote_id, opts)
        },
        Keyword.get(opts, :extra, %{})
      )
    )
  end

  defp served_eip712(body, signed, quote_id, opts) do
    eip712 =
      XochiIntentFixture.eip712(
        body,
        signed,
        [{:quote_id, quote_id} | Keyword.take(opts, [:from_amount, :message])]
      )

    case Keyword.fetch(opts, :types) do
      {:ok, types} -> Map.put(eip712, "types", types)
      :error -> eip712
    end
  end

  @doc """
  A one-shot HTTP server that answers the quote, then closes, so the execute
  that follows is refused at connect: a failure proven to happen before send.
  """
  def quote_then_refuse_connections do
    {:ok, listener} =
      :gen_tcp.listen(0, [
        :binary,
        packet: :raw,
        active: false,
        reuseaddr: true,
        ip: {127, 0, 0, 1}
      ])

    {:ok, port} = :inet.port(listener)

    # No timeouts on this side: the server is linked to the test, and the
    # client's own timeouts bound how long the test waits. A clock here only
    # fails a loaded run whose client was slow to connect.
    spawn_link(fn ->
      {:ok, socket} = :gen_tcp.accept(listener)
      :ok = :gen_tcp.close(listener)
      body = socket |> read_http_request("") |> Jason.decode!()
      to_amount = body["output_amount"] || "499000"

      payload =
        Jason.encode!(%{
          "intentId" => "int_1",
          "quoteId" => "q_1",
          "canSolve" => true,
          "toAmount" => to_amount,
          "xochiFee" => "1000",
          "eip712Data" => served_eip712(body, to_amount, "q_1", [])
        })

      :ok =
        :gen_tcp.send(
          socket,
          "HTTP/1.1 200 OK\r\ncontent-type: application/json\r\nconnection: close\r\ncontent-length: #{byte_size(payload)}\r\n\r\n#{payload}"
        )

      :ok = :gen_tcp.close(socket)
    end)

    "http://127.0.0.1:#{port}"
  end

  defp read_http_request(socket, acc) do
    case String.split(acc, "\r\n\r\n", parts: 2) do
      [head, body] ->
        [_, length] = Regex.run(~r/\r\ncontent-length:\s*(\d+)/i, "\r\n" <> head)
        length = String.to_integer(length)

        if byte_size(body) >= length do
          binary_part(body, 0, length)
        else
          {:ok, data} = :gen_tcp.recv(socket, 0)
          read_http_request(socket, acc <> data)
        end

      [_head] ->
        {:ok, data} = :gen_tcp.recv(socket, 0)
        read_http_request(socket, acc <> data)
    end
  end

  def stub_quote_and_execute do
    stub(fn conn ->
      case conn.request_path do
        "/api/intent/quote" ->
          serve_quote(conn)

        "/api/intent/execute" ->
          Req.Test.json(conn, %{
            "success" => true,
            "intentId" => "int_1",
            "status" => "executing",
            "stealthAddress" => "0xstealth"
          })

        "/api/intent/int_1/status" ->
          Req.Test.json(conn, %{
            "intentId" => "int_1",
            "status" => "completed",
            "settlementType" => "stealth",
            "txHash" => "0xabc",
            "terminal" => true
          })
      end
    end)
  end
end
