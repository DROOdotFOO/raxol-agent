defmodule Raxol.Payments.Ramp.OnrampTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.{Checkpoint, Ledger, SpendingPolicy}
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Onramp
  alias Raxol.Payments.Ramps

  defmodule MemoryReader do
    def reconcile(state, _operation), do: {:ok, state}
  end

  defp context do
    vectors =
      File.read!(Path.expand("../../../fixtures/ramp/conformance.json", __DIR__))
      |> Jason.decode!()

    preview_wire =
      Enum.find_value(vectors["wire_cases"], fn v ->
        if v["input"]["kind"] == "preview" and v["valid"], do: v["input"]
      end)

    {:ok, preview} = Ramp.decode(preview_wire)

    %{
      checkpoint: Checkpoint.ETS.new(),
      interaction_ready: true,
      policy: SpendingPolicy.unrestricted(),
      preview: %{preview | leg_order: ["peer"], expires_at: "2099-01-01T00:00:00Z"},
      now: fn -> ~U[2026-11-16 12:00:00Z] end,
      onramp_reader: {MemoryReader, :signaled},
      on_confirm: fn _, _ -> :approve end,
      widget: fn _, _, _ -> :ready end
    }
  end

  defp command(revision \\ "0"),
    do: %{expected_revision: revision, idempotency_key: "test_command_" <> revision}

  test "explicit approval and checkpoint are mandatory" do
    c = context()

    assert {:error, :approval_required} =
             Onramp.approve(
               c.preview.operation_id,
               c.preview.quote_id,
               command(),
               Map.delete(c, :on_confirm)
             )

    assert {:error, :checkpoint_required} =
             Onramp.approve(
               c.preview.operation_id,
               c.preview.quote_id,
               command(),
               Map.delete(c, :checkpoint)
             )
  end

  test "each boundary is checkpointed and the original operation resumes" do
    c = context()
    owner = self()

    c = %{
      c
      | widget: fn stage, op, _ ->
          assert {:ok, %{dispatched: true}} = Checkpoint.fetch(c.checkpoint, "peer_onramp:" <> op)
          send(owner, stage)
          if stage == :onchain_submission, do: :held, else: :ready
        end
    }

    op = c.preview.operation_id
    quote = c.preview.quote_id
    assert {:requires_user, action, snap} = Onramp.approve(op, quote, command(), c)
    assert_received :intent_signaling
    assert {:requires_user, ^action, ^snap} = Onramp.approve(op, quote, command(), c)
    refute_received :intent_signaling

    assert {:error, :session_conflict, ^snap} =
             Onramp.resume(op, "wrong", command(snap.revision), c)

    assert {:requires_user, _, s2} =
             Onramp.resume(op, action.action_ref, command(snap.revision), c)

    assert_received :external_interaction
    assert {:requires_user, _, s3} = Onramp.resume(op, action.action_ref, command(s2.revision), c)
    assert_received :proof_finalization
    assert {:ok, held} = Onramp.resume(op, action.action_ref, command(s3.revision), c)
    assert_received :onchain_submission
    assert held.peer["payout_state"] == "held"
    refute held.terminal
    assert {:ok, ^held} = Onramp.resume(op, action.action_ref, command(held.revision), c)
    refute_received :onchain_submission
  end

  test "unknown outcome remains in doubt and setup uses a bounded error" do
    c = context()
    op = c.preview.operation_id
    quote = c.preview.quote_id

    assert {:ok, snap} =
             Onramp.approve(op, quote, command(), %{
               c
               | widget: fn _, _, _ -> raise "untrusted" end
             })

    assert snap.peer["state"] == "in_doubt"
    assert snap.allowed_actions == ["check_status"]
    c = %{context() | widget: fn _, _, _ -> :setup_required end}
    assert {:error, :setup_required} = Onramp.approve(op, quote, command(), c)
  end

  test "policy caps, expiry and changed quotes deny before widget dispatch" do
    c = %{context() | widget: fn _, _, _ -> flunk("must not dispatch") end}
    op = c.preview.operation_id
    quote = c.preview.quote_id
    denied = %{c | policy: SpendingPolicy.dev()}
    assert {:error, :approval_required} = Onramp.approve(op, quote, command(), denied)
    expired = %{c | preview: %{c.preview | expires_at: "2020-01-01T00:00:00Z"}}
    assert {:error, :approval_required} = Onramp.approve(op, quote, command(), expired)
    assert {:error, :approval_required} = Onramp.approve(op, "quote_changed", command(), c)

    assert {:error, :approval_required} =
             Onramp.approve(op, quote, Map.put(command(), :unexpected, "value"), c)
  end

  test "an already-claimed command cannot prompt or reserve for another operation" do
    c = context()

    assert {:requires_user, _, _} =
             Onramp.approve(c.preview.operation_id, c.preview.quote_id, command(), c)

    changed = %{
      c
      | preview: %{c.preview | operation_id: "op_other"},
        on_confirm: fn _, _ -> flunk("claimed command must not prompt") end
    }

    assert {:error, :session_conflict} =
             Onramp.approve("op_other", changed.preview.quote_id, command(), changed)
  end

  test "expiry during confirmation releases the undispatched reservation" do
    c = context()
    ledger = start_supervised!({Ledger, table_name: :onramp_expiry_test})
    clock = start_supervised!({Agent, fn -> ~U[2026-11-16 12:00:00Z] end})
    preview = %{c.preview | expires_at: "2026-11-16T12:01:00Z"}

    c =
      Map.merge(c, %{
        agent_id: :onramp_expiry,
        ledger: ledger,
        now: fn -> Agent.get(clock, & &1) end,
        preview: preview,
        on_confirm: fn _, _ ->
          Agent.update(clock, fn _ -> ~U[2026-11-16 12:01:00Z] end)
          :approve
        end,
        widget: fn _, _, _ -> flunk("expired quote must not dispatch") end
      })

    assert {:error, :approval_required} =
             Onramp.approve(preview.operation_id, preview.quote_id, command(), c)

    assert :error = Checkpoint.fetch(c.checkpoint, "peer_onramp:" <> preview.operation_id)
    assert %{lifetime: total} = Ledger.get_totals(ledger, c.agent_id, c.policy)
    assert Decimal.equal?(total, 0)
  end

  test "widget release requires authoritative reconciliation for a terminal snapshot" do
    c = %{
      context()
      | widget: fn stage, _, _ -> if stage == :onchain_submission, do: :released, else: :ready end
    }

    op = c.preview.operation_id
    assert {:requires_user, action, s1} = Onramp.approve(op, c.preview.quote_id, command(), c)
    assert {:requires_user, _, s2} = Onramp.resume(op, action.action_ref, command(s1.revision), c)
    assert {:requires_user, _, s3} = Onramp.resume(op, action.action_ref, command(s2.revision), c)
    assert {:ok, done} = Onramp.resume(op, action.action_ref, command(s3.revision), c)
    refute done.terminal
    assert done.allowed_actions == ["check_status"]

    assert {:ok, terminal} =
             Onramp.status(op, Map.put(c, :onramp_reader, {__MODULE__.MemoryReader, :completed}))

    assert terminal.terminal
    assert terminal.allowed_actions == []

    assert {:ok, %{closed: true, receipt: receipt}} =
             Checkpoint.fetch(c.checkpoint, "peer_onramp:" <> op)

    assert receipt.state == "completed"
    assert done.peer["payout_state"] == "released"
    for snapshot <- [s1, s2, s3, done], do: assert({:ok, _} = Ramp.decode(Ramp.to_wire(snapshot)))
  end

  test "concurrent approvals dispatch only once" do
    c = context()
    owner = self()

    c = %{
      c
      | widget: fn stage, _, _ ->
          send(owner, stage)
          :ready
        end
    }

    results =
      1..4
      |> Task.async_stream(fn _ ->
        Onramp.approve(c.preview.operation_id, c.preview.quote_id, command(), c)
      end)
      |> Enum.map(fn {:ok, result} -> result end)

    assert length(Enum.uniq(results)) == 1
    assert_received :intent_signaling
    refute_received :intent_signaling
  end

  test "an older checkpoint without a verified signal cannot start a later stage" do
    c = context()
    op = c.preview.operation_id

    assert {:requires_user, action, snapshot} =
             Onramp.approve(op, c.preview.quote_id, command(), c)

    key = "peer_onramp:" <> op
    assert {:ok, record} = Checkpoint.fetch(c.checkpoint, key)
    assert :ok = Checkpoint.put(c.checkpoint, key, Map.delete(record, :signal_verified))
    c = %{c | widget: fn _, _, _ -> flunk("unverified signal must not dispatch") end}

    assert {:ok, doubt} =
             Onramp.resume(op, action.action_ref, command(snapshot.revision), c)

    assert doubt.peer["state"] == "in_doubt"
    assert doubt.allowed_actions == ["check_status"]
  end

  test "public facade runs and resumes the approved operation" do
    c = context()
    op = c.preview.operation_id
    approval = %{quote_id: c.preview.quote_id, command: command()}
    assert {:requires_user, action, snap} = Ramps.run(op, approval, c)
    c = Map.merge(c, %{action_ref: action.action_ref, command: command(snap.revision)})
    assert {:requires_user, _, resumed} = Ramps.resume(op, c)
    assert resumed.operation_id == op
    assert String.to_integer(resumed.revision) > String.to_integer(snap.revision)
  end

  test "killed submission resumes by status without another widget dispatch" do
    c = context()
    owner = self()

    c = %{
      c
      | widget: fn stage, _, _ ->
          if stage == :onchain_submission do
            send(owner, {:dispatched, stage})

            receive do
              :unblock -> :ready
            end
          else
            :ready
          end
        end
    }

    op = c.preview.operation_id
    assert {:requires_user, action, s1} = Onramp.approve(op, c.preview.quote_id, command(), c)
    assert {:requires_user, _, s2} = Onramp.resume(op, action.action_ref, command(s1.revision), c)
    assert {:requires_user, _, s3} = Onramp.resume(op, action.action_ref, command(s2.revision), c)
    pid = spawn(fn -> Onramp.resume(op, action.action_ref, command(s3.revision), c) end)
    monitor = Process.monitor(pid)
    assert_receive {:dispatched, :onchain_submission}
    Process.exit(pid, :kill)
    assert_receive {:DOWN, ^monitor, :process, ^pid, :killed}
    assert {:ok, record} = Checkpoint.fetch(c.checkpoint, "peer_onramp:" <> op)
    snap = record.snapshot
    assert snap.peer["state"] == "in_doubt"
    assert {:ok, ^snap} = Onramp.resume(op, record.action_ref, command(snap.revision), c)
    assert {:ok, ^snap} = Onramp.approve(op, c.preview.quote_id, command(), c)
    assert {:ok, done} = Ramps.status(op, Map.put(c, :onramp_reader, {MemoryReader, :completed}))
    assert done.terminal
    refute_received {:dispatched, _}
    assert {:ok, ^done} = Ramps.status(op, c)

    assert {:ok, %{closed: true, receipt: receipt}} =
             Checkpoint.fetch(c.checkpoint, "peer_onramp:" <> op)

    assert Enum.sort(Map.keys(receipt)) == [
             :direction,
             :operation_id,
             :revision,
             :state,
             :updated_at
           ]
  end

  test "conflicts return the latest sanitized snapshot and cannot create another operation" do
    c = context()
    op = c.preview.operation_id
    assert {:requires_user, action, latest} = Onramp.approve(op, c.preview.quote_id, command(), c)

    assert {:error, :session_conflict, ^latest} =
             Onramp.resume(op, action.action_ref, command(), c)

    assert {:error, :session_conflict, ^latest} =
             Onramp.approve(op, c.preview.quote_id, %{command() | idempotency_key: "changed"}, c)

    other = %{c | preview: %{c.preview | operation_id: "op_other"}}

    assert {:error, :session_conflict} =
             Onramp.approve("op_other", c.preview.quote_id, command(), other)

    assert :error = Checkpoint.fetch(c.checkpoint, "peer_onramp:op_other")
    assert {:ok, _} = Ramp.encode(latest)
  end
end
