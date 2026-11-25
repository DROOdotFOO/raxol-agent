defmodule Raxol.Payments.Test.ExecuteRelayTransferCase do
  @moduledoc """
  Shared setup for the `ExecuteRelayTransfer` test files: a `Req.Test` stub
  named after this module, a relay config pointing at it, a spending policy,
  request params, a quote-then-execute stub and a context with a fresh ledger.
  """

  use ExUnit.CaseTemplate

  import ExUnit.Callbacks

  alias Raxol.Payments.{Ledger, SpendingPolicy}

  using do
    quote do
      import Raxol.Payments.Test.ExecuteRelayTransferCase

      alias Raxol.Payments.Test.ExecuteRelayTransferCase.{RaisingBroadcaster, SpyWallet},
        warn: false
    end
  end

  defmodule SpyWallet do
    @moduledoc false
    def address, do: "0x1111111111111111111111111111111111111111"
    def chain_id, do: 8453
    def sign_typed_data(_d, _t, _m), do: {:ok, <<7::size(520)>>}
    def sign_message(_), do: {:ok, <<7::size(520)>>}
    def sign_hash(_), do: {:ok, <<7::size(520)>>}
  end

  # A broadcaster that raises after it may have submitted the deposit.
  defmodule RaisingBroadcaster do
    @moduledoc false
    @behaviour Raxol.Payments.Relay.Broadcaster
    @impl true
    def send_deposit(_params), do: raise("receipt poll crashed")
  end

  @tron 728_126_428
  @tron_addr "TR7NHqjeKQxGTCi8q8ZY4pL8otSzgjLj6t"
  @usdt_trc20 "TEkxiTehnzSmSe2XqrBj4w32RUN966rdz8"
  @usdc_base "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913"

  @doc "Installs `fun` as this module's `Req.Test` stub (the one `config/0` plugs in)."
  @spec stub((Plug.Conn.t() -> Plug.Conn.t())) :: :ok
  def stub(fun), do: Req.Test.stub(__MODULE__, fun)

  @spec config() :: map()
  def config do
    %{
      base_url: "https://relay.test",
      auth_token: "token",
      req_options: [plug: {Req.Test, __MODULE__}]
    }
  end

  @spec policy(map()) :: SpendingPolicy.t()
  def policy(overrides \\ %{}) do
    Map.merge(
      %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("5.00"),
        lifetime_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        approved_domains: ["relay.test"]
      },
      overrides
    )
  end

  @spec base_params(map()) :: map()
  def base_params(overrides) do
    Map.merge(
      %{
        amount: "0.50",
        from_chain_id: 8453,
        to_chain_id: @tron,
        from_token: @usdc_base,
        to_token: @usdt_trc20,
        to_address: @tron_addr,
        settlement: "public"
      },
      overrides
    )
  end

  @spec stub_quote_and_execute() :: :ok
  def stub_quote_and_execute do
    stub(fn conn ->
      case conn.request_path do
        "/relay/quote" ->
          Req.Test.json(conn, %{
            "transfer_id" => "t_1",
            "quote_id" => "q_1",
            "can_fill" => true,
            "to_amount" => "499000",
            "deposit_address" => "0xdeposit"
          })

        "/relay/execute" ->
          Req.Test.json(conn, %{"transfer_id" => "t_1", "status" => "pending"})
      end
    end)
  end

  @spec ctx(map()) :: map()
  def ctx(overrides \\ %{}) do
    Map.merge(
      %{
        wallet: SpyWallet,
        relay_config: config(),
        ledger: start_supervised!({Ledger, [name: nil]}),
        policy: policy(),
        agent_id: "a1"
      },
      overrides
    )
  end

  @spec lifetime(map()) :: Decimal.t()
  def lifetime(context), do: Ledger.get_totals(context.ledger, "a1", policy()).lifetime
end
