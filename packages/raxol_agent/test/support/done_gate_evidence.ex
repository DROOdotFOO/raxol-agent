defmodule Raxol.Agent.Test.DoneGateEvidence do
  @moduledoc """
  Test support for the `Raxol.Agent.DoneGate` suites: a journal builder
  (`Build`), a specification oracle that never calls `DoneGate` (`Oracle`),
  broken gate implementations (`Injector`), fixed cases (`Contours`), a
  seeded journal generator (`Gen`) and fired counters (`Fired`).
  """
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Build do
  @moduledoc false
  alias Raxol.Agent.Contract.Event

  @session "sess-done-gate"

  @doc "A durable loop `%Event{}` at offset `id` (offset == journal id)."
  def ev(id, type, payload, opts \\ []) do
    %Event{
      v: 0,
      id: id,
      session_id: @session,
      turn_id: Keyword.get(opts, :turn_id, "t"),
      ts: id,
      family: Keyword.get(opts, :family, :loop),
      type: type,
      tier: :durable,
      payload: payload
    }
  end

  def turn_started(id, opts \\ []),
    do: ev(id, :turn_started, %{prompt: "do the thing"}, opts)

  @doc "A mutating action (write/shell tool_use) — the thing evidence must postdate."
  def mutation(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_use,
        mutating: true,
        name: Keyword.get(opts, :name, "fs_write"),
        effect_class: :reversible_local
      },
      opts
    )
  end

  @doc """
  A read-intended tool_use stamped `mutating: false`. It still counts as a
  mutation: the stamp is a self-report, which the gate must ignore.
  """
  def read_action(id, opts \\ []),
    do:
      ev(
        id,
        :item_completed,
        %{item_type: :tool_use, mutating: false, name: "fs_read"},
        opts
      )

  @doc """
  A tool_use in the REAL producer's shape (`StreamPump.pump/3`): no
  `effect_class`, no `mutating` flag — exactly the payload the fail-safe
  mutation default exists for.
  """
  def tool_call(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_use,
        name: Keyword.get(opts, :name, "fs_write"),
        arguments: %{},
        call_id: "call-#{id}"
      },
      opts
    )
  end

  @doc """
  Evidence: a tool result / verification output (test run, file check).

  Default `name: "shell"` deliberately pairs with NO preceding tool_use in
  any contour journal, so the result reads as an independent verification
  output rather than some call's echo (echo pairing is by name +
  nearest-preceding order — see the mutation-echo contour for the paired
  case).
  """
  def evidence(id, opts \\ []) do
    ev(
      id,
      :item_completed,
      %{
        item_type: :tool_result,
        name: Keyword.get(opts, :name, "shell"),
        result: Keyword.get(opts, :result, "tests: 12 passed, 0 failed")
      },
      opts
    )
  end

  @doc "The agent's own say-so — a `:message` item. NOT evidence-class."
  def self_report(id, opts \\ []),
    do:
      ev(
        id,
        :item_completed,
        %{item_type: :message, content: "All done — everything works."},
        opts
      )

  @doc "An internal state transition. NOT evidence-class."
  def state_change(id, opts \\ []),
    do: ev(id, :state_change, %{from: :a, to: :b}, opts)

  @doc "Resolve a journal offset to its event, or nil."
  def resolve(journal, offset), do: Enum.find(journal, &(&1.id == offset))
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Oracle do
  @moduledoc false
  alias Raxol.Agent.Test.DoneGateEvidence.Build

  @doc "Evidence-class predicate: a tool result / verification output."
  def evidence_class?(%{type: :item_completed, payload: p}),
    do: Map.get(p, :item_type) == :tool_result

  def evidence_class?(_), do: false

  @doc """
  Every completed `:tool_use` is a mutation: producers stamp no effect
  metadata, and a self-reported `mutating:` flag never removes a call.
  """
  def mutating?(%{type: :item_completed, payload: p}),
    do: Map.get(p, :item_type) == :tool_use

  def mutating?(_), do: false

  @doc "Offset of the turn's last mutating action, or nil if the turn mutated nothing."
  def last_mutation(journal, turn_id) do
    journal
    |> Enum.filter(&(&1.turn_id == turn_id and mutating?(&1)))
    |> Enum.map(& &1.id)
    |> case do
      [] -> nil
      ids -> Enum.max(ids)
    end
  end

  @doc """
  The verdict a correct `DoneGate` must return. Each ref is checked for
  existence, class, same turn and ordering, in `refs` order, and the first
  violation wins. `Contours.shape/1` compares the whole reason, offset
  included, so which of several bad refs is reported is part of the
  contract.
  """
  def verdict(_journal, _turn_id, []), do: {:error, :evidence_required}

  def verdict(journal, turn_id, refs) do
    last_mut = last_mutation(journal, turn_id)

    Enum.reduce_while(refs, {:ok, refs}, fn ref, acc ->
      case classify_ref(journal, turn_id, last_mut, ref) do
        :ok -> {:cont, acc}
        err -> {:halt, err}
      end
    end)
  end

  @doc """
  Classify one ref against the claiming turn. Same-turn is checked before
  ordering, so a foreign turn's result with a later offset is
  `:foreign_turn`, not accepted.
  """
  def classify_ref(journal, turn_id, last_mut, ref) do
    case Build.resolve(journal, ref) do
      nil ->
        {:error, {:missing_ref, ref}}

      ev ->
        cond do
          not evidence_class?(ev) ->
            {:error, {:not_evidence, ref}}

          ev.turn_id != turn_id ->
            {:error, {:foreign_turn, ref}}

          true ->
            classify_order(journal, turn_id, last_mut, ev)
        end
    end
  end

  defp classify_order(journal, turn_id, last_mut, ev) do
    cond do
      last_mut != nil and ev.id <= last_mut ->
        {:error, {:stale_evidence, ev.id}}

      mutation_echo?(journal, turn_id, ev, last_mut) ->
        {:error, {:mutation_echo, ev.id}}

      ran_before_mutation?(journal, turn_id, ev, last_mut) ->
        {:error, {:stale_evidence, ev.id}}

      true ->
        :ok
    end
  end

  @doc """
  True when `ev` precedes the last mutation's own result: in a batched
  round every tool_use is journaled before any result, so such a result
  came from a call that ran before the mutation.
  """
  def ran_before_mutation?(_journal, _turn_id, _ev, nil), do: false

  def ran_before_mutation?(journal, turn_id, ev, last_mut) do
    journal
    |> Enum.find(fn res ->
      res.turn_id == turn_id and evidence_class?(res) and res.id > last_mut and
        mutation_echo?(journal, turn_id, res, last_mut)
    end)
    |> case do
      nil -> false
      result -> ev.id < result.id
    end
  end

  @doc """
  A `:tool_result` produced by the turn's last mutating call is that call's
  echo and verifies nothing. A result with a `call_id` pairs with the
  tool_use of that id; otherwise by tool name and nearest preceding order
  within the turn. An unpaired result is no echo.
  """
  def mutation_echo?(_journal, _turn_id, _ev, nil), do: false

  def mutation_echo?(journal, _turn_id, %{payload: %{call_id: id}}, last_mut)
      when is_binary(id) do
    case Build.resolve(journal, last_mut) do
      %{payload: %{call_id: ^id}} -> true
      _ -> false
    end
  end

  def mutation_echo?(journal, turn_id, ev, last_mut) do
    name = ev.payload[:name]

    producing_calls =
      journal
      |> Enum.filter(fn cand ->
        cand.turn_id == turn_id and mutating?(cand) and cand.id < ev.id and
          name != nil and cand.payload[:name] == name
      end)
      |> Enum.map(& &1.id)

    producing_calls != [] and Enum.max(producing_calls) == last_mut
  end
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Injector do
  @moduledoc false

  # Injectors put their fake done at offset 9_999, past any contour or
  # generated journal.

  # A correct implementation, so every contour is satisfiable. It wraps
  # `Oracle.verdict/3`; the independent checks are the hand-written
  # `Contours` expectations and the injectors below.
  defmodule Reference do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Test.DoneGateEvidence.{Build, Oracle}

    @impl true
    def gate(journal, turn_id, refs) do
      case Oracle.verdict(journal, turn_id, refs) do
        {:ok, _} ->
          {:ok,
           Build.ev(
             9_999,
             :turn_completed,
             %{final: true, refs: refs, usage: %{}},
             turn_id: turn_id
           )}

        err ->
          err
      end
    end
  end

  # Accepts a done without checking refs.
  defmodule AcceptsWithoutRefs do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Test.DoneGateEvidence.Build

    @impl true
    def gate(_journal, turn_id, refs),
      do: {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)}
  end

  # Checks existence and class but not ordering.
  defmodule ExistenceOnly do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Test.DoneGateEvidence.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              if Oracle.evidence_class?(ev),
                do: {:cont, acc},
                else: {:halt, {:error, {:not_evidence, ref}}}
          end
        end
      )
    end
  end

  # Counts a `:message` self-report as evidence.
  defmodule TextAsEvidence do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Test.DoneGateEvidence.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      last_mut = Oracle.last_mutation(journal, turn_id)

      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              cond do
                not lenient_evidence?(ev) ->
                  {:halt, {:error, {:not_evidence, ref}}}

                last_mut != nil and ev.id <= last_mut ->
                  {:halt, {:error, {:stale_evidence, ref}}}

                true ->
                  {:cont, acc}
              end
          end
        end
      )
    end

    # The bug: a `:message` self-report is treated as evidence.
    defp lenient_evidence?(%{type: :item_completed, payload: p}),
      do: Map.get(p, :item_type) in [:tool_result, :message]

    defp lenient_evidence?(_), do: false
  end

  # Checks existence, class and ordering, but not that the cited ref belongs
  # to the claiming turn.
  defmodule SkipsTurnCheck do
    @moduledoc false
    @behaviour Raxol.Agent.DoneGate
    alias Raxol.Agent.Test.DoneGateEvidence.{Build, Oracle}

    @impl true
    def gate(_journal, _turn_id, []), do: {:error, :evidence_required}

    def gate(journal, turn_id, refs) do
      last_mut = Oracle.last_mutation(journal, turn_id)

      Enum.reduce_while(
        refs,
        {:ok, Build.ev(9_999, :turn_completed, %{final: true, refs: refs}, turn_id: turn_id)},
        fn ref, acc ->
          case Build.resolve(journal, ref) do
            nil ->
              {:halt, {:error, {:missing_ref, ref}}}

            ev ->
              cond do
                not Oracle.evidence_class?(ev) ->
                  {:halt, {:error, {:not_evidence, ref}}}

                last_mut != nil and ev.id <= last_mut ->
                  {:halt, {:error, {:stale_evidence, ref}}}

                true ->
                  {:cont, acc}
              end
          end
        end
      )
    end
  end
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Contours do
  @moduledoc false
  alias Raxol.Agent.Test.DoneGateEvidence.Build

  @doc """
  `{name, journal, turn_id, refs, expected_shape}`. Each is a hand-built,
  minimal journal exercising exactly one branch of the acceptance contract.
  """
  def contours do
    t = "t"

    [
      # done with valid postdating evidence -> accepted
      {:valid, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [3], :accept},
      # done with NO refs -> evidence_required, no done event
      {:evidence_required, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [],
       {:reject, :evidence_required}},
      # evidence PREDATES a later mutation -> stale
      {:stale, [Build.turn_started(1), Build.evidence(2), Build.mutation(3)], t, [2],
       {:reject, {:stale_evidence, 2}}},
      # ref points at an internal state_change -> not evidence-class
      {:not_evidence_state_change,
       [Build.turn_started(1), Build.mutation(2), Build.state_change(3)], t, [3],
       {:reject, {:not_evidence, 3}}},
      # ref points at the agent's own message text -> not evidence-class
      {:not_evidence_self_report,
       [Build.turn_started(1), Build.mutation(2), Build.self_report(3)], t, [3],
       {:reject, {:not_evidence, 3}}},
      # ref names an offset that does not exist
      {:missing_ref, [Build.turn_started(1), Build.mutation(2), Build.evidence(3)], t, [99],
       {:reject, {:missing_ref, 99}}},
      # Cross-turn spoof: another turn's result at offset 4 postdates turn
      # "t"'s last mutation (2), but belongs to the other turn.
      {:foreign_turn,
       [
         Build.turn_started(1, turn_id: t),
         Build.mutation(2, turn_id: t),
         Build.turn_started(3, turn_id: "other"),
         Build.evidence(4, turn_id: "other")
       ], t, [4], {:reject, {:foreign_turn, 4}}},
      # Class is checked, not content: a verification tool that reported
      # failure still counts.
      {:evidence_content_not_validated,
       [
         Build.turn_started(1),
         Build.mutation(2),
         Build.evidence(3, result: "tests: 0 passed, 12 FAILED")
       ], t, [3], :accept},
      # A later tool_use stamped `mutating: false` still gates: the stamp is
      # a self-report, so the evidence at 3 is stale.
      {:tool_use_after_evidence_gates,
       [
         Build.turn_started(1),
         Build.mutation(2),
         Build.evidence(3),
         Build.read_action(4)
       ], t, [3], {:reject, {:stale_evidence, 3}}},
      # Mutation echo: the result at 3 is the last mutation's own output
      # (same name, nearest preceding), so it verifies nothing.
      {:mutation_echo,
       [
         Build.turn_started(1),
         Build.tool_call(2, name: "fs_write"),
         Build.evidence(3, name: "fs_write", result: "wrote 42 bytes")
       ], t, [3], {:reject, {:mutation_echo, 3}}}
    ]
  end

  def by_name(name),
    do: Enum.find(contours(), fn {n, _, _, _, _} -> n == name end)

  @doc "Collapse a verdict to its accept/reject shape for equality across impls."
  def shape({:ok, _}), do: :accept
  def shape({:error, reason}), do: {:reject, reason}

  @doc "Collapse a verdict to its outcome CLASS (for generator-coverage assertions)."
  def outcome_class({:ok, _}), do: :accept
  def outcome_class({:error, :evidence_required}), do: :evidence_required
  def outcome_class({:error, {:stale_evidence, _}}), do: :stale_evidence
  def outcome_class({:error, {:not_evidence, _}}), do: :not_evidence
  def outcome_class({:error, {:missing_ref, _}}), do: :missing_ref
  def outcome_class({:error, {:foreign_turn, _}}), do: :foreign_turn
  def outcome_class({:error, {:mutation_echo, _}}), do: :mutation_echo
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Gen do
  @moduledoc false
  alias Raxol.Agent.Test.DoneGateEvidence.Build

  # `sample/1` is deterministic and diverse: each index gets its own seed
  # (`@seed + index`) through `StreamData.__call__/3`. Enumerating a
  # generator reseeds from the clock, and one shared seed collapses every
  # sample onto one branch.
  @seed 0x51212026

  def steps_gen do
    StreamData.list_of(
      StreamData.member_of([
        :mutation,
        :read,
        :evidence,
        :self_report,
        :state_change,
        :foreign_evidence
      ]),
      min_length: 1,
      max_length: 7
    )
  end

  @doc "Generates `{journal, turn_id, refs}` triples over the contract vocabulary."
  def journal_and_refs_gen do
    StreamData.bind(steps_gen(), fn steps ->
      journal = build_journal(steps)
      offsets = Enum.map(journal, & &1.id)
      # 999 is guaranteed absent -> exercises the missing-ref branch.
      candidates = offsets ++ [999]

      # Own-turn evidence (maybe stale) and another turn's evidence, which a
      # gate that skips the ownership check would accept.
      own_evidence_offsets =
        journal
        |> Enum.filter(&(&1.payload[:item_type] == :tool_result and &1.turn_id == "t"))
        |> Enum.map(& &1.id)

      foreign_evidence_offsets =
        journal
        |> Enum.filter(&(&1.payload[:item_type] == :tool_result and &1.turn_id != "t"))
        |> Enum.map(& &1.id)

      refs_gen =
        StreamData.one_of([
          StreamData.constant([]),
          StreamData.list_of(StreamData.member_of(candidates), max_length: 4),
          # Cite all own-turn evidence: reliably surfaces stale evidence.
          StreamData.constant(own_evidence_offsets),
          # Cite all foreign evidence: reliably surfaces the cross-turn spoof.
          StreamData.constant(foreign_evidence_offsets)
        ])

      StreamData.bind(refs_gen, fn refs ->
        StreamData.constant({journal, "t", refs})
      end)
    end)
  end

  @doc """
  Deterministic, diverse sample of `n` triples: each index has its own
  seed (`@seed + index`).
  """
  def sample(n) do
    gen = journal_and_refs_gen()

    for i <- 0..(n - 1) do
      seed = :rand.seed_s(:exsss, {0, 0, @seed + i})
      # `StreamData.__call__/3` returns a `%StreamData.LazyTree{}`; only the
      # root value is wanted.
      %StreamData.LazyTree{root: value} = StreamData.__call__(gen, seed, 50)
      value
    end
  end

  defp build_journal(steps) do
    first = Build.turn_started(1, turn_id: "t")

    rest =
      steps
      |> Enum.with_index(2)
      |> Enum.map(fn {step, off} -> build_step(step, off) end)

    [first | rest]
  end

  defp build_step(:mutation, off), do: Build.mutation(off, turn_id: "t")
  defp build_step(:read, off), do: Build.read_action(off, turn_id: "t")
  defp build_step(:evidence, off), do: Build.evidence(off, turn_id: "t")
  defp build_step(:self_report, off), do: Build.self_report(off, turn_id: "t")
  # Evidence journaled under another turn in the same session journal.
  defp build_step(:foreign_evidence, off),
    do: Build.evidence(off, turn_id: "other")

  defp build_step(:state_change, off), do: Build.state_change(off)
end

defmodule Raxol.Agent.Test.DoneGateEvidence.Fired do
  @moduledoc false

  def new do
    {:ok, pid} = Agent.start_link(fn -> %{armed: MapSet.new(), fired: %{}} end)
    pid
  end

  def arm(pid, site) do
    Agent.update(pid, fn s -> %{s | armed: MapSet.put(s.armed, site)} end)
    pid
  end

  def fire(pid, site),
    do:
      Agent.update(pid, fn s ->
        %{s | fired: Map.update(s.fired, site, 1, &(&1 + 1))}
      end)

  def assert_all_fired!(pid) do
    %{armed: armed, fired: fired} = Agent.get(pid, & &1)
    dead = Enum.filter(armed, &(Map.get(fired, &1, 0) == 0))

    if dead != [] do
      raise ExUnit.AssertionError,
        message:
          "dead injector(s): armed site(s) never fired: #{inspect(dead)}; fired: #{inspect(fired)}"
    end

    fired
  end
end
