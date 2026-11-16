defmodule Raxol.Payments.Ramp.OnrampTest do
  use ExUnit.Case, async: true
  alias Raxol.Payments.{Checkpoint, SpendingPolicy}
  alias Raxol.Payments.Ramp
  alias Raxol.Payments.Ramp.Onramp
  alias Raxol.Payments.Ramps

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
      on_confirm: fn _, _ -> :approve end,
      widget: fn _, _, _ -> :ready end
    }
  end

  defp command(revision \\ "0"),
    do: %{expected_revision: revision, idempotency_key: "test_command"}

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
    assert {:error, :session_conflict} = Onramp.resume(op, "wrong", command(snap.revision), c)

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

  test "released payout alone produces a valid terminal snapshot" do
    c = %{
      context()
      | widget: fn stage, _, _ -> if stage == :onchain_submission, do: :released, else: :ready end
    }

    op = c.preview.operation_id
    assert {:requires_user, action, s1} = Onramp.approve(op, c.preview.quote_id, command(), c)
    assert {:requires_user, _, s2} = Onramp.resume(op, action.action_ref, command(s1.revision), c)
    assert {:requires_user, _, s3} = Onramp.resume(op, action.action_ref, command(s2.revision), c)
    assert {:ok, done} = Onramp.resume(op, action.action_ref, command(s3.revision), c)
    assert done.terminal
    assert done.allowed_actions == []
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
end
