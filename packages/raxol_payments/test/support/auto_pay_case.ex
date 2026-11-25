defmodule Raxol.Payments.Test.AutoPayCase do
  @moduledoc """
  Shared setup for the `Req.AutoPay` test files: test wallets (one that
  signs, and ones that fail, raise, exit or throw), 402 challenge stubs for
  x402 and MPP, and an AutoPay-attached request.
  """

  use ExUnit.CaseTemplate

  alias Raxol.Payments.{Ledger, Req.AutoPay, SpendingPolicy}
  alias Raxol.Payments.Test.AutoPayCase.StubWallet

  using do
    quote do
      import Raxol.Payments.Test.AutoPayCase

      alias Raxol.Payments.Test.AutoPayCase.{
              ExitingWallet,
              FailingWallet,
              RaisingWallet,
              StubWallet,
              ThrowingWallet
            },
            warn: false
    end
  end

  defmodule StubWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x" <> String.duplicate("aa", 20)
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_msg), do: {:ok, <<0::512>>}
    @impl true
    def sign_typed_data(_domain, _types, _message) do
      case Process.get(:wallet_signal_target) do
        nil -> :ok
        pid -> send(pid, :wallet_signed)
      end

      {:ok, <<0::512>>}
    end

    @impl true
    def sign_hash(_digest), do: {:ok, <<0::520>>}
  end

  defmodule FailingWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x" <> String.duplicate("aa", 20)
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_msg), do: {:error, :locked}
    @impl true
    def sign_typed_data(_domain, _types, _message), do: {:error, :locked}
    @impl true
    def sign_hash(_digest), do: {:error, :locked}
  end

  defmodule RaisingWallet do
    @moduledoc false
    @behaviour Raxol.Payments.Wallet
    @impl true
    def address, do: "0x" <> String.duplicate("aa", 20)
    @impl true
    def chain_id, do: 8453
    @impl true
    def sign_message(_msg), do: raise("wallet unavailable")
    @impl true
    def sign_typed_data(_domain, _types, _message), do: raise("wallet unavailable")
    @impl true
    def sign_hash(_digest), do: raise("wallet unavailable")
  end

  # A GenServer-backed wallet whose call exits (a crash or a timeout), and one
  # that throws: neither returns a signature.
  defmodule ExitingWallet do
    @moduledoc false
    def address, do: "0x" <> String.duplicate("aa", 20)
    def chain_id, do: 8453
    def sign_message(_msg), do: exit(:timeout)
    def sign_typed_data(_domain, _types, _message), do: exit({:timeout, {GenServer, :call, []}})
    def sign_hash(_digest), do: exit(:timeout)
  end

  defmodule ThrowingWallet do
    @moduledoc false
    def address, do: "0x" <> String.duplicate("aa", 20)
    def chain_id, do: 8453
    def sign_message(_msg), do: throw(:locked)
    def sign_typed_data(_domain, _types, _message), do: throw(:locked)
    def sign_hash(_digest), do: throw(:locked)
  end

  # Build a base64-encoded x402 `payment-required` challenge body.
  @spec x402_challenge(String.t()) :: String.t()
  def x402_challenge(amount) do
    %{
      "maxAmountRequired" => amount,
      "payTo" => "0x" <> String.duplicate("cd", 20),
      "asset" => "0x833589fCD6eDb6E08f4c7C32D4f71b54bdA02913",
      "network" => "eip155:8453",
      "nonce" => "0x" <> String.duplicate("12", 32),
      "validAfter" => 0,
      "validBefore" => System.system_time(:second) + 300
    }
    |> Jason.encode!()
    |> Base.encode64()
  end

  @spec stub_402(String.t()) :: (Req.Request.t() -> {Req.Request.t(), Req.Response.t()})
  def stub_402(amount) do
    fn req ->
      resp =
        Req.Response.new(status: 402, body: "")
        |> Req.Response.put_header("payment-required", x402_challenge(amount))

      {req, resp}
    end
  end

  # 402 on the first request, then 2xx on the retry (which carries the signed
  # x-payment header) -- i.e. a payment that actually completes.
  @spec stub_402_then_ok(String.t()) :: (Req.Request.t() -> {Req.Request.t(), Req.Response.t()})
  def stub_402_then_ok(amount) do
    fn req ->
      resp =
        if Req.Request.get_header(req, "x-payment") == [] do
          Req.Response.new(status: 402, body: "")
          |> Req.Response.put_header("payment-required", x402_challenge(amount))
        else
          Req.Response.new(status: 200, body: "ok")
        end

      {req, resp}
    end
  end

  # 402 on the first request, then a non-2xx on the retry: the server holds the
  # signed payment and answers with an error.
  @spec stub_402_then_error(String.t()) ::
          (Req.Request.t() -> {Req.Request.t(), Req.Response.t()})
  def stub_402_then_error(amount) do
    fn req ->
      resp =
        if Req.Request.get_header(req, "x-payment") == [] do
          Req.Response.new(status: 402, body: "")
          |> Req.Response.put_header("payment-required", x402_challenge(amount))
        else
          Req.Response.new(status: 500, body: "server error")
        end

      {req, resp}
    end
  end

  # 402 with an MPP `www-authenticate: Payment` challenge, 200 on the paid retry.
  @spec stub_mpp_402_then_ok(map()) :: (Req.Request.t() -> {Req.Request.t(), Req.Response.t()})
  def stub_mpp_402_then_ok(fields) do
    challenge =
      %{"recipient" => "0x" <> String.duplicate("cd", 20), "network" => "tempo:mainnet"}
      |> Map.merge(fields)
      |> Jason.encode!()
      |> Base.encode64()

    fn req ->
      resp =
        if Req.Request.get_header(req, "authorization") == [] do
          Req.Response.new(status: 402, body: "")
          |> Req.Response.put_header("www-authenticate", "Payment " <> challenge)
        else
          Req.Response.new(status: 200, body: "ok")
        end

      {req, resp}
    end
  end

  @spec autopay_req(GenServer.server(), SpendingPolicy.t(), function(), module()) ::
          Req.Request.t()
  def autopay_req(ledger, policy, stub, wallet \\ StubWallet) do
    Req.new(url: "https://api.example.com/data", retry: false)
    |> AutoPay.attach(wallet: wallet, ledger: ledger, policy: policy, agent_id: :test)
    |> Req.Request.prepend_request_steps(stub: stub)
  end

  @spec lifetime(GenServer.server(), SpendingPolicy.t()) :: Decimal.t()
  def lifetime(ledger, policy), do: Ledger.get_totals(ledger, :test, policy).lifetime
end
