defmodule Raxol.Payments.SpendingPolicy do
  @moduledoc """
  Spending limits for agent payment operations.

  Defines per-request, per-session (sliding window), and lifetime caps.
  Used by the `Ledger` to enforce budget constraints before signing payments.

  Caps are human amounts of `currency` (see `unit/1`): with the default
  `"USDC"`, `Decimal.new("1.00")` is one US dollar, whichever protocol is
  paying (an x402 USDC authorization, an MPP charge in USD cents or a dollar
  stablecoin, a Xochi intent).

  ## Example

      policy = %SpendingPolicy{
        per_request_max: Decimal.new("1.00"),
        session_max: Decimal.new("10.00"),
        session_window_ms: 3_600_000,
        lifetime_max: Decimal.new("100.00"),
        currency: "USDC",
        approved_domains: ["api.example.com"],
        require_confirmation_above: Decimal.new("5.00")
      }
  """

  @type t :: %__MODULE__{
          per_request_max: Decimal.t(),
          session_max: Decimal.t(),
          session_window_ms: pos_integer(),
          lifetime_max: Decimal.t(),
          currency: String.t(),
          approved_domains: [String.t()] | nil,
          require_confirmation_above: Decimal.t() | nil
        }

  defstruct [
    :per_request_max,
    :session_max,
    :lifetime_max,
    :require_confirmation_above,
    session_window_ms: 3_600_000,
    currency: "USDC",
    approved_domains: nil
  ]

  @doc """
  Create a policy with sensible defaults for development.
  """
  @spec dev() :: t()
  def dev do
    %__MODULE__{
      per_request_max: Decimal.new("0.10"),
      session_max: Decimal.new("1.00"),
      lifetime_max: Decimal.new("10.00"),
      currency: "USDC"
    }
  end

  @doc """
  Create an unrestricted policy (for testing only).
  """
  @spec unrestricted() :: t()
  def unrestricted do
    max = Decimal.new("999999999")

    %__MODULE__{
      per_request_max: max,
      session_max: max,
      lifetime_max: max,
      currency: "USDC"
    }
  end

  @doc """
  Check if a domain is approved under this policy.

  Returns true if `approved_domains` is nil (all domains allowed)
  or if the domain matches an entry in the list. Matching is
  case-insensitive and respects domain boundaries -- `evil-example.com`
  does not match `example.com`, but `api.example.com` does.

  Empty strings in the approved list are ignored. An empty domain
  string never matches.
  """
  @spec domain_approved?(t(), String.t()) :: boolean()
  def domain_approved?(%__MODULE__{approved_domains: nil}, _domain), do: true
  def domain_approved?(_policy, ""), do: false

  def domain_approved?(%__MODULE__{approved_domains: domains}, domain) do
    downcased = String.downcase(domain)

    Enum.any?(domains, fn approved ->
      approved = String.downcase(approved)
      approved != "" and domain_matches?(downcased, approved)
    end)
  end

  defp domain_matches?(domain, approved) do
    domain == approved or String.ends_with?(domain, "." <> approved)
  end

  @doc """
  Check if a payment amount requires user confirmation.
  """
  @spec requires_confirmation?(t(), Decimal.t()) :: boolean()
  def requires_confirmation?(%__MODULE__{require_confirmation_above: nil}, _amount), do: false

  def requires_confirmation?(%__MODULE__{require_confirmation_above: threshold}, amount) do
    Decimal.compare(amount, threshold) == :gt
  end

  @doc """
  The unit the caps are written in: `"USD"` for a `"USD"` or `"USDC"` policy
  (USDC counts at par), otherwise the currency code upper-cased. `nil` when
  `currency` is not a string. A payment is gated only when it is priced in
  this unit; `Raxol.Payments.Req.AutoPay` refuses a challenge in any other.
  """
  @spec unit(t()) :: String.t() | nil
  def unit(%__MODULE__{currency: currency}) when is_binary(currency) do
    case String.upcase(currency, :ascii) do
      code when code in ["USD", "USDC"] -> "USD"
      code -> code
    end
  end

  def unit(_policy), do: nil

  @all_caps [:per_request_max, :session_max, :session_window_ms, :lifetime_max]

  @doc """
  Check that `policy` is a `SpendingPolicy` whose `fields` are usable: each
  `*_max` a finite positive `Decimal`, `session_window_ms` a positive integer.
  `fields` defaults to every cap the ledger reads.

  Returns `:ok` or `{:error, {:invalid_policy, field}}` (`field` is
  `:not_a_policy` for anything but the struct).
  """
  @spec validate(term(), [atom()]) :: :ok | {:error, {:invalid_policy, atom()}}
  def validate(policy, fields \\ @all_caps)

  def validate(%__MODULE__{} = policy, fields) do
    Enum.find_value(fields, :ok, fn field ->
      unless usable?(field, Map.fetch!(policy, field)), do: {:error, {:invalid_policy, field}}
    end)
  end

  def validate(_policy, _fields), do: {:error, {:invalid_policy, :not_a_policy}}

  defp usable?(:session_window_ms, ms), do: is_integer(ms) and ms > 0

  # A finite Decimal carries an integer coefficient; Infinity and NaN carry an
  # atom.
  defp usable?(_cap, %Decimal{coef: coef} = cap) when is_integer(coef),
    do: Decimal.compare(cap, 0) == :gt

  defp usable?(_cap, _value), do: false
end
