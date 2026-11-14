defmodule Raxol.Payments.Actions.SpendGate do
  @moduledoc """
  Single spending choke point for payment Actions.

  Every agent Action that releases a wallet signature for real funds calls
  `authorize/3` first and proceeds only on `:ok`. This routes the request
  through the non-budget policy gate (`Raxol.Payments.PolicyGate`) and the
  atomic ledger reservation (`Raxol.Payments.Ledger.try_spend/5`) before any
  `wallet.sign_*` call.

  ## Amounts

  `authorize/3` takes a human amount of an asset (`:asset`) and converts it
  into the policy's unit (`Raxol.Payments.SpendPricing`) before the policy
  gate, the ledger reservation and any signature: a stablecoin pegged to the
  unit at par, a token that is not a stablecoin at its USD price from the
  configured source under a USD policy, or the
  spend is refused as `{:unpriced_asset, detail}`. It returns the converted
  amount, which is what the caps and the confirmation threshold saw and what
  the ledger recorded; pass that amount to `release/3` and `tag_reservation/3`.

  ## Targets

  * `{:domain, host}` -- HTTP/host-routed payment (x402, Xochi intent endpoint).
    The host is matched against `policy.approved_domains` and the confirmation
    threshold is applied.
  * `{:address, addr}` -- a direct on-chain transfer to an address. There is no
    host to approve, so only the confirmation threshold applies.

  ## Context keys

  * `:policy` -- a `SpendingPolicy` (nil means unrestricted: the gate is a no-op).
  * `:ledger` -- a `Ledger` server (nil disables budget reservation).
  * `:agent_id` -- ledger key (default `:unknown`).
  * `:on_confirm` -- `(Decimal.t(), String.t() -> :approve | :deny)` consulted
    when the converted amount exceeds `policy.require_confirmation_above`.
  * `:price_fn` -- `(symbol -> Decimal.t() | nil)` USD prices; without it the
    configured source is used (`Raxol.Payments.Prices`).

  ## Failed downstream execution

  `authorize/3` reserves budget atomically. If the signing/execution step that
  follows fails, call `release/2` (or `release/3`) to refund the reservation so
  a failed payment does not permanently consume the agent's budget.
  """

  alias Raxol.Payments.{Ledger, PolicyGate, SpendingPolicy, SpendPricing}

  @type target :: {:domain, String.t()} | {:address, String.t()}

  @type error ::
          {:over_budget, atom()}
          | {:requires_confirmation, Decimal.t()}
          | {:invalid_amount, Decimal.t()}
          | {:policy_required, atom()}
          | {:unpriced_asset, map()}
          | {:deny, PolicyGate.deny_reason()}

  @doc """
  Authorize a spend before signing. Returns `{:ok, amount}`, the spend in the
  policy's unit (unchanged with no policy), or `{:error, reason}`.

  ## Options

  * `:asset` -- what `amount` is a human amount of, required:
    `{:token, chain_id, address}` or `{:symbol, ticker}`.
  * `:target` -- `{:domain, host}` or `{:address, addr}` (default `{:address, ""}`).
  * `:metadata` -- map recorded with the ledger entry on success, with the
    policy's `currency`, `source_asset` and `source_amount` (the unconverted
    amount) added.
  """
  @spec authorize(map(), Decimal.t(), keyword()) :: {:ok, Decimal.t()} | {:error, error()}
  def authorize(context, %Decimal{} = amount, opts \\ []) when is_map(context) do
    target = Keyword.get(opts, :target, {:address, ""})
    asset = Keyword.get(opts, :asset)
    policy = Map.get(context, :policy)

    with :ok <- validate_amount(amount),
         :ok <- require_policy(context),
         {:ok, spend} <- SpendPricing.to_policy_unit(policy, amount, asset, context),
         :ok <- validate_amount(spend),
         :ok <- gate(policy, spend, target, context),
         :ok <- reserve(context, spend, metadata(policy, opts, asset, amount)) do
      {:ok, spend}
    end
  end

  defp metadata(%SpendingPolicy{currency: currency}, opts, asset, amount) do
    opts
    |> Keyword.get(:metadata, %{})
    |> Map.merge(%{currency: currency, source_asset: asset, source_amount: amount})
  end

  defp metadata(_policy, _opts, _asset, _amount), do: %{}

  @doc """
  Refund a previously authorized amount (e.g. when execution fails after the
  gate reserved budget). No-op when no ledger is configured.
  """
  @spec release(map(), Decimal.t(), map()) :: :ok
  def release(context, %Decimal{} = amount, metadata \\ %{}) when is_map(context) do
    case Map.get(context, :ledger) do
      nil ->
        :ok

      ledger ->
        agent_id = Map.get(context, :agent_id, :unknown)
        Ledger.release(ledger, agent_id, amount, metadata)
    end
  end

  @doc """
  Tag the reservation just made for `amount` with the intent (or transfer) id it
  funded, so a later refund can release it by id. Call once execution dispatches.
  No-op when no ledger is configured. See `Ledger.tag_reservation/4`.
  """
  @spec tag_reservation(map(), String.t(), Decimal.t()) :: :ok
  def tag_reservation(context, intent_id, %Decimal{} = amount) when is_map(context) do
    case Map.get(context, :ledger) do
      nil -> :ok
      ledger -> Ledger.tag_reservation(ledger, agent_id(context), intent_id, amount)
    end
  end

  @doc """
  Idempotently release the reservation tagged for `intent_id` (a refund reversed
  the spend). Returns `:released`, `:noop`, or `:noop` when no ledger is
  configured. Safe to call on every observation of a refund -- a second call for
  an already-released intent is a no-op. See `Ledger.release_by_intent/3`.
  """
  @spec release_by_intent(map(), String.t()) :: :released | :noop
  def release_by_intent(context, intent_id) when is_map(context) do
    case Map.get(context, :ledger) do
      nil -> :noop
      ledger -> Ledger.release_by_intent(ledger, agent_id(context), intent_id)
    end
  end

  @doc """
  Drop the reservation tag for `intent_id` without releasing budget (the spend
  stands; the intent settled or failed with funds kept). No-op when no ledger is
  configured. See `Ledger.forget_reservation/3`.
  """
  @spec forget_reservation(map(), String.t()) :: :ok
  def forget_reservation(context, intent_id) when is_map(context) do
    case Map.get(context, :ledger) do
      nil -> :ok
      ledger -> Ledger.forget_reservation(ledger, agent_id(context), intent_id)
    end
  end

  defp agent_id(context), do: Map.get(context, :agent_id, :unknown)

  # -- Amount validation --

  # A spend must be a positive, finite amount. Zero, negative, and non-finite
  # (Infinity/NaN) amounts are rejected before any gate runs. A negative amount
  # would otherwise pass every cap check and, once reserved, lower the running
  # ledger total, handing back budget headroom for later real spends. In
  # Decimal 2.x a finite value carries an integer coefficient while Infinity and
  # NaN carry an atom, so `is_integer(coef)` gates them out without hitting the
  # error `Decimal.compare/2` raises on NaN.
  defp validate_amount(%Decimal{coef: coef} = amount) when is_integer(coef) do
    if Decimal.compare(amount, 0) == :gt,
      do: :ok,
      else: {:error, {:invalid_amount, amount}}
  end

  defp validate_amount(amount), do: {:error, {:invalid_amount, amount}}

  # -- Policy presence --

  # A missing policy makes the gate a no-op (`gate(nil, ...)` passes and the
  # reservation is skipped), i.e. unlimited spending. That default-open posture
  # is convenient for tests and unconfigured callers but wrong for a fund-moving
  # deployment. `require_policy: true` (context) or
  # `config :raxol_payments, :require_policy, true` fails closed when no
  # `SpendingPolicy` is in context. In a deployed release this is the default;
  # development and tests stay permissive.
  defp require_policy(context) do
    if policy_required?(context) and not match?(%SpendingPolicy{}, Map.get(context, :policy)),
      do: {:error, {:policy_required, :no_spending_policy}},
      else: :ok
  end

  defp policy_required?(context) do
    case Map.get(context, :require_policy) do
      flag when is_boolean(flag) ->
        flag

      _ ->
        Application.get_env(
          :raxol_payments,
          :require_policy,
          Raxol.Payments.Deployment.production?()
        )
    end
  end

  # -- Non-budget gate --

  defp gate(nil, _amount, _target, _context), do: :ok

  defp gate(%SpendingPolicy{} = policy, amount, {:domain, host}, context)
       when is_binary(host) do
    opts = [on_confirm: Map.get(context, :on_confirm)]

    case PolicyGate.evaluate(policy, amount, host, opts) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:deny, reason}}
    end
  end

  defp gate(%SpendingPolicy{} = policy, amount, {:address, addr}, context)
       when is_binary(addr) do
    if SpendingPolicy.requires_confirmation?(policy, amount) do
      confirm_address(Map.get(context, :on_confirm), amount, addr)
    else
      :ok
    end
  end

  defp confirm_address(on_confirm, amount, addr) when is_function(on_confirm, 2) do
    case on_confirm.(amount, addr) do
      :approve -> :ok
      _ -> {:error, {:requires_confirmation, amount}}
    end
  end

  defp confirm_address(_on_confirm, amount, _addr),
    do: {:error, {:requires_confirmation, amount}}

  # -- Atomic budget reservation --

  defp reserve(context, amount, metadata) do
    with {:ledger, ledger} when not is_nil(ledger) <-
           {:ledger, Map.get(context, :ledger)},
         {:policy, %SpendingPolicy{} = policy} <-
           {:policy, Map.get(context, :policy)} do
      agent_id = Map.get(context, :agent_id, :unknown)

      case Ledger.try_spend(ledger, agent_id, amount, policy, metadata) do
        :ok -> :ok
        {:over_limit, type} -> {:error, {:over_budget, type}}
      end
    else
      _ -> :ok
    end
  end
end
