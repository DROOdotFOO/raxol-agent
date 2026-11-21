defmodule Raxol.Agent.StreamPumpTest do
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract
  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.StreamPump

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  defp mock_stream(response) do
    Raxol.Agent.Stream.run("prompt",
      backend: Raxol.Agent.Backend.Mock,
      backend_opts: [response: response]
    )
  end

  describe "pump/3" do
    test "the billed model rides on turn_completed" do
      # Costing has to price the model the provider CHARGED for, which is not
      # always the one configured: with no :model the backend substitutes its
      # own default and reports it back in the response metadata. Without this
      # on the durable payload, a turn prices at $0.00 and no budget can bind.
      session_id = "contract-model-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      assert {:ok, _} =
               StreamPump.pump(session_id, mock_stream("answer"), prompt: "hi")

      completed =
        session_id
        |> drain_events()
        |> Enum.filter(&(&1.type == :turn_completed))

      assert completed != []
      assert Enum.all?(completed, &(&1.payload.model == "mock-1"))
    end

    test "maps a completed run onto the v0 vocabulary, in order" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      assert {:ok, %{content: content}} =
               StreamPump.pump(session_id, mock_stream("Hello!"), prompt: "hi")

      assert content =~ "Hello"

      events = drain_events(session_id)
      types = Enum.map(events, & &1.type)

      assert List.first(types) == :turn_started
      assert List.last(types) == :turn_completed
      assert :item_completed in types

      # the final turn_completed closes the run
      assert %Event{payload: %{final: true}} = List.last(events)

      # ids are monotonic from 1
      assert Enum.map(events, & &1.id) == Enum.to_list(1..length(events))

      # one turn: every event shares session and turn ids
      assert Enum.uniq(Enum.map(events, & &1.session_id)) == [session_id]
      assert [_turn_id] = Enum.uniq(Enum.map(events, & &1.turn_id))
    end

    test "text deltas are ephemeral; completed items are durable" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      {:ok, _} = StreamPump.pump(session_id, mock_stream("chunky"), prompt: "hi")

      events = drain_events(session_id)

      for %Event{type: :item_delta} = event <- events do
        assert event.tier == :ephemeral
      end

      for %Event{type: type} = event <- events, type != :item_delta do
        assert event.tier == :durable
      end
    end

    test "the done gate is consulted on the real done path: independent postdating evidence closes gated with refs" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # A tool_use (mutation) followed by a tool_result of a DIFFERENT tool
      # name — an independent verification output that postdates the mutation
      # and is not its own echo. The gate accepts, so the final turn_completed
      # carries the evidence ref (offset 5: turn_started=1, the tool_use's
      # item_started=2 / item_completed=3, the tool_result's item_started=4 /
      # item_completed=5).
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.type == :turn_completed
      assert final.payload.final == true
      assert final.payload.refs == [5]
    end

    test "a mutation's own result echo is rejected: done closes fail-open with rejected_evidence telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "done-gate-rejected-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :rejected_evidence],
        fn _e, _m, metadata, _c ->
          send(test_pid, {:rejected_evidence, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      # The only tool_result postdating the mutation is that same call's echo
      # (same tool name) — the gate rejects it as :mutation_echo. Completion
      # stays fail-open: still final: true, no refs, plus telemetry.
      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      final = session_id |> drain_events() |> List.last()
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:rejected_evidence, %{reason: {:mutation_echo, _}}}
    end

    test "a tool_result seals an open message first, so text across the boundary is not fused" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # A message opens, a tool_result arrives while it is still open, then
      # more answer text follows. The pre-boundary text must seal as its OWN
      # message item before the tool_result item, and the post-boundary text
      # must open a FRESH message -- not re-enter the still-open one and fuse
      # both text runs into a single block across the tool_result.
      stream = [
        {:text_delta, "before "},
        {:tool_result, %{name: "run_tests", result: "ok"}},
        {:text_delta, "after"},
        {:done, %{content: "after"}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      events = drain_events(session_id)

      message_contents =
        for %Event{type: :item_completed, payload: %{item_type: :message, content: c}} <-
              events,
            do: c

      # TWO distinct message items, not one fused message.
      assert message_contents == ["before ", "after"]

      # The pre-boundary message seals BEFORE the tool_result item opens.
      boundary =
        for %Event{type: t, payload: %{item_type: it}} <- events,
            t in [:item_started, :item_completed],
            do: {t, it}

      assert Enum.find_index(boundary, &(&1 == {:item_completed, :message})) <
               Enum.find_index(boundary, &(&1 == {:item_started, :tool_result}))
    end

    test "a zero-tool turn closes ungated (parked policy) and emits done-gate telemetry" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      handler = "done-gate-ungated-#{System.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler,
        [:raxol, :agent, :done_gate, :ungated_done],
        fn _e, _m, metadata, _c ->
          send(test_pid, {:ungated_done, metadata})
        end,
        nil
      )

      on_exit(fn -> :telemetry.detach(handler) end)

      {:ok, _} =
        StreamPump.pump(session_id, mock_stream("plain answer"), prompt: "hi")

      final = session_id |> drain_events() |> List.last()

      # Parked zero-tool policy preserved: still final: true, no refs attached.
      assert final.payload.final == true
      refute Map.has_key?(final.payload, :refs)

      assert_receive {:ungated_done, %{turn_id: turn_id}}
      assert is_binary(turn_id)
    end

    test "an error stream yields an :error event and error return" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      error_stream = [{:error, {:http, 500, "boom"}}]

      assert {:error, {:http, 500, "boom"}} =
               StreamPump.pump(session_id, error_stream, prompt: "hi")

      events = drain_events(session_id)
      assert Enum.any?(events, &(&1.type == :error))
    end

    test "an error mid-stream seals whatever reasoning/answer text streamed before the halt (no dangling item_started)" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "thinking"},
        {:text_delta, "partial ans"},
        {:error, :timeout}
      ]

      assert {:error, :timeout} = StreamPump.pump(session_id, stream, prompt: "q")

      events = drain_events(session_id)

      assert Enum.any?(events, &(&1.type == :error))

      # No dangling item_started: every opened item (reasoning, message)
      # has a matching item_completed in the drained journal.
      started_ids =
        for %Event{type: :item_started, payload: payload} <- events,
            do: payload.item_id

      completed_ids =
        for %Event{type: :item_completed, payload: payload} <- events,
            do: payload.item_id

      assert started_ids != [], "expected at least one opened item in this witness"
      assert Enum.sort(started_ids) == Enum.sort(completed_ids)

      # The streamed reasoning and partial answer both survive replay,
      # sealed as their own durable blocks rather than evaporating.
      reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      message_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      assert reasoning_seal.payload.content == "thinking"
      assert message_seal.payload.content == "partial ans"

      # Reasoning sealed before the message (mirrors every other boundary),
      # and the error event closes the run last.
      assert reasoning_seal.id < message_seal.id
      assert message_seal.id < Enum.find(events, &(&1.type == :error)).id
    end
  end

  describe "pump/3 — tool-execution vocabulary" do
    test "approval events sequence into the run's id stream between tool_use and result" do
      session_id = "contract-appr-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "edit_file", arguments: %{}, id: "e1"}},
        {:approval_requested, %{request_id: "r1", tool_name: "edit_file", options: []}},
        {:approval_decided, %{request_id: "r1", option_id: "allow", decision: :allow}},
        {:tool_result, %{name: "edit_file", result: %{ok: true}}},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)
      types = Enum.map(events, & &1.type)

      assert :approval_requested in types
      assert :approval_decided in types

      req_i = Enum.find_index(types, &(&1 == :approval_requested))
      dec_i = Enum.find_index(types, &(&1 == :approval_decided))
      assert req_i < dec_i

      # ids are strictly monotonic across the whole run (single id source).
      ids = Enum.map(events, & &1.id)
      assert ids == Enum.sort(ids)
      assert ids == Enum.uniq(ids)
    end

    test "a diff-shaped tool_result flattens path/old/new + a diff marker onto the payload" do
      session_id = "contract-diff-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_result,
         %{
           name: "edit_file",
           result: %{path: "a.ex", old: "x", new: "y", language: "elixir"}
         }},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)

      tr =
        Enum.find(
          events,
          &(&1.type == :item_completed and
              &1.payload[:item_type] == :tool_result)
        )

      assert tr.payload.diff == true
      assert tr.payload.path == "a.ex"
      assert tr.payload.old == "x"
      assert tr.payload.new == "y"
    end

    test "a tool_unexecuted event seals a visible ⚠ marker message" do
      session_id = "contract-unexec-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_unexecuted, %{name: "write_file", reason: :dropped}},
        {:done, %{content: "done", usage: %{}}}
      ]

      {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      events = drain_events(session_id)

      marker =
        Enum.find(events, fn e ->
          e.payload[:item_type] == :message and is_binary(e.payload[:content]) and
            e.payload.content =~ "never executed"
        end)

      assert marker, "expected a ⚠ unexecuted marker message"
      assert marker.payload.content =~ "write_file"
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = event} ->
        drain_events(session_id, [event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "the evidence marker on the final turn_completed" do
    # Without the marker, a rejected done and a done that offered no
    # evidence close with the same payload, and telemetry, which tells them
    # apart live, is not journaled.
    test "the marker tells a rejected done from one that offered no evidence" do
      session_id = "done-gate-marker-rejected-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # Rejected arm: the only postdating tool_result is the mutation's own
      # echo (:mutation_echo) — evidence was offered and refused.
      rejected_stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, rejected_stream, prompt: "p")
      rejected_final = session_id |> drain_events() |> List.last()

      # Absent arm: a zero-tool turn — no evidence ever offered.
      absent_session_id = "done-gate-marker-absent-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(absent_session_id)

      {:ok, _} = StreamPump.pump(absent_session_id, mock_stream("plain answer"), prompt: "hi")
      absent_final = absent_session_id |> drain_events() |> List.last()

      # Both close `final: true` with no `refs`.
      assert rejected_final.payload.final == true
      assert absent_final.payload.final == true
      refute Map.has_key?(rejected_final.payload, :refs)
      refute Map.has_key?(absent_final.payload, :refs)

      # Only the marker differs.
      assert rejected_final.payload[:evidence] == :rejected
      assert absent_final.payload[:evidence] == :absent
      assert rejected_final.payload[:evidence] != absent_final.payload[:evidence]
    end

    test "accepted done carries evidence: :accepted alongside the untouched refs carrier" do
      session_id = "done-gate-marker-accepted-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{path: "/x"}, id: "call-1"}},
        {:tool_result, %{name: "run_tests", result: "tests: 12 passed"}},
        {:done, %{content: "done", usage: %{output_tokens: 1}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      # the item lifecycle emits item_started siblings, so the accepted
      # tool_result ref sits at journal offset 5 (not the pre-lifecycle 3)
      assert final.payload.evidence == :accepted
      assert final.payload.refs == [5]
      refute Map.has_key?(final.payload, :evidence_rejected)
    end

    test "rejected done carries evidence_rejected with the DoneGate reason flattened onto the wire, never inspect-stringified" do
      session_id = "done-gate-marker-detail-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      assert final.payload.evidence == :rejected

      assert %{"refs" => offered_refs, "reason" => reason, "ref" => offending_ref} =
               final.payload.evidence_rejected

      assert is_list(offered_refs)
      assert reason == "mutation_echo"
      assert is_integer(offending_ref)

      # Never `inspect/1`-stringified (that would look like "{:mutation_echo, 3}").
      refute reason =~ "{"
      refute reason =~ ":"

      # Survives a real JSON round-trip (the actual wire path).
      line = final |> Contract.encode_line() |> IO.iodata_to_binary()
      assert {:ok, decoded} = Jason.decode(String.trim_trailing(line))
      assert decoded["payload"]["evidence"] == "rejected"

      assert decoded["payload"]["evidence_rejected"] == %{
               "refs" => offered_refs,
               "reason" => "mutation_echo",
               "ref" => offending_ref
             }
    end

    test "absent done (:evidence_required) carries evidence: :absent and no evidence_rejected detail" do
      session_id = "done-gate-marker-absent-detail-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      {:ok, _} = StreamPump.pump(session_id, mock_stream("plain answer"), prompt: "hi")
      final = session_id |> drain_events() |> List.last()

      assert final.payload.evidence == :absent
      refute Map.has_key?(final.payload, :evidence_rejected)
      refute Map.has_key?(final.payload, :refs)
    end

    test "the DoneGate reject reason is not observable on the wire before the marker (telemetry-only today)" do
      # This test pins the CURRENT payload shape's ceiling: nothing about
      # *why* the gate rejected survives onto `final.payload` apart from the
      # `evidence_rejected` detail. It guards against a
      # future regression that puts the raw verdict tuple (or an
      # `inspect/1` rendering of it) directly under an unexpected key.
      session_id = "done-gate-marker-reason-shape-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "fs_write", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "fs_write", result: "wrote"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")
      final = session_id |> drain_events() |> List.last()

      allowed_keys = MapSet.new([:usage, :final, :evidence, :evidence_rejected])
      assert MapSet.new(Map.keys(final.payload)) |> MapSet.subset?(allowed_keys)

      refute Map.has_key?(final.payload, :reason)
      refute Map.has_key?(final.payload, :ref)
    end
  end
end
