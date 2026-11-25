defmodule Raxol.Agent.DoneGate.ControlsTest do
  @moduledoc """
  Negative controls for `Raxol.Agent.DoneGate.EvidenceTest`: a correct
  reference passes every contour, each injector fails its targeted contour,
  and the generator reaches every outcome class.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.Test.DoneGateEvidence.{Build, Contours, Fired, Gen, Injector, Oracle}

  # Through apply/3, so the return type stays dynamic.
  defp real_gate(journal, turn, refs),
    do: apply(DoneGate, :gate, [journal, turn, refs])

  describe "contours" do
    test "a correct reference implementation satisfies every contour" do
      for {name, journal, turn, refs, expected} <- Contours.contours() do
        assert Contours.shape(Injector.Reference.gate(journal, turn, refs)) ==
                 expected,
               "reference failed the #{name} contour"
      end
    end
  end

  describe "injectors" do
    test "each injector fails its targeted contour, and every armed site fires" do
      fired = Fired.new()

      for site <- [
            :accepts_without_refs,
            :existence_only,
            :text_as_evidence,
            :skips_turn_check
          ],
          do: Fired.arm(fired, site)

      # Accepts without refs: fails the evidence-required contour.
      {_, j_a, t_a, r_a, exp_a} = Contours.by_name(:evidence_required)

      refute Contours.shape(Injector.AcceptsWithoutRefs.gate(j_a, t_a, r_a)) ==
               exp_a,
             "AcceptsWithoutRefs should not satisfy the evidence-required contour"

      Fired.fire(fired, :accepts_without_refs)

      # Existence only: fails the stale-evidence contour.
      {_, j_b, t_b, r_b, exp_b} = Contours.by_name(:stale)

      refute Contours.shape(Injector.ExistenceOnly.gate(j_b, t_b, r_b)) == exp_b,
             "ExistenceOnly should not satisfy the stale-evidence contour"

      Fired.fire(fired, :existence_only)

      # Text as evidence: fails the evidence-class contour.
      {_, j_c, t_c, r_c, exp_c} = Contours.by_name(:not_evidence_self_report)

      refute Contours.shape(Injector.TextAsEvidence.gate(j_c, t_c, r_c)) ==
               exp_c,
             "TextAsEvidence should not satisfy the evidence-class contour"

      Fired.fire(fired, :text_as_evidence)

      # Skips the turn check: fails the foreign-turn contour.
      {_, j_d, t_d, r_d, exp_d} = Contours.by_name(:foreign_turn)

      refute Contours.shape(Injector.SkipsTurnCheck.gate(j_d, t_d, r_d)) ==
               exp_d,
             "SkipsTurnCheck should not satisfy the foreign-turn contour"

      Fired.fire(fired, :skips_turn_check)

      Fired.assert_all_fired!(fired)
    end

    test "the fold property is non-vacuous: each dead injector disagrees with the spec on >= 1 generated journal" do
      for {name, mod} <- [
            {:accepts_without_refs, Injector.AcceptsWithoutRefs},
            {:existence_only, Injector.ExistenceOnly},
            {:text_as_evidence, Injector.TextAsEvidence},
            {:skips_turn_check, Injector.SkipsTurnCheck}
          ] do
        disagreements =
          Gen.sample(300)
          |> Enum.count(fn {j, t, r} ->
            Contours.shape(mod.gate(j, t, r)) !=
              Contours.shape(Oracle.verdict(j, t, r))
          end)

        assert disagreements > 0, "the fold property would never catch #{name}"
      end
    end
  end

  describe "generator coverage" do
    test "the generator exercises every outcome class, INCLUDING cited stale AND foreign-turn evidence" do
      # `Gen.sample/1` is seed-fixed, so a missing class fails every run.
      classes =
        Gen.sample(400)
        |> Enum.map(fn {j, t, r} ->
          Contours.outcome_class(Oracle.verdict(j, t, r))
        end)
        |> Enum.frequencies()

      assert Map.get(classes, :accept, 0) > 0,
             "no accept case generated (#{inspect(classes)})"

      assert Map.get(classes, :evidence_required, 0) > 0,
             "no evidence-required case (#{inspect(classes)})"

      assert Map.get(classes, :stale_evidence, 0) > 0,
             "generator never cited stale evidence — the stale-evidence check is vacuous (#{inspect(classes)})"

      assert Map.get(classes, :not_evidence, 0) > 0,
             "no not-evidence case (#{inspect(classes)})"

      assert Map.get(classes, :missing_ref, 0) > 0,
             "no missing-ref case (#{inspect(classes)})"

      assert Map.get(classes, :foreign_turn, 0) > 0,
             "generator never cited foreign-turn evidence — the cross-turn check is vacuous (#{inspect(classes)})"
    end
  end

  # The fold property compares the gate with `Oracle.verdict/3`, which
  # reimplements the same predicates, so a consistent change to the mutation
  # boundary would move both. These verdicts are written by hand.
  describe "mutation boundary" do
    test "an effect-bearing tool_use with `mutating: false` counts as a mutation" do
      # Evidence at 2, then a tool_use at 3 stamped `mutating: false`.
      effect_bearing_write =
        Build.ev(
          3,
          :item_completed,
          %{
            item_type: :tool_use,
            mutating: false,
            effect_class: :reversible_local
          },
          turn_id: "t"
        )

      journal = [Build.turn_started(1), Build.evidence(2), effect_bearing_write]

      assert real_gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "a bare tool_use (no effect_class, no flag — the REAL producer shape) IS a mutation" do
      # The real producer's tool_use carries neither effect_class nor a
      # mutating flag; the call at 3 still makes the evidence at 2 stale.
      journal = [
        Build.turn_started(1),
        Build.evidence(2),
        Build.tool_call(3, name: "fs_write")
      ]

      assert real_gate(journal, "t", [2]) == {:error, {:stale_evidence, 2}}
    end

    test "a read-INTENDED tool_use self-reporting `mutating: false` still gates later evidence" do
      # Mutation at 2, evidence at 3, then a tool_use at 4 stamped
      # `mutating: false`: the stamp is ignored, so 3 is stale.
      journal = [
        Build.turn_started(1),
        Build.mutation(2),
        Build.evidence(3),
        Build.read_action(4)
      ]

      assert real_gate(journal, "t", [3]) == {:error, {:stale_evidence, 3}}
    end

    test "the last mutation's own result echo is not evidence (mutation_echo)" do
      # A call's result always postdates it and class-passes, so the last
      # mutation's echo must not count.
      journal = [
        Build.turn_started(1),
        Build.tool_call(2, name: "fs_write"),
        Build.evidence(3, name: "fs_write", result: "wrote 42 bytes")
      ]

      assert real_gate(journal, "t", [3]) == {:error, {:mutation_echo, 3}}
    end
  end
end
