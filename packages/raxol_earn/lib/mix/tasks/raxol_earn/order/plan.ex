defmodule Mix.Tasks.RaxolEarn.Order.Plan do
  @moduledoc false
  # Operator-facing lines for `mix raxol_earn.order`: the spend plan printed
  # before anything happens, the origin-pull disclosure, the funding line, and
  # receipt-derived actuals. Pure apart from `log/1`.

  alias Mix.Tasks.RaxolEarn.Order.Budget
  alias Raxol.Earn.Xochi.OriginPull
  alias Raxol.Payments.Assets

  @type escrow :: :new_job | :unreadable | {:ok, non_neg_integer()}
  @type receipt_read ::
          {String.t(), {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}}

  # The ERC-20 paymaster that fronts the ETH for the Virtuals-managed SCA and
  # bills the buyer in USDC on Base. Any other recipient is unplanned spend.
  @paymaster "0x5d74bdab1ce9ddadd7e2e333d1d173830860694a"

  @explorers %{
    1 => "https://etherscan.io/tx/",
    10 => "https://optimistic.etherscan.io/tx/",
    137 => "https://polygonscan.com/tx/",
    8453 => "https://basescan.org/tx/",
    42_161 => "https://arbiscan.io/tx/"
  }

  @spec log(String.t()) :: :ok
  def log(msg), do: Mix.shell().info("[order] " <> msg)

  @spec explorer(pos_integer()) :: String.t()
  def explorer(chain_id), do: Map.get(@explorers, chain_id, "")

  # Every line is a bound or an expectation; actuals come from receipts. The
  # principal is AUTHORIZED by the signed intent and pulled later by the
  # solver, so it is never reported as escrow.
  @spec spend_plan_lines(map(), keyword(), escrow()) :: [String.t()]
  def spend_plan_lines(cfg, opts, escrow) do
    decimals = Assets.decimals(cfg.from, cfg.src_token)

    ["SPEND PLAN -- buyer #{cfg.buyer} on chain #{cfg.from}, amounts in USDC"] ++
      escrow_lines(cfg, decimals, Budget.escrow_ceiling(cfg, opts), escrow) ++
      [
        "  gas         #{gas_note(cfg.signer)}",
        "             writes this run: #{writes(opts)}"
      ] ++
      permit2_lines(cfg, opts) ++
      [
        "  principal   #{cfg.amount} AUTHORIZED, not moved here -- the signed intent lets " <>
          "the solver pull up to that during settlement"
      ] ++ plan_footer(opts)
  end

  # A run that signs a Permit2 intent without funding grants no allowance, so
  # it must say the pull it authorized cannot execute yet.
  @spec origin_pull_lines(OriginPull.status(), keyword()) :: [String.t()]
  def origin_pull_lines(status, opts) do
    [OriginPull.describe(status)] ++
      grant_lines(status, Keyword.get(opts, :dry_run, false), Keyword.get(opts, :fund, false))
  end

  @spec funding_line(non_neg_integer(), OriginPull.status()) :: String.t()
  def funding_line(job_id, {:short, permit}),
    do:
      "funding escrow: batched approve(Permit2, #{permit.amount}) + approve + " <>
        "fund(#{job_id}) in one UserOp -- gas billed to the buyer in USDC"

  def funding_line(job_id, _pull),
    do:
      "funding escrow: batched approve + fund(#{job_id}) in one UserOp -- " <>
        "gas billed to the buyer in USDC"

  # An unread receipt is an unknown, not a zero, and must not print like one.
  @spec spend_actual_lines(map(), String.t(), [receipt_read()]) :: [String.t()]
  def spend_actual_lines(cfg, label, reads) do
    decimals = Assets.decimals(cfg.from, cfg.src_token)
    {read, failed} = Enum.split_with(reads, &match?({_hash, {:ok, _}}, &1))
    transfers = Enum.flat_map(read, fn {_hash, {:ok, transfers}} -> transfers end)

    headline(label, decimals, transfers, failed) ++
      Enum.map(transfers, fn {to, amount} ->
        "  #{Assets.to_human(amount, decimals)} -> #{to}#{destination_note(cfg, to)}"
      end) ++
      Enum.map(failed, fn {hash, {:error, reason}} ->
        "  UNREAD receipt #{hash} (#{inspect(reason)}) -- check #{explorer(cfg.from)}#{hash}"
      end)
  end

  # `eoa` pays ETH for plain EIP-1559 txs; the smart-account signers go through
  # an ERC-20 paymaster that bills USDC.
  defp gas_note("eoa"),
    do:
      "paid in ETH by the buyer EOA, NOT in USDC and NOT free; priced per tx, " <>
        "known only from the receipt"

  defp gas_note(_signer),
    do:
      "charged in USDC from the buyer by an ERC-20 paymaster, NOT in ETH " <>
        "and NOT free; priced per UserOp, known only from the receipt"

  # The approve(Permit2) has no write of its own: it rides inside the --fund
  # batch, because the Virtuals paymaster refuses a standalone approve.
  defp permit2_lines(cfg, opts) do
    Enum.concat(
      pull_lines(cfg, Keyword.get(opts, :dry_run, false), Keyword.get(opts, :fund, false)),
      ["             spender pin: #{spender_pin(cfg)}"]
    )
  end

  defp pull_lines(cfg, true = _dry_run?, _funding?) do
    [
      "  permit2     no approve(Permit2) #{write_noun(cfg.signer)} is sent under --dry-run; the " <>
        "run reads the allowance and reports whether a funded run would need one"
    ]
  end

  defp pull_lines(cfg, false, true = _funding?) do
    [
      "  permit2     the approve(Permit2) rides INSIDE the approve+fund " <>
        "#{write_noun(cfg.signer)} -- no separate write, no extra gas -- IF the quote's " <>
        "origin pull is Permit2 and the buyer's allowance is short",
      "             approves exactly the intent's authorized pull, not a standing max"
    ]
  end

  defp pull_lines(cfg, false, false) do
    [
      "  permit2     no approve(Permit2) #{write_noun(cfg.signer)} without --fund: the approve " <>
        "rides in the funding batch, so a run that signs a Permit2 intent here leaves that " <>
        "intent's pull unexecutable until a --fund run grants the allowance"
    ]
  end

  defp write_noun("eoa"), do: "tx"
  defp write_noun(_signer), do: "UserOp"

  defp spender_pin(%{solver: nil}),
    do:
      "NONE -- a Permit2 pull is refused before signing (pass --solver 0x.. / ORDER_SOLVER); " <>
        "Permit2 has no on-chain recipient guard, so the pin is the only destination control"

  defp spender_pin(%{solver: solver}), do: solver

  defp escrow_lines(cfg, decimals, ceiling, :new_job) do
    [
      "  escrow     ~#{Assets.to_human(Budget.expected_escrow(cfg), decimals)} expected " <>
        "(#{cfg.fee_bps} bps of #{cfg.amount}) -> ACP Core #{cfg.core}",
      "             the PROVIDER sets the real budget on-chain; --fund pays what it set, " <>
        ceiling_note(ceiling, decimals)
    ]
  end

  defp escrow_lines(cfg, decimals, ceiling, {:ok, budget}) do
    [
      "  escrow      #{Assets.to_human(budget, decimals)} ON-CHAIN -- the resumed job's own " <>
        "budget -> ACP Core #{cfg.core}",
      "             --amount/--fee-bps do not describe a resumed job; --fund pays it, " <>
        ceiling_note(ceiling, decimals)
    ]
  end

  defp escrow_lines(cfg, decimals, ceiling, :unreadable) do
    [
      "  escrow      UNKNOWN -- could not read the resumed job's budget on chain #{cfg.from}",
      "             --amount/--fee-bps do not describe a resumed job; --fund pays what the " <>
        "provider set, " <> ceiling_note(ceiling, decimals)
    ]
  end

  defp ceiling_note(ceiling, decimals),
    do:
      "refusing anything above #{Assets.to_human(ceiling, decimals)} (raise it with --max-escrow)"

  # Every leg that can broadcast, in order. The Permit2 approve is named inside
  # the funding leg because that is where it rides.
  defp writes(opts), do: describe_writes(Keyword.get(opts, :dry_run, false), opts)

  defp describe_writes(true, _opts), do: "none (--dry-run writes nothing on-chain)"

  defp describe_writes(false, opts) do
    [
      if(Keyword.get(opts, :job_id), do: nil, else: "createJob"),
      if(Keyword.get(opts, :fund, false), do: fund_leg(), else: nil)
    ]
    |> Enum.reject(&is_nil/1)
    |> join_writes()
  end

  defp fund_leg, do: "approve+fund (carrying the approve(Permit2) if the pull needs it)"

  defp join_writes([]), do: "none (without --fund and without createJob, this run only signs)"
  defp join_writes(legs), do: Enum.join(legs, ", ")

  defp plan_footer(opts) do
    footer(
      Keyword.get(opts, :dry_run, false),
      Keyword.get(opts, :fund, false),
      Keyword.get(opts, :job_id) != nil
    )
  end

  defp footer(true, _funding?, _resuming?),
    do: ["  (--dry-run: signs the intent and stops, spends nothing)"]

  defp footer(false, true, _resuming?), do: []

  defp footer(false, false, false),
    do: ["  (no --fund: no escrow this run, but the createJob write still costs gas)"]

  defp footer(false, false, true),
    do: [
      "  (no --fund and no createJob: this run signs an intent and broadcasts nothing, so " <>
        "a Permit2 pull it authorizes stays unexecutable)"
    ]

  defp grant_lines({:short, _permit}, true, _funding?),
    do: [
      "origin pull: --dry-run sends no approve; a funded run grants it inside the " <>
        "approve+fund batch"
    ]

  defp grant_lines({:short, _permit}, false, true),
    do: [
      "origin pull: that approve rides in the approve+fund batch, so the allowance lands " <>
        "in the same transaction as the escrow"
    ]

  defp grant_lines({:short, _permit}, false, false),
    do: [
      "WARN: this run does not --fund, so no approve is sent. The intent is signed and its " <>
        "pull authorized, but that pull CANNOT execute until the allowance exists -- " <>
        "re-run with --job-id <id> --fund to grant it in the funding batch."
    ]

  defp grant_lines(_status, _dry_run?, _funding?), do: []

  defp headline(label, _decimals, [], []),
    do: ["SPEND ACTUAL (#{label}): no USDC left the buyer"]

  defp headline(label, decimals, transfers, []) do
    [
      "SPEND ACTUAL (#{label}): #{Assets.to_human(total(transfers), decimals)} USDC left the buyer"
    ]
  end

  defp headline(label, decimals, transfers, failed) do
    [
      "SPEND ACTUAL (#{label}): at least #{Assets.to_human(total(transfers), decimals)} USDC " <>
        "left the buyer -- LOWER BOUND, #{length(failed)} receipt(s) unread"
    ]
  end

  defp total(transfers), do: transfers |> Enum.map(&elem(&1, 1)) |> Enum.sum()

  defp destination_note(cfg, to) do
    core = String.downcase(cfg.core)

    case String.downcase(to) do
      ^core -> "  (ACP Core -- the fee escrow)"
      @paymaster -> "  (gas: ERC-20 paymaster)"
      _ -> "  (UNEXPECTED recipient -- neither the fee escrow nor the known paymaster)"
    end
  end
end
