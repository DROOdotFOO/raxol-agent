defmodule Raxol.Agent.DoneGate.EvidenceTest do
  @moduledoc """
  `Raxol.Agent.DoneGate.gate/3` against fixed contours from
  `Raxol.Agent.Test.DoneGateEvidence.Contours` and a generated fold property.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.Test.DoneGateEvidence.{Build, Contours, Gen, Oracle}

  # Through apply/3, so the return type stays dynamic and `{:ok, _}`
  # matches are not flagged as dead clauses.
  defp gate(journal, turn, refs),
    do: apply(DoneGate, :gate, [journal, turn, refs])

  describe "accepted claims" do
    # Every accept-shaped contour gets the same assertions.
    for name <- [:valid, :evidence_content_not_validated] do
      test "accept: #{name} — the gate hands back a turn_completed{final: true} carrying its evidence refs" do
        {_, journal, turn, refs, _} = Contours.by_name(unquote(name))

        assert {:ok, done} = gate(journal, turn, refs)
        assert done.type == :turn_completed
        assert done.payload.final == true
        assert done.payload.refs == refs
        assert done.turn_id == turn
      end
    end
  end

  describe "rejected claims" do
    # Selected by expected shape, so new reject contours are included.
    for {name, _j, _t, _r, expected} <- Contours.contours(),
        match?({:reject, _}, expected) do
      test "reject: #{name} -> #{inspect(expected)}; no turn_completed{final: true} is produced" do
        {_, journal, turn, refs, _expected} = Contours.by_name(unquote(name))

        verdict = gate(journal, turn, refs)
        assert Contours.shape(verdict) == unquote(Macro.escape(expected))
      end
    end
  end

  describe "fold property" do
    property "gate agrees with the evidence spec on every generated journal" do
      # The generator MUST include the stale-evidence ordering, or the property
      # is vacuous; the ControlsTest coverage guard enforces that separately.
      check all(
              {journal, turn, refs} <- Gen.journal_and_refs_gen(),
              max_runs: 200
            ) do
        assert Contours.shape(gate(journal, turn, refs)) ==
                 Contours.shape(Oracle.verdict(journal, turn, refs))
      end
    end
  end

  describe "a nil claiming turn" do
    test "a nil-turn done citing nil-turn evidence is rejected (nil==nil must not satisfy same-turn)" do
      # Evidence and done both under a nil turn: `nil == nil` must not pass
      # the same-turn check.
      journal = [
        Build.turn_started(1, turn_id: nil),
        Build.mutation(2, turn_id: nil),
        Build.evidence(3, turn_id: nil)
      ]

      assert gate(journal, nil, [3]) == {:error, :unturned_done}
    end

    test "a nil-turn done is :unturned_done even with no refs (checked before evidence)" do
      assert gate([Build.turn_started(1, turn_id: nil)], nil, []) ==
               {:error, :unturned_done}
    end
  end

  describe "mutation is derived from type, never from stamped flags" do
    test "an effect-bearing tool_use with `mutating: false` still counts as a mutation" do
      # Stamped `mutating: false`, the call at 3 still gates, so the evidence
      # at 2 is stale.
      spoofed_mutation =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            mutating: false,
            effect_class: :reversible_local,
            name: "fs_write"
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), spoofed_mutation]

      assert gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "an effect-bearing tool_use with NO `mutating` flag at all still counts as a mutation" do
      unflagged_mutation =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            effect_class: :reversible_local,
            name: "fs_write"
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), unflagged_mutation]

      assert gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end
  end

  describe "JSON-replayed (string-keyed) journals" do
    test "every contour gates identically whether atom-keyed or JSON-replayed (string-keyed)" do
      # `FileStore.Reader` replays string-keyed maps with string enum values;
      # the verdict must not change.
      for {name, journal, turn, refs, _expected} <- Contours.contours() do
        replayed =
          Enum.map(journal, fn e -> e |> Jason.encode!() |> Jason.decode!() end)

        assert Contours.shape(gate(replayed, turn, refs)) ==
                 Contours.shape(gate(journal, turn, refs)),
               "string-keyed journal diverged from atom-keyed on the #{name} contour"
      end
    end
  end

  describe "the done's session_id" do
    test "an accepted done carries the claiming turn's session, not List.first's" do
      # The journal head is another turn in another session; the Writer does
      # not re-stamp session_id, so the done must carry the claiming turn's.
      head = %{
        Build.turn_started(1, turn_id: "other")
        | session_id: "sess-OTHER"
      }

      journal = [
        head,
        Build.turn_started(2, turn_id: "t"),
        Build.mutation(3, turn_id: "t"),
        Build.evidence(4, turn_id: "t")
      ]

      assert {:ok, done} = gate(journal, "t", [4])
      assert done.session_id == "sess-done-gate"
      refute done.session_id == "sess-OTHER"
    end
  end
end
