defmodule Raxol.Earn.Xochi.SolverAgent.Budget do
  @moduledoc false
  # Storefront fee sizing for `Raxol.Earn.Xochi.SolverAgent`. Pure: no process
  # state, no I/O beyond the static `Raxol.Payments.Assets` registry.

  alias Raxol.Payments.Assets

  # The smallest fee worth escrowing, in the ACP payment token's base units.
  # `budget_for/2` truncates through `div/2`, so below this a fee that was meant
  # to be charged has rounded away to an escrow that can never pay.
  @default_min_fee_atomic 1

  # The budget is `fee_bps` of the intent's `from_amount`, escrowed as the ACP
  # payment token (USDC, 6dp). `from_amount` is in the ORIGIN token's base units,
  # so the arithmetic only holds when the origin leg is itself a 6dp USD
  # stablecoin. Rescaling cannot rescue a non-stablecoin (1 WETH = 1e18 base
  # units, read as USDC that understates the fee by roughly the ETH price), so
  # without a price oracle the corridor is refused rather than mis-sized.
  @fee_base_symbols ~w(USDC USDT USDG)

  # Asserted, not trusted: a symbol is only a proxy for decimals, and an 18dp
  # token registered under one of these symbols would size a budget ~1e12 too
  # small. The symbol check still comes first, because `Assets.decimals/2`
  # answers 6 for tokens it does not know.
  @fee_base_decimals 6

  @type rejection ::
          {:unsupported_fee_base, pos_integer() | nil, String.t() | nil}
          | {:unsupported_fee_base_decimals, pos_integer(), String.t(), non_neg_integer()}
          | {:fee_below_min, non_neg_integer(), non_neg_integer()}

  @doc false
  # The ACP job budget is the storefront fee only. The transfer flows through
  # Xochi off-escrow; sizing the escrow to the transfer would incur the core's
  # 5-10% take on the full amount.
  @spec budget_for(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  def budget_for(transfer_atomic, fee_bps)
      when is_integer(transfer_atomic) and transfer_atomic >= 0 and
             is_integer(fee_bps) and fee_bps >= 0 do
    div(transfer_atomic * fee_bps, 10_000)
  end

  @doc false
  # Returns the budget it validated, so the number that was checked is the
  # number that gets escrowed.
  @spec fee_budget(map(), non_neg_integer(), non_neg_integer(), non_neg_integer()) ::
          {:ok, non_neg_integer()} | {:reject, rejection()}
  def fee_budget(intent, transfer_atomic, fee_bps, min_fee_atomic) do
    budget_atomic = budget_for(transfer_atomic, fee_bps)

    with :ok <- ensure_stable_origin(intent),
         :ok <- ensure_fee_floor(budget_atomic, fee_bps, min_fee_atomic) do
      {:ok, budget_atomic}
    end
  end

  @doc false
  # Read and checked once, at start, rather than per job. `>=` against a
  # non-integer does not raise (every number sorts below every atom and binary),
  # so a mistyped value would silently reject every job. Refusing to start says
  # so instead.
  @spec min_fee(keyword()) :: {:ok, non_neg_integer()} | {:error, term()}
  def min_fee(opts) do
    opts
    |> Keyword.get_lazy(:min_fee_atomic, fn ->
      Application.get_env(:raxol_earn, :solver_min_fee_atomic, @default_min_fee_atomic)
    end)
    |> validate_min_fee()
  end

  defp validate_min_fee(n) when is_integer(n) and n >= 0, do: {:ok, n}
  defp validate_min_fee(other), do: {:error, {:invalid_solver_min_fee_atomic, other}}

  defp ensure_stable_origin(%{from_chain_id: chain, from_token: token}) do
    with symbol when symbol in @fee_base_symbols <- Assets.symbol_for(chain, token),
         @fee_base_decimals <- Assets.decimals(chain, token) do
      :ok
    else
      decimals when is_integer(decimals) ->
        {:reject, {:unsupported_fee_base_decimals, chain, token, decimals}}

      _ ->
        {:reject, {:unsupported_fee_base, chain, token}}
    end
  end

  defp ensure_stable_origin(_intent), do: {:reject, {:unsupported_fee_base, nil, nil}}

  # A fee truncated to zero is an escrow that can never pay, so it is rejected.
  # `fee_bps: 0` is the other zero: a storefront charging nothing on purpose.
  defp ensure_fee_floor(_budget_atomic, 0, _min), do: :ok
  defp ensure_fee_floor(budget_atomic, _fee_bps, min) when budget_atomic >= min, do: :ok

  defp ensure_fee_floor(budget_atomic, _fee_bps, min),
    do: {:reject, {:fee_below_min, budget_atomic, min}}
end
