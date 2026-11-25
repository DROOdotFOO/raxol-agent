defmodule Mix.Tasks.RaxolEarn.Order do
  @shortdoc "Place a real ACP order (buyer) against a live agent offering"

  @moduledoc """
  Live BUYER harness: creates a real on-chain ACP job for an agent's offering,
  sends the requirement, and watches the provider set the budget on-chain.

    1. Quote, check the origin pull against the `--solver` pin, and sign a Xochi
       intent as the buyer; then verify on-chain that the pull signature will be
       accepted (four read-only calls).
    2. `createJob` on the ACP Core (skipped with `--job-id`) and resolve the id.
    3. Send the requirement to the job's chat room (retried while it lags).
    4. Poll `getJob(jobId).budget` and check it against `--fee-bps`.
    5. With `--fund`: one batched approve + `fund(jobId, budget)`, carrying the
       origin-pull `approve(Permit2)` when the allowance is short.

  MOVES REAL FUNDS. Each UserOp pays its own gas in USDC; `--fund` adds the fee
  escrow. The principal is only AUTHORIZED here and pulled by the solver at
  settlement. A spend plan is printed first, and receipt actuals after each
  write. `--dry-run` signs and stops; it still exits non-zero when the pull
  signature is rejected on-chain.

  A Permit2 pull has no on-chain recipient guard, so it is refused before
  signing unless `--solver` / `ORDER_SOLVER` names the spender the quote served.

  ## Signers (`--signer`)

    * `privy` (default) -- managed 7702 agent at `RAXOL_ACP_WALLET_ADDRESS`,
      signing through the Node sidecar in `priv/signer_sidecar`.
    * `sca` -- ERC-4337 with the `ORDER_KEY` session key, your own bundler and
      paymaster (`ORDER_BUNDLER_URL`, `ORDER_PAYMASTER_POLICY`).
    * `eoa` -- raw `ORDER_KEY` EOA; not a registered agent (messaging 404s).

  ## Env

      ORDER_KEY          session-key EOA (0x-hex), for sca/eoa.
      ORDER_RPC_8453     Base JSON-RPC (default mainnet); ACP core and origin chain.
      ORDER_XOCHI_TOKEN  Xochi Member token.  ORDER_XOCHI_URL default api.xochi.fi.
      ORDER_SOLVER       origin-pull spender to pin, when --solver is not passed.
      ORDER_BUNDLER_URL, ORDER_PAYMASTER_POLICY    the sca backend.
      RAXOL_ACP_WALLET_ADDRESS, RAXOL_ACP_WALLET_ID,
      RAXOL_ACP_SIGNER_PRIVATE_KEY, PRIVY_APP_ID   the privy backend; the
      sidecar listens on RAXOL_ACP_SIGNER_PORT or RAXOL_ACP_SIDECAR_URL, which
      must be loopback unless RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1.

  ## Flags

      --signer B         privy (default) | sca | eoa
      --amount N         principal in USDC (default 3.00)
      --corridor F>T     origin>destination chain ids (default 8453>42161); the
                         origin must be the ACP core's chain (8453)
      --provider 0x..    seller wallet to hire (default the raxol agent)
      --solver 0x..      origin-pull spender to pin (required for Permit2 pulls)
      --fee-bps N        expected take-rate (default 8)
      --max-escrow N     USDC ceiling on what --fund pays (default: the take-rate)
      --job-id N         resume an existing job (skip createJob)
      --fund             fund the escrow once the budget is set
      --dry-run          sign only, no on-chain writes

      mix raxol_earn.order --amount 3.00 --solver 0x<spender>
  """

  use Mix.Task

  alias Mix.Tasks.RaxolEarn.Order.{Budget, Errors, Plan, Preflight, Signer}
  alias Raxol.Agent.Secret
  alias Raxol.Earn.{ABI, Agent, Auth, Chain, JobApi, JobIdResolver, ProviderAdapter}
  alias Raxol.Earn.Transport
  alias Raxol.Earn.Xochi.{OriginPull, PullPreflight}
  alias Raxol.Payments.Assets
  alias Raxol.Payments.Protocols.Xochi, as: XochiProtocol
  alias Raxol.Payments.Xochi.Client, as: XochiClient
  alias Raxol.Payments.Xochi.Schemas.QuoteRequest

  # The raxol agent (seller) wallet: the provider a buyer hires by default.
  @default_provider "0x939ead944b5d28b86d91af1961812d3bbc46cac1"
  @offering "xochi_crosschain"
  @sla_minutes 5
  @zero_address "0x0000000000000000000000000000000000000000"

  @switches [
    amount: :string,
    corridor: :string,
    provider: :string,
    solver: :string,
    fee_bps: :integer,
    max_escrow: :string,
    fund: :boolean,
    dry_run: :boolean,
    job_id: :integer,
    signer: :string
  ]

  @impl Mix.Task
  def run(argv) do
    opts = parse_argv(argv)

    Application.ensure_all_started(:raxol_earn)

    cfg = build_config(opts)
    Preflight.pin_origin_pull(cfg.solver)

    Plan.log(
      "buyer=#{cfg.buyer}  provider=#{cfg.provider}  corridor=#{cfg.from}->#{cfg.to}  amount=#{cfg.amount} USDC"
    )

    # Printed before anything, --dry-run included: rehearsing is what it is for.
    cfg
    |> Plan.spend_plan_lines(opts, Budget.resume_escrow(cfg, opts))
    |> Enum.each(&Plan.log/1)

    # What survives to funding is the cross-checked PLAN, not the allowance
    # read taken here, which is stale by then.
    {bundle, plan} =
      case sign_intent(cfg, opts) do
        {:ok, signed} -> signed
        {:error, reason} -> Mix.raise(Errors.sign_intent(reason))
      end

    requirement = requirement(cfg, bundle)
    Plan.log("signed Xochi intent: #{bundle[:intent_id] || bundle["intent_id"]}")

    if opts[:dry_run] do
      Plan.log("--dry-run: signed only, no on-chain writes. requirement=#{inspect(requirement)}")
    else
      place(cfg, requirement, opts, plan)
    end
  end

  @doc false
  # Public so the spend gate can be exercised against the flags an operator types.
  @spec parse_argv([String.t()]) :: keyword()
  def parse_argv(argv) do
    {opts, _argv, _invalid} = OptionParser.parse(argv, strict: @switches)
    opts
  end

  @doc false
  @spec privy_provider() :: ProviderAdapter.adapter()
  defdelegate privy_provider, to: Signer, as: :signing_provider

  @doc false
  @spec spend_plan_lines(map(), keyword(), Plan.escrow()) :: [String.t()]
  defdelegate spend_plan_lines(cfg, opts, escrow), to: Plan

  @doc false
  @spec spend_actual_lines(map(), String.t(), [Plan.receipt_read()]) :: [String.t()]
  defdelegate spend_actual_lines(cfg, label, reads), to: Plan

  @doc false
  @spec origin_pull_lines(OriginPull.status(), keyword()) :: [String.t()]
  defdelegate origin_pull_lines(status, opts), to: Plan

  @doc false
  @spec funding_line(non_neg_integer(), OriginPull.status()) :: String.t()
  defdelegate funding_line(job_id, pull), to: Plan

  @doc false
  @spec budget_verdict(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  defdelegate budget_verdict(cfg, budget, ceiling), to: Budget

  @doc false
  @spec preflight_pull(map(), map(), map(), keyword()) :: :ok | {:error, term()}
  defdelegate preflight_pull(cfg, quote_resp, bundle, opts), to: Preflight

  @doc false
  @spec decide_preflight(PullPreflight.outcome(), boolean()) ::
          :ok | {:error, atom()}
  defdelegate decide_preflight(outcome, dry_run?), to: Preflight

  @doc false
  # Over-ceiling is disclosure without --fund (nothing is approved) and a hard
  # stop with it.
  @spec enforce_budget!(map(), non_neg_integer(), keyword()) :: :ok
  def enforce_budget!(cfg, budget, opts) do
    case {Budget.budget_verdict(cfg, budget, Budget.escrow_ceiling(cfg, opts)),
          Keyword.get(opts, :fund, false)} do
      {{:ok, line}, _funding?} -> Plan.log(line)
      {{:error, message}, false} -> Plan.log("WARN: " <> message)
      {{:error, message}, true} -> Mix.raise(message)
    end
  end

  @doc false
  # The batch is decided against an allowance read taken now, not the one taken
  # at signing: minutes have passed and an earlier intent's pull can have spent
  # it down. A failed read aborts, since funding without the approve strands
  # the escrow.
  @spec fund_time_allowance(map(), OriginPull.plan()) :: OriginPull.status()
  def fund_time_allowance(cfg, plan) do
    case OriginPull.allowance_status(plan, cfg.provider_adapter, cfg.buyer) do
      {:ok, status} ->
        Plan.log("at funding time -- " <> OriginPull.describe(status))
        status

      {:error, reason} ->
        Mix.raise(OriginPull.explain(reason))
    end
  end

  @doc false
  # approve (USDC) + fund (ACP Core) in ONE UserOp: the Virtuals paymaster
  # refuses a standalone approve to a token contract. The origin-pull approve
  # rides first, so the allowance lands in the same transaction as the escrow.
  @spec funding_calls(map(), non_neg_integer(), non_neg_integer(), OriginPull.status()) ::
          [ProviderAdapter.call()]
  def funding_calls(cfg, job_id, budget, pull) do
    OriginPull.approve_calls(pull) ++
      [
        %{
          to: cfg.src_token,
          data:
            ABI.encode_call("approve(address,uint256)", [
              {"address", cfg.core},
              {"uint256", budget}
            ]),
          value: 0
        },
        %{
          to: cfg.core,
          data:
            ABI.encode_call("fund(uint256,uint256,bytes)", [
              {"uint256", job_id},
              {"uint256", budget},
              {"bytes", <<>>}
            ]),
          value: 0
        }
      ]
  end

  defp place(cfg, requirement, opts, plan) do
    {agent, resolver} = start_buyer(cfg)

    job_id =
      case Keyword.get(opts, :job_id) do
        nil -> create_and_resolve(cfg, resolver)
        existing -> tap(existing, &Plan.log("resuming job #{&1} (skip createJob)"))
      end

    :ok = send_requirement(agent, cfg.from, job_id, requirement)
    Plan.log("requirement sent for job #{job_id}")

    budget = await_budget(cfg, job_id)
    realized_bps = Float.round(budget / cfg.principal_atomic * 10_000, 3)

    Plan.log("provider setBudget = #{budget} base units (#{realized_bps} bps)")
    enforce_budget!(cfg, budget, opts)

    Plan.log("job #{job_id} is live -- view it at https://app.virtuals.io/acp")

    if Keyword.get(opts, :fund, false), do: fund_job(cfg, job_id, budget, plan)
  end

  defp create_and_resolve(cfg, resolver) do
    expired_at = System.system_time(:second) + @sla_minutes * 60 + 60

    job = %{
      provider: cfg.provider,
      evaluator: @zero_address,
      expired_at: expired_at,
      hook_address: @zero_address,
      description: @offering
    }

    tx =
      case Signer.create_job(cfg.provider_adapter, cfg.from, cfg.core, job) do
        {:ok, tx} ->
          tx

        {:error, {:sidecar_unhealthy, url, r}} ->
          Mix.raise(Errors.write_blocked(:create_job, url, r))

        err ->
          Mix.raise("createJob failed: #{inspect(err)}")
      end

    Plan.log("createJob tx: #{Plan.explorer(cfg.from)}#{tx}")
    report_actuals(cfg, "createJob", tx)

    job_id = await_job_id(resolver, cfg, tx)
    Plan.log("jobId: #{job_id}")
    job_id
  end

  defp fund_job(cfg, job_id, budget, plan) do
    pull = fund_time_allowance(cfg, plan)
    label = batch_label(pull)
    Plan.log(Plan.funding_line(job_id, pull))

    case Signer.send_calls(
           cfg.provider_adapter,
           cfg.from,
           funding_calls(cfg, job_id, budget, pull)
         ) do
      {:ok, txs} ->
        Plan.log("funded (#{label} batched): #{inspect(txs)} -- provider will settle + deliver")
        report_actuals(cfg, label, txs)

      {:error, {:sidecar_unhealthy, url, reason}} ->
        Mix.raise(Errors.write_blocked({:fund, job_id}, url, reason))

      err ->
        Mix.raise(
          "fund failed for job #{job_id}: #{inspect(err)}. The job is on chain; check " <>
            "whether its funding landed (#{Plan.explorer(cfg.from)}) before re-running with " <>
            "--job-id #{job_id} --fund."
        )
    end
  end

  defp batch_label({:short, _permit}), do: "approve(Permit2)+approve+fund"
  defp batch_label(_pull), do: "approve+fund"

  defp report_actuals(cfg, label, tx_hashes) do
    client = Budget.rpc_client(cfg)

    tx_hashes
    |> List.wrap()
    |> Enum.map(&{&1, Budget.buyer_transfers(client, cfg, &1)})
    |> then(&Plan.spend_actual_lines(cfg, label, &1))
    |> Enum.each(&Plan.log/1)
  rescue
    # Accounting must never take down a run that already moved money.
    e -> Plan.log("SPEND ACTUAL (#{label}): could not read receipts (#{Exception.message(e)})")
  end

  # Quote first, so the origin-pull rail comes from what the solver served, and
  # decide that rail's allowance before releasing a signature over it.
  defp sign_intent(cfg, opts) do
    request = %QuoteRequest{
      wallet: cfg.buyer,
      from_chain_id: cfg.from,
      to_chain_id: cfg.to,
      from_token: cfg.src_token,
      to_token: cfg.dst_token,
      from_amount: Integer.to_string(cfg.principal_atomic),
      settlement_preference: "public",
      slippage_bps: 50
    }

    with {:ok, quote_resp} <- XochiProtocol.get_quote(cfg.xochi_config, request),
         {:ok, pull} <- Preflight.check_origin_pull(cfg, quote_resp, opts),
         {:ok, bundle} <- XochiProtocol.sign_intent(quote_resp, cfg.intent_wallet, request),
         :ok <- Preflight.preflight_pull(cfg, quote_resp, bundle, opts) do
      {:ok, {bundle, pull}}
    end
  end

  defp requirement(cfg, bundle) do
    %{
      "src_chain_id" => cfg.from,
      "dst_chain_id" => cfg.to,
      "src_token" => cfg.src_token,
      "dst_token" => cfg.dst_token,
      "amount_atomic" => Integer.to_string(cfg.principal_atomic),
      "settlement_preference" => "public",
      "signed_intent" => Map.new(bundle, fn {k, v} -> {to_string(k), v} end)
    }
  end

  defp start_buyer(cfg) do
    # Auth signs its login through the same sidecar: checked here, at start.
    {:ok, auth} =
      Auth.start_link(
        provider: Signer.verify_sidecar!(cfg.provider_adapter),
        server_url: cfg.server_url,
        chain_id: cfg.from
      )

    transport =
      Transport.SSE.new(auth: auth, server_url: cfg.server_url, supported_chain_ids: [cfg.from])

    api = JobApi.HTTP.new(auth: auth, server_url: cfg.server_url, chain_ids: [cfg.from])

    {:ok, agent} =
      Agent.start_link(
        provider: cfg.provider_adapter,
        transport: transport,
        api: api,
        wallet_address: cfg.buyer,
        supported_chain_ids: [cfg.from],
        default_role: :client
      )

    Agent.subscribe(agent)
    Agent.start_stream(agent)

    # `emitter` + `client` scope the JobCreated search to this buyer's job: a
    # bundle receipt also carries other senders' JobCreated logs.
    resolver = %{
      adapter: JobIdResolver.Receipt,
      config: %{
        event_signature: "JobCreated(uint256,address,address,address,uint256,address)",
        topic_index: 1,
        emitter: cfg.core,
        client: cfg.buyer
      }
    }

    {agent, resolver}
  end

  defp await_job_id(resolver, cfg, tx, tries \\ 30)

  defp await_job_id(_resolver, _cfg, tx, 0),
    do: Mix.raise("createJob #{tx} not mined / jobId not decodable in time")

  defp await_job_id(resolver, cfg, tx, tries) do
    case JobIdResolver.resolve(resolver, cfg.provider_adapter, cfg.from, tx) do
      {:ok, job_id} ->
        job_id

      {:error, reason} ->
        Mix.raise("jobId resolve failed: #{inspect(reason)}")

      :pending ->
        Process.sleep(2_000)
        await_job_id(resolver, cfg, tx, tries - 1)
    end
  end

  # The off-chain chat room may not exist immediately after createJob.
  defp send_requirement(agent, chain_id, job_id, requirement, tries \\ 12)

  defp send_requirement(_agent, _chain_id, job_id, _requirement, 0),
    do: Mix.raise("could not deliver requirement for job #{job_id} (chat room never ready)")

  defp send_requirement(agent, chain_id, job_id, requirement, tries) do
    case Agent.send_message(
           agent,
           {chain_id, to_string(job_id)},
           Jason.encode!(requirement),
           "requirement"
         ) do
      :ok ->
        :ok

      err ->
        Plan.log("send_message attempt #{13 - tries} failed: #{inspect(err)}")
        Process.sleep(3_000)
        send_requirement(agent, chain_id, job_id, requirement, tries - 1)
    end
  end

  defp await_budget(cfg, job_id, tries \\ 60)

  defp await_budget(_cfg, job_id, 0),
    do: Mix.raise("provider never set a budget for job #{job_id}")

  defp await_budget(cfg, job_id, tries) do
    case Budget.read_budget(cfg, job_id) do
      {:ok, budget} when budget > 0 ->
        budget

      _ ->
        Process.sleep(3_000)
        await_budget(cfg, job_id, tries - 1)
    end
  end

  defp build_config(opts) do
    {from, to} = parse_corridor(Keyword.get(opts, :corridor, "8453>42161"))
    assert_acp_origin!(from)
    amount = Keyword.get(opts, :amount, "3.00")

    # `acp_rpc` reads the ACP core; `rpc` is the origin chain the buyer signs
    # on. `assert_acp_origin!/1` makes them the same chain; the names record
    # which role each read plays.
    acp_rpc = System.get_env("ORDER_RPC_8453", Chain.mainnet().rpc_url)
    rpc = System.get_env("ORDER_RPC_#{from}", acp_rpc)

    src_token = usdc_address!(from, "origin")
    dst_token = usdc_address!(to, "destination")
    principal_atomic = Assets.to_atomic(Decimal.new(amount), Assets.decimals(from, src_token))

    # Before the signer, which boots the sidecar: a malformed pin should not
    # cost a subprocess to discover.
    solver = Preflight.pinned_solver(opts)

    signer = Keyword.get(opts, :signer, "privy")
    {provider_adapter, buyer, intent_wallet} = Signer.build(signer, from, rpc)
    Plan.log("signer backend: #{signer}")

    %{
      buyer: buyer,
      intent_wallet: intent_wallet,
      provider_adapter: provider_adapter,
      provider: Keyword.get(opts, :provider, @default_provider),
      solver: solver,
      from: from,
      to: to,
      amount: amount,
      principal_atomic: principal_atomic,
      src_token: src_token,
      dst_token: dst_token,
      fee_bps: Keyword.get(opts, :fee_bps, 8),
      signer: signer,
      # Wrapped: `cfg` is an argument of nearly every function here, so a
      # FunctionClauseError prints it, and RPC URLs embed provider keys.
      rpc: Secret.new(rpc),
      acp_rpc: Secret.new(acp_rpc),
      core: Chain.mainnet().acp_core_address,
      server_url: Chain.mainnet().acp_server_url,
      xochi_config:
        XochiClient.protect_config(%{
          base_url: System.get_env("ORDER_XOCHI_URL", "https://api.xochi.fi"),
          auth_token: System.get_env("ORDER_XOCHI_TOKEN", "")
        })
    }
  end

  # The whole ACP lifecycle runs on the origin chain, and the funding batch
  # carries the origin-chain Permit2 approve beside the Base ACP fund: one batch
  # cannot span two chains, so a non-Base origin is refused up front.
  defp assert_acp_origin!(from) do
    core_chain = Chain.mainnet().chain_id

    case from do
      ^core_chain ->
        :ok

      other ->
        Mix.raise("""
        --corridor origin #{other} is not the ACP core's chain (#{core_chain}).

        This task creates and funds a real ACP job, and the ACP core is deployed
        only on chain #{core_chain}. The origin-pull approve rides in the same
        batch as that job's fund call, so the origin leg cannot be a different
        chain than the job.

        Order FROM #{core_chain} (the destination is free): --corridor #{core_chain}>#{other}
        """)
    end
  end

  defp parse_corridor(spec) do
    [from, to] = String.split(spec, ">", parts: 2)
    {String.to_integer(String.trim(from)), String.to_integer(String.trim(to))}
  end

  defp usdc_address!(chain_id, side) do
    case Assets.address(chain_id, "USDC") do
      {:ok, address} ->
        address

      :error ->
        # Read the USDC table itself: `Assets.supported_chain_ids/0` also lists
        # chains that carry other tokens but no USDC.
        supported =
          Assets.evm_tokens()
          |> Map.fetch!("USDC")
          |> Map.keys()
          |> Enum.sort()
          |> Enum.map_join(", ", &"#{&1} (#{Assets.chain_name(&1)})")

        Mix.raise("""
        no USDC address for the #{side} chain #{chain_id}.

        Check --corridor (origin>destination). Chains with a USDC address:
          #{supported}
        """)
    end
  end
end
