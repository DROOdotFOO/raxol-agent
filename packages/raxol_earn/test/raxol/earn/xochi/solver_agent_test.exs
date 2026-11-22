defmodule Raxol.Earn.Xochi.SolverAgentTest do
  use ExUnit.Case, async: false

  import Raxol.Earn.TestSupport.SolverAgentFixtures

  alias Raxol.Earn.{ABI, Agent, ProviderAdapter, Transport}
  alias Raxol.Earn.TestSupport.SolverAgentFixtures
  alias Raxol.Earn.Xochi.SolverAgent
  alias Raxol.Payments.Assets

  @solver_wallet SolverAgentFixtures.solver_wallet()
  @acp_core SolverAgentFixtures.acp_core()

  # Real Base WETH (18dp), from Raxol.Payments.Assets.
  @base_weth "0x4200000000000000000000000000000000000006"

  setup do
    {:ok, SolverAgentFixtures.solver_context()}
  end

  describe "job acceptance filtering" do
    test "ignores jobs whose provider is someone else", ctx do
      {:ok, solver} = start_solver([], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry(provider: "0xother"))
      Process.sleep(40)

      assert SolverAgent.sessions(solver) == %{}
    end

    test "accepts jobs targeting our wallet address", ctx do
      {:ok, solver} = start_solver([], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Process.sleep(40)

      assert %{{8453, "42"} => %{status: :awaiting_requirement}} = SolverAgent.sessions(solver)
    end

    test "case-insensitive on the provider address", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      upper = String.upcase(@solver_wallet)
      Transport.Mock.deliver(ctx.transport, job_created_entry(provider: upper))
      Process.sleep(40)

      assert SolverAgent.sessions(solver) |> map_size() == 1
    end
  end

  # The budget is `fee_bps` of the intent's `from_amount`, escrowed as the ACP
  # payment token (USDC, 6dp). `from_amount` is in the ORIGIN token's base units,
  # so that arithmetic only holds when the origin token is itself a 6dp USD
  # stablecoin. Rescaling decimals cannot rescue an 18dp token either: 1 WETH is
  # 1e18 base units, and reading that as 1e6-scaled USDC understates by roughly
  # the ETH price. Without a price oracle the only sound answer is to refuse.
  describe "budget proposal fee-base gate" do
    test "refuses to size a budget from an 18dp origin token", ctx do
      {:ok, solver} =
        start_solver(
          [fee_bps: 50, xochi_config: xochi_stub("1000000", "quoted", from_token: @base_weth)],
          ctx
        )

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "refuses an unregistered origin token rather than assuming 6dp", ctx do
      unknown = "0x" <> String.duplicate("11", 20)

      {:ok, solver} =
        start_solver(
          [fee_bps: 50, xochi_config: xochi_stub("1000000", "quoted", from_token: unknown)],
          ctx
        )

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "refuses a transfer so small the fee truncates to zero", ctx do
      # 50 bps of 100 base units truncates to 0 through `div/2`. A zero budget is
      # an escrow that can never pay, so the job fails closed instead.
      {:ok, solver} =
        start_solver([fee_bps: 50, xochi_config: xochi_stub("100")], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "a 6dp stablecoin origin still proposes a budget", ctx do
      {:ok, solver} = start_solver([fee_bps: 50], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :budget_proposed, budget_atomic: 5_000}} =
               SolverAgent.sessions(solver)
    end
  end

  # The gate reads a SYMBOL, but the arithmetic it protects is about DECIMALS,
  # and a symbol is only a proxy for them. `ensure_stable_origin/1` now asserts
  # the scale directly, which is defence the day the proxy stops holding. This is
  # the early warning for the same drift: `Raxol.Payments.Assets` is compiled
  # from module attributes with no runtime seam, so registering an 18dp token
  # under a stablecoin symbol is a source change, and this is the test it breaks.
  describe "fee-base scale invariant" do
    @fee_base_symbols ~w(USDC USDT USDG)
    @corridor_chains [1, 10, 137, 8453, 42_161, 4663]

    test "every stablecoin the fee can be sized from is 6dp on every corridor chain" do
      registered =
        for chain <- @corridor_chains,
            symbol <- @fee_base_symbols,
            {:ok, address} <- [Assets.address(chain, symbol)] do
          {chain, symbol, address, Assets.decimals(chain, address)}
        end

      # Guards the guard: a comprehension that silently matched nothing would
      # assert nothing. Assets.address/2 returns {:ok, _} | :error, and reading
      # it as a bare address is exactly how this test could go hollow.
      assert length(registered) >= 11

      for {chain, symbol, address, decimals} <- registered do
        assert decimals == 6,
               "#{symbol} on chain #{chain} (#{address}) is #{decimals}dp, but " <>
                 "SolverAgent sizes the ACP fee by reading an origin amount in " <>
                 "this token's base units as 6dp USDC. Either drop it from " <>
                 "@fee_base_symbols or size the fee through a price oracle."
      end
    end
  end

  # `>=` against a non-integer does not raise: Erlang term order puts every
  # number below every atom and binary, so `5000 >= "1"` is false. An unvalidated
  # value would silently reject every job on this path -- a storefront that is
  # down and says nothing. Refusing to start says it instead.
  describe "min fee config validation" do
    test "refuses to start on a min fee that is not a non-negative integer", ctx do
      Process.flag(:trap_exit, true)

      for bad <- ["1", :infinity, 1.0, -1] do
        assert {:error, {:invalid_solver_min_fee_atomic, ^bad}} =
                 start_solver([min_fee_atomic: bad], ctx)
      end
    end

    test "refuses to start on a bad :solver_min_fee_atomic from application config", ctx do
      Process.flag(:trap_exit, true)
      Application.put_env(:raxol_earn, :solver_min_fee_atomic, "1000")
      on_exit(fn -> Application.delete_env(:raxol_earn, :solver_min_fee_atomic) end)

      assert {:error, {:invalid_solver_min_fee_atomic, "1000"}} = start_solver([], ctx)
    end

    test "a valid min fee is honoured over the default", ctx do
      # 50 bps of 1_000_000 is 5_000, which clears the default floor of 1 but not
      # a floor of 10_000.
      {:ok, solver} = start_solver([fee_bps: 50, min_fee_atomic: 10_000], ctx)

      Agent.start_stream(ctx.agent)
      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
    end
  end

  describe "budget proposal" do
    test "after job_created + requirement, submits set_budget on-chain", ctx do
      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :budget_proposed, budget_atomic: budget}} =
               SolverAgent.sessions(solver)

      # Budget is the storefront fee only: 0.5% of 1_000_000 = 5_000. The
      # transfer flows via Xochi off-escrow, not through the ACP budget.
      assert budget == 5_000

      assert [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core
    end

    test "the budget is the storefront fee, a fraction of the transfer, not the transfer", ctx do
      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      %{{8453, "42"} => session} = SolverAgent.sessions(solver)

      # The ACP escrow holds only the storefront fee; the transfer moves through
      # Xochi. So the budget is a small fraction of the transfer, never >= it.
      assert session.budget_atomic == 5_000
      assert session.budget_atomic < session.transfer_amount_atomic
    end

    test "zero fee_bps yields a zero budget", ctx do
      {:ok, solver} = start_solver([fee_bps: 0], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{budget_atomic: 0}} = SolverAgent.sessions(solver)
    end

    test "sizes the fee on Xochi's amount, ignoring the declared amount_atomic", ctx do
      # Buyer understates amount_atomic to 1 base unit; the stub intent carries
      # the authoritative 1_000_000, so the fee is 0.5% of 1_000_000 = 5_000.
      req =
        requirement_message(
          requirement: %{
            "amount_atomic" => "1",
            "signed_intent" => %{
              "intent_id" => "xi_1",
              "quote_id" => "xq_1",
              "signature" => "0x" <> String.duplicate("11", 65),
              "nonce" => 7,
              "pull_signature" => "0x" <> String.duplicate("22", 65)
            }
          }
        )

      {:ok, solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, req)
      Process.sleep(60)

      assert %{{8453, "42"} => session} = SolverAgent.sessions(solver)
      assert session.budget_atomic == 5_000
      assert session.transfer_amount_atomic == 1_000_000
    end

    test "fails the job closed when the intent is not in the quoted state", ctx do
      {:ok, solver} = start_solver([xochi_config: xochi_stub("1000000", "executing")], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # No budget was proposed on-chain: the fee was never sized on an
      # unresolved intent.
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "malformed requirement marks the session :failed", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())

      bad =
        %{
          "kind" => "message",
          "contentType" => "requirement",
          "chainId" => 8453,
          "jobId" => "42",
          "content" => "not-json"
        }

      Transport.Mock.deliver(ctx.transport, bad)
      Process.sleep(60)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # No on-chain calls were made.
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end
  end

  describe "settle flow" do
    test "on job.funded, runs settle_fn and submits on-chain", ctx do
      settle_stub = fn _ ->
        {:ok,
         %{
           intent_id: "xochi-1",
           quote_id: "q-1",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.funded",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(80)

      assert %{{8453, "42"} => session} = SolverAgent.sessions(solver)
      assert session.status == :submitted
      assert session.deliverable.intent_id == "xochi-1"

      # Two ProviderAdapter calls: set_budget then submit.
      assert length(ProviderAdapter.Mock.sent_calls(ctx.provider)) == 2
    end

    test "job.funded settles only the funded job, not other pending sessions", ctx do
      settle_stub = fn _ ->
        {:ok,
         %{
           intent_id: "xochi-42",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      # Two independent jobs both reach :budget_proposed.
      Transport.Mock.deliver(ctx.transport, job_created_entry(job_id: "42"))
      Transport.Mock.deliver(ctx.transport, requirement_message(job_id: "42"))
      Transport.Mock.deliver(ctx.transport, job_created_entry(job_id: "77"))
      Transport.Mock.deliver(ctx.transport, requirement_message(job_id: "77"))
      Process.sleep(80)

      assert %{status: :budget_proposed} = SolverAgent.session(solver, {8453, "42"})
      assert %{status: :budget_proposed} = SolverAgent.session(solver, {8453, "77"})

      # Fund ONLY job 42.
      Transport.Mock.deliver(
        ctx.transport,
        %{"kind" => "system", "event" => "job.funded", "chainId" => 8453, "jobId" => "42"}
      )

      Process.sleep(80)

      # Job 42 settled; job 77 must be untouched -- a job.funded for 42 must not
      # settle (spend funds for) an unfunded job.
      assert SolverAgent.session(solver, {8453, "42"}).status == :submitted
      assert SolverAgent.session(solver, {8453, "77"}).status == :budget_proposed
    end

    test "settle_fn failure marks the session :failed; no submit call", ctx do
      settle_stub = fn _ -> {:error, :solver_offline} end

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.funded",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(80)

      assert %{{8453, "42"} => %{status: :failed}} = SolverAgent.sessions(solver)
      # Just set_budget; no submit.
      assert length(ProviderAdapter.Mock.sent_calls(ctx.provider)) == 1
    end
  end

  describe "completion" do
    test "job.completed event updates session status", ctx do
      {:ok, solver} = start_solver([], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Process.sleep(40)

      Transport.Mock.deliver(
        ctx.transport,
        %{
          "kind" => "system",
          "event" => "job.completed",
          "chainId" => 8453,
          "jobId" => "42"
        }
      )

      Process.sleep(40)

      session = SolverAgent.session(solver, {8453, "42"})
      assert session.status == :completed
    end
  end

  describe "plain job (hook = address(0))" do
    test "set_budget is a plain setBudget with empty hook data and a fee budget", ctx do
      {:ok, _solver} = start_solver([fee_bps: 50], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, job_created_entry())
      Transport.Mock.deliver(ctx.transport, requirement_message())
      Process.sleep(60)

      [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core

      # The calldata is exactly setBudget(jobId=42, amount=fee, data=<<>>) -- no
      # FundTransfer payload. Re-encoding with the same ABI encoder pins it
      # without hardcoding byte offsets. fee = 0.5% of 1_000_000 = 5_000.
      expected =
        ABI.encode_call("setBudget(uint256,uint256,bytes)", [
          {"uint256", 42},
          {"uint256", 5_000},
          {"bytes", <<>>}
        ])

      assert call.data == expected
    end
  end

  test "format_status/1 hides the provider and the Xochi config" do
    state = %SolverAgent{
      provider: %{config: %{key: "sek-1"}},
      xochi_config: %{auth_token: "sek-2"}
    }

    status = SolverAgent.format_status(%{state: state, reason: {:boom, "sek-3"}, log: [:x]})

    refute inspect(status, structs: false, limit: :infinity) =~ "sek-"
  end
end
