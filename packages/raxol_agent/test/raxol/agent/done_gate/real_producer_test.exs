defmodule Raxol.Agent.DoneGate.RealProducerTest do
  @moduledoc """
  `Raxol.Agent.DoneGate` on journals produced by the real
  `Raxol.Agent.StreamPump.pump/3`, whose payloads carry no effect stamps.
  """
  # async: false — SessionStreamer is a named singleton.
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.DoneGate
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.StreamPump

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  # Run the tests, edit code, then cite the pre-edit test run as evidence.
  #
  # Journal produced (all durable; every item carries its item_started
  # sibling): 1 turn_started, 2/3 tool_use(run_tests), 4/5
  # tool_result(run_tests), 6/7 tool_use(fs_write), 8/9
  # tool_result(fs_write), 10/11 message, 12 turn_completed{final: true}.
  defp real_journal do
    session_id = "u21-real-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    stream = [
      {:tool_use, %{name: "run_tests", id: "call-1", arguments: %{}}},
      {:tool_result, %{name: "run_tests", result: "tests: 12 passed, 0 failed"}},
      {:tool_use, %{name: "fs_write", id: "call-2", arguments: %{path: "lib/a.ex"}}},
      {:tool_result, %{name: "fs_write", result: "wrote 42 bytes"}},
      {:done, %{content: "All fixed.", usage: %{}}}
    ]

    {:ok, _} = StreamPump.pump(session_id, stream, prompt: "fix the bug")

    journal = drain_events(session_id)
    [%Event{turn_id: turn_id} | _] = journal
    {journal, turn_id}
  end

  test "the real producer stamps neither effect_class nor mutating on tool_use " do
    # If this ever fails, the producer grew effect stamping and the fail-safe
    # default below must be re-derived against the new shape.
    {journal, _turn} = real_journal()

    tool_uses = Enum.filter(journal, &(&1.payload[:item_type] == :tool_use))
    assert tool_uses != []

    for %Event{payload: payload} <- tool_uses do
      refute Map.has_key?(payload, :effect_class)
      refute Map.has_key?(payload, :mutating)
    end
  end

  test "stale evidence predating a real (unstamped) tool_use mutation is rejected" do
    # The unstamped fs_write at 7 makes the test run at 5 stale.
    {journal, turn} = real_journal()

    assert DoneGate.gate(journal, turn, [5]) == {:error, {:stale_evidence, 5}}
  end

  test "the last mutation's own echo in a real journal cannot green-light the done" do
    # Offset 9 is fs_write's own tool_result — it postdates the mutation at 7
    # trivially and verifies nothing.
    {journal, turn} = real_journal()

    assert DoneGate.gate(journal, turn, [9]) == {:error, {:mutation_echo, 9}}
  end

  test "fail-closed: no offset in a real v0 journal is acceptable evidence" do
    # With no structural effect classification, every tool call gates and
    # every result is some call's echo, so nothing is acceptable evidence
    # (see the DoneGate moduledoc).
    {journal, turn} = real_journal()

    for %Event{id: offset} <- journal do
      refute match?({:ok, _}, DoneGate.gate(journal, turn, [offset]))
    end
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{tier: :durable} = event} ->
        drain_events(session_id, [event | acc])

      {:session_event, ^session_id, %Event{}} ->
        drain_events(session_id, acc)
    after
      100 -> Enum.reverse(acc)
    end
  end
end
