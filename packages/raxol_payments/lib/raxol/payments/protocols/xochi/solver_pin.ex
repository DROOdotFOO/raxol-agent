defmodule Raxol.Payments.Protocols.Xochi.SolverPin do
  @moduledoc false
  # The origin-pull solver pin: which `to` (ERC-3009) or `spender` (Permit2)
  # an origin pull may name. Configured with
  # `config :raxol_payments, :pull_solver_allowlist, ["0x..."]` and
  # `:pull_require_solver_pin`; public entry points are delegated from
  # `Raxol.Payments.Protocols.Xochi`, which documents them.

  alias Raxol.Payments.{Deployment, EIP712}
  alias Raxol.Payments.Xochi.PullContracts

  @solver_env ~w(
    XOCHI_SOLVER_ETH XOCHI_SOLVER_BASE XOCHI_SOLVER_ARBITRUM
    XOCHI_SOLVER_OPTIMISM XOCHI_SOLVER_POLYGON XOCHI_SOLVER_ROBINHOOD
  )

  @doc """
  Whether `addr` may receive a pull of `method`. It must be a clean `0x` +
  40-hex address (served, so its case is not checked), pinned or not, so
  padding, bare hex or a doubled prefix never normalizes onto a pinned solver.
  A configured allowlist none of whose entries is a valid address refuses
  every pull rather than reading as unset. With an allowlist set it must
  be in it. With none, the methods differ by their on-chain guarantees:
  ERC-3009 binds `to` in the signed digest and the token enforces
  `msg.sender == to`, so an unpinned `to` stays bounded and is accepted unless
  the pin is required; Permit2 has no on-chain recipient guard (the spender
  picks the recipient at call time), so it is always refused.
  """
  @spec allowed?(term(), :erc3009 | :permit2) :: boolean()
  def allowed?(addr, method) do
    EIP712.address?(addr, checksum: false) and
      case allowlist() do
        [] -> method == :erc3009 and not required?()
        {:configured, list} -> EIP712.normalize_address(addr) in list
      end
  end

  # `require_pin?` true means a boot with an empty allowlist is acceptable
  # because every ERC-3009 pull will then be refused; false with an empty
  # allowlist is the fail-open state.
  @spec fail_open?([String.t()] | nil, boolean()) :: boolean()
  def fail_open?(allowlist, require_pin?) do
    normalize(allowlist) == [] and require_pin? != true
  end

  @spec assert_pinned!([String.t()] | nil, boolean()) :: :ok
  def assert_pinned!(allowlist, require_pin?) do
    if fail_open?(allowlist, require_pin?) do
      raise ArgumentError,
            "Xochi origin-pull solver pin is not configured (fail-open): the agent " <>
              "would sign ERC-3009 origin-pull authorizations to an unverified recipient. " <>
              "Set #{Enum.join(@solver_env, " / ")} to the canonical solver address(es), " <>
              "or set XOCHI_PULL_REQUIRE_SOLVER_PIN=true."
    end

    :ok
  end

  @spec env_config!() :: [pull_solver_allowlist: [String.t()], pull_require_solver_pin: boolean()]
  def env_config! do
    solvers =
      @solver_env
      |> Enum.map(&{&1, String.trim(System.get_env(&1) || "")})
      |> Enum.reject(fn {_var, value} -> value == "" end)
      |> Enum.map(&solver_address!/1)

    require_pin? =
      case System.get_env("XOCHI_PULL_REQUIRE_SOLVER_PIN", "") do
        "" -> Deployment.production?()
        value -> value == "true"
      end

    assert_pinned!(solvers, require_pin?)

    [
      pull_solver_allowlist: Enum.uniq(solvers ++ PullContracts.pull_recipients()),
      pull_require_solver_pin: require_pin?
    ]
  end

  # Explicit config wins both ways; unset, a deployed release requires the pin.
  defp required? do
    Application.get_env(:raxol_payments, :pull_require_solver_pin, Deployment.production?())
  end

  # A set `XOCHI_SOLVER_*` must be an address (EIP-55 if mixed case): a typo
  # would otherwise boot and refuse every pull to that solver.
  defp solver_address!({var, value}) do
    if EIP712.address?(value),
      do: value,
      else: raise(ArgumentError, "#{var} is not a valid 0x address (EIP-55 if mixed case).")
  end

  # `:unset` only when nothing is configured: a list whose entries are all
  # malformed still pins (to nothing), so it refuses rather than fails open.
  defp allowlist do
    raw = Application.get_env(:raxol_payments, :pull_solver_allowlist, [])

    case raw |> List.wrap() |> Enum.filter(&(is_binary(&1) and String.trim(&1) != "")) do
      [] -> []
      _configured -> {:configured, normalize(raw)}
    end
  end

  # Entries are trimmed, then kept only if they are a clean address (EIP-55 if
  # mixed case), so a malformed entry never counts as a pin.
  defp normalize(list) do
    list
    |> List.wrap()
    |> Enum.filter(&is_binary/1)
    |> Enum.map(&String.trim/1)
    |> Enum.filter(&EIP712.address?/1)
    |> Enum.map(&EIP712.normalize_address/1)
  end
end
