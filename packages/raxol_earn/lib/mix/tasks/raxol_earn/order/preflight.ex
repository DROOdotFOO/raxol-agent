defmodule Mix.Tasks.RaxolEarn.Order.Preflight do
  @moduledoc false
  # The origin-pull gates of `mix raxol_earn.order`, all before any write: the
  # spender pin, the allowance plan checked before signing, and the on-chain
  # check that the signature just produced will verify at settlement.

  alias Mix.Tasks.RaxolEarn.Order.Plan
  alias Raxol.Agent.Secret
  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Earn.Xochi.{OriginPull, PullPreflight}
  alias Raxol.Payments.Protocols.Permit2
  alias Raxol.Payments.Xochi.PullContracts

  # Trust the verified XochiPull contracts plus the spender this run names.
  # The mirrored set is a checked-in deployment record, never widened silently:
  # a rotated address has to be named on the command line.
  @spec pin_origin_pull(String.t() | nil) :: :ok
  def pin_origin_pull(solver) do
    Application.put_env(:raxol_payments, :pull_solver_allowlist, pull_allowlist(solver))
    Application.put_env(:raxol_payments, :pull_require_solver_pin, true)
  end

  # --solver wins over ORDER_SOLVER. Blank values are trimmed BEFORE the
  # fallback, since `--solver ""` is truthy and would otherwise leave the run
  # unpinned.
  @spec pinned_solver(keyword()) :: String.t() | nil
  def pinned_solver(opts) do
    case present(Keyword.get(opts, :solver)) || present(System.get_env("ORDER_SOLVER")) do
      nil -> nil
      value -> solver_address!(value)
    end
  end

  # Decides the pull's SHAPE is safe to sign: an unpinned or mismatched Permit2
  # spender is refused while nothing is signed yet. Returns the plan, not the
  # status read here; the funding batch re-reads the allowance.
  @spec check_origin_pull(map(), map(), keyword()) ::
          {:ok, OriginPull.plan()} | {:error, {:origin_pull, term()}}
  def check_origin_pull(cfg, quote_resp, opts) do
    with {:ok, plan} <- OriginPull.allowance_plan(quote_resp, cfg.solver, origin_leg(cfg)),
         {:ok, status} <- OriginPull.allowance_status(plan, cfg.provider_adapter, cfg.buyer) do
      Enum.each(Plan.origin_pull_lines(status, opts), &Plan.log/1)
      {:ok, plan}
    else
      {:error, reason} -> {:error, {:origin_pull, reason}}
    end
  end

  # Asks whether the signature just produced will be accepted on chain: four
  # read-only calls against `cfg.rpc`, which the task pins to the same chain
  # the createJob and fund writes go to. A served pull with no
  # signature in the bundle aborts both modes; there is nothing to rehearse.
  @spec preflight_pull(map(), map(), map(), keyword()) :: :ok | {:error, term()}
  def preflight_pull(_cfg, %{pull_authorization: nil}, _bundle, _opts), do: :ok

  def preflight_pull(cfg, quote_resp, bundle, opts) do
    with {:ok, signature} <- pull_signature(bundle) do
      outcome =
        PullPreflight.verify(
          quote_resp.pull_authorization,
          signature,
          cfg.buyer,
          rpc: RPC.client(url: cfg.rpc |> Secret.new() |> Secret.reveal()),
          expect_verifier: expected_verifier(quote_resp.payment_method, cfg)
        )

      Plan.log(PullPreflight.describe(outcome))
      decide_preflight(outcome, Keyword.get(opts, :dry_run, false))
    end
  end

  # No catch-all: an outcome nobody named raises `FunctionClauseError` before
  # any write, which is the safe failure. A rejection fails --dry-run too, so a
  # rehearsal exits non-zero on the defect it exists to find. An inconclusive
  # check stays soft only under --dry-run: it says nothing about the payload,
  # and the usual cause is an unreachable ORDER_RPC_8453.
  @spec decide_preflight(PullPreflight.outcome(), boolean()) :: :ok | {:error, atom()}
  def decide_preflight({:ok, _details}, _dry_run?), do: :ok
  def decide_preflight({:rejected, _details}, _dry_run?), do: {:error, :pull_signature_rejected}
  def decide_preflight({:inconclusive, _reason}, true = _dry_run?), do: :ok

  def decide_preflight({:inconclusive, _reason}, false),
    do: {:error, :pull_preflight_inconclusive}

  # Reading a missing signature as "nothing to check" would turn the gate off
  # for exactly the payload it exists to gate.
  defp pull_signature(bundle) do
    case Map.get(bundle, :pull_signature) do
      sig when is_binary(sig) -> {:ok, sig}
      other -> {:error, {:pull_signature_missing, other}}
    end
  end

  # WHO checks the signature comes from the rail we asked for, never from the
  # served `verifyingContract`, which would let a hostile quote nominate its own
  # oracle. Two clauses, no catch-all: `Protocols.Xochi.sign_intent/3` already
  # refused every other payment_method before signing.
  defp expected_verifier("permit2", _cfg), do: Permit2.verifying_contract()
  defp expected_verifier("erc3009", cfg), do: cfg.src_token

  # The transfer the operator asked for; the served permit is cross-checked
  # against it, so the allowance never exceeds the principal.
  defp origin_leg(cfg),
    do: %{chain_id: cfg.from, token: cfg.src_token, amount: cfg.principal_atomic}

  defp pull_allowlist(nil), do: PullContracts.pull_recipients()
  defp pull_allowlist(solver), do: Enum.uniq([solver | PullContracts.pull_recipients()])

  defp present(nil), do: nil

  defp present(value) do
    case String.trim(value) do
      "" -> nil
      trimmed -> trimmed
    end
  end

  defp solver_address!(value) do
    if Regex.match?(~r/\A0x[0-9a-fA-F]{40}\z/, value) do
      value
    else
      Mix.raise(
        "--solver / ORDER_SOLVER #{inspect(value)} is not a 0x-hex 20-byte address. " <>
          "It pins the origin-pull spender, so a typo would either reject every quote " <>
          "or pin the wrong destination."
      )
    end
  end
end
