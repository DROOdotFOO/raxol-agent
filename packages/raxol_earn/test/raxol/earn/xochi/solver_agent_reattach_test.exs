defmodule Raxol.Earn.Xochi.SolverAgentReattachTest do
  use ExUnit.Case, async: false

  import Raxol.Earn.TestSupport.SolverAgentFixtures, only: [start_solver: 2, requirement: 0]

  alias Raxol.Earn.{Agent, ProviderAdapter, Transport}
  alias Raxol.Earn.TestSupport.SolverAgentFixtures
  alias Raxol.Earn.Xochi.SolverAgent

  @solver_wallet SolverAgentFixtures.solver_wallet()
  @acp_core SolverAgentFixtures.acp_core()

  setup do
    {:ok, SolverAgentFixtures.solver_context()}
  end

  describe "reattach after restart (deployed funded->settle path)" do
    # The solver set the budget, then restarted before the buyer funded: no
    # in-memory session, and the live SSE stream never replays earlier entries.
    # `handle_job_funded/2` must rebuild from job history and settle.

    # Raw wire-shaped history entries: a system `job.created` (nested event map,
    # onChainJobId) and a `requirement` message. Parser.normalize/1 folds these
    # into the shape the reattach reads, same as the live stream.
    defp history_created(job_id, provider) do
      %{
        "kind" => "system",
        "event" => %{"type" => "job.created", "provider" => provider, "onChainJobId" => job_id},
        "chainId" => 8453
      }
    end

    defp history_requirement(job_id) do
      req = requirement()

      %{
        "kind" => "message",
        "contentType" => "requirement",
        "chainId" => 8453,
        "onChainJobId" => job_id,
        "content" => Jason.encode!(req)
      }
    end

    defp funded(job_id) do
      %{"kind" => "system", "event" => "job.funded", "chainId" => 8453, "jobId" => job_id}
    end

    test "rebuilds the session from history and settles a funded job the solver never saw created",
         ctx do
      test_pid = self()

      settle_stub = fn args ->
        send(test_pid, {:settled, args})

        {:ok,
         %{
           intent_id: "xochi-reattach",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      # The ACP server holds the job's history; the solver's memory does not.
      Transport.Mock.set_history(ctx.transport, {8453, 70_759}, [
        history_created(70_759, @solver_wallet),
        history_requirement(70_759)
      ])

      # ...and the job is genuinely funded on-chain (the reattach gate reads it).
      ProviderAdapter.Mock.set_contract_read(ctx.provider, @acp_core, "getJob(uint256)", 1)

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      # ONLY a funded event arrives (post-restart) -- no job.created, no requirement.
      Transport.Mock.deliver(ctx.transport, funded(70_759))
      Process.sleep(80)

      # The relay ran on the recovered signed intent...
      assert_received {:settled, %{signed_intent: %{"intent_id" => "xi_1"}}}

      # ...and the job advanced to submitted on-chain.
      session = SolverAgent.session(solver, {8453, 70_759})
      assert session.status == :submitted
      assert session.deliverable.intent_id == "xochi-reattach"

      # Only the submit call -- setBudget already happened before the restart, so
      # reattach does NOT re-propose the budget.
      assert [{8453, [call]}] = ProviderAdapter.Mock.sent_calls(ctx.provider)
      assert call.to == @acp_core
    end

    test "a duplicate funded event does not re-settle an already-submitted job", ctx do
      settle_count = :counters.new(1, [])

      settle_stub = fn _ ->
        :counters.add(settle_count, 1, 1)

        {:ok,
         %{
           intent_id: "xochi-dup",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      Transport.Mock.set_history(ctx.transport, {8453, 70_760}, [
        history_created(70_760, @solver_wallet),
        history_requirement(70_760)
      ])

      ProviderAdapter.Mock.set_contract_read(ctx.provider, @acp_core, "getJob(uint256)", 1)

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_760))
      Process.sleep(80)
      assert SolverAgent.session(solver, {8453, 70_760}).status == :submitted

      # A replayed funded event must not spend again.
      Transport.Mock.deliver(ctx.transport, funded(70_760))
      Process.sleep(80)

      assert :counters.get(settle_count, 1) == 1
    end

    test "reattach fails closed when the funded job is not ours (no settle)", ctx do
      settle_stub = fn _ -> flunk("must not settle a job we did not provide") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_761}, [
        history_created(70_761, "0xother0000000000000000000000000000000000"),
        history_requirement(70_761)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_761))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_761}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach fails closed when history has no requirement (no settle)", ctx do
      settle_stub = fn _ -> flunk("must not settle without a recovered requirement") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_762}, [
        history_created(70_762, @solver_wallet)
      ])

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_762))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_762}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach fails closed when the job is not funded on-chain (premature event)", ctx do
      settle_stub = fn _ -> flunk("must not settle a job that is not funded on-chain") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_763}, [
        history_created(70_763, @solver_wallet),
        history_requirement(70_763)
      ])

      # History recoverable + our job, but on-chain the job has NOT been funded
      # (still budget_set, status below funded). The gate must not spend.
      ProviderAdapter.Mock.set_contract_read(ctx.provider, @acp_core, "getJob(uint256)", 0)

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_763))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_763}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach fails closed when the job already advanced past funded on-chain", ctx do
      settle_stub = fn _ -> flunk("must not re-settle a job already past funded") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_764}, [
        history_created(70_764, @solver_wallet),
        history_requirement(70_764)
      ])

      # On-chain status is past funded (e.g. already submitted) -- a stale/replayed
      # funded event must not trigger a second settlement.
      ProviderAdapter.Mock.set_contract_read(ctx.provider, @acp_core, "getJob(uint256)", 2)

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_764))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_764}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach fails closed when the on-chain status is unreadable", ctx do
      settle_stub = fn _ -> flunk("must not settle when the on-chain status can't be read") end

      Transport.Mock.set_history(ctx.transport, {8453, 70_765}, [
        history_created(70_765, @solver_wallet),
        history_requirement(70_765)
      ])

      # No canned getJob read -> the Mock returns {:error, _}; the gate fails closed.
      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_765))
      Process.sleep(80)

      assert SolverAgent.session(solver, {8453, 70_765}) == nil
      assert ProviderAdapter.Mock.sent_calls(ctx.provider) == []
    end

    test "reattach decodes the funded status from a real getJob struct return and settles", ctx do
      test_pid = self()

      settle_stub = fn args ->
        send(test_pid, {:settled, args})

        {:ok,
         %{
           intent_id: "xochi-decode",
           settlement_tx_hash: "0x" <> String.duplicate("a", 64),
           receiving_tx_hash: "0x" <> String.duplicate("b", 64),
           status: "settled"
         }}
      end

      Transport.Mock.set_history(ctx.transport, {8453, 70_766}, [
        history_created(70_766, @solver_wallet),
        history_requirement(70_766)
      ])

      # A real ABI-shaped getJob return: leading offset word, then the struct head
      # [client, status, provider, expiredAt, evaluator, hook, budget]. status
      # (word index 2) = 1 (funded). Proves the word-offset decoder, not just the
      # integer canned-read shortcut.
      ProviderAdapter.Mock.set_contract_read(
        ctx.provider,
        @acp_core,
        "getJob(uint256)",
        getjob_return_hex(1)
      )

      {:ok, solver} = start_solver([settle_fn: settle_stub], ctx)
      Agent.start_stream(ctx.agent)

      Transport.Mock.deliver(ctx.transport, funded(70_766))
      Process.sleep(80)

      assert_received {:settled, %{signed_intent: %{"intent_id" => "xi_1"}}}
      assert SolverAgent.session(solver, {8453, 70_766}).status == :submitted
    end

    # Minimal ABI-encoded getJob(uint256) return: offset word (0x20) + the 7-word
    # struct head, with only `status` (word index 2) set. Enough for the funded gate.
    defp getjob_return_hex(status) do
      words = [0x20, 0, status, 0, 0, 0, 0, 0]

      body =
        words
        |> Enum.map(&<<&1::unsigned-big-integer-size(256)>>)
        |> IO.iodata_to_binary()

      "0x" <> Base.encode16(body, case: :lower)
    end
  end
end
