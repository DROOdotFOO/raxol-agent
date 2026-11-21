defmodule Raxol.Agent.StreamPumpItemsTest do
  @moduledoc """
  Item lifecycles `Raxol.Agent.StreamPump.pump/3` emits: streamed message
  items, blank-message suppression, reasoning items and wire markers.
  """
  use ExUnit.Case, async: false

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.StreamPump

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  defp drain_events(session_id, acc \\ []) do
    receive do
      {:session_event, ^session_id, %Event{} = event} ->
        drain_events(session_id, [event | acc])
    after
      100 -> Enum.reverse(acc)
    end
  end

  describe "streaming item lifecycle (item_started + item_id)" do
    # The live tail (`Raxol.Harness.Projection.BlockBuilder.build_tail/2`)
    # shows `item_delta` chunks only for an item with an `item_started` and
    # an `item_id`, the shape the fixture corpus carries.

    test "a streamed message opens with item_started and every delta carries its item_id" do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "Hel"},
        {:text_delta, "lo!"},
        {:done, %{content: "Hello!", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "hi")

      events = drain_events(session_id)

      started =
        Enum.find(events, &(&1.type == :item_started))

      assert started != nil,
             "pump must emit item_started before the first delta"

      assert started.tier == :durable
      assert %{item_id: item_id, item_type: :message} = started.payload
      assert is_binary(item_id) and item_id != ""

      deltas = Enum.filter(events, &(&1.type == :item_delta))
      assert length(deltas) == 2

      for delta <- deltas do
        assert delta.payload.item_id == item_id
      end

      # item_started precedes the first delta in emit order.
      first_delta = List.first(deltas)
      assert started.id < first_delta.id

      # The message's item_completed closes the SAME item.
      completed =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      assert completed.payload.item_id == item_id
      assert completed.payload.content == "Hello!"
    end

    test "tool_use and tool_result complete as DISTINCT items, each with a started sibling" do
      # Without distinct item_ids every item_completed shares the same
      # (nil) id, so the projection folds them into ONE group and drops
      # the tool_result completion as a duplicate -- a live multi-item
      # turn silently loses blocks the fixture path renders.
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{path: "."}, id: "call-1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      events = drain_events(session_id)

      completed_ids =
        for %Event{type: :item_completed, payload: payload} <- events do
          assert is_binary(payload.item_id) and payload.item_id != ""
          payload.item_id
        end

      # tool_use, tool_result, and the done message: three distinct items.
      assert length(completed_ids) == 3
      assert length(Enum.uniq(completed_ids)) == 3

      started_ids =
        for %Event{type: :item_started, payload: payload} <- events,
            do: payload.item_id

      # Every completed item has a started sibling with the same id.
      assert Enum.sort(started_ids) == Enum.sort(completed_ids)
    end

    test "a non-diff tool_result lifts a human :content summary (never an empty row)" do
      session_id = "contract-summary-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{path: "."}, id: "call-1"}},
        {:tool_result,
         %{
           name: "list_dir",
           result: %{path: ".", entries: ["a.ex", "b/", "c.md"]}
         }},
        {:done, %{content: "done", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      completed =
        session_id
        |> drain_events()
        |> Enum.find(
          &(&1.type == :item_completed and
              &1.payload[:item_type] == :tool_result)
        )

      # The structured result nests under :result; the summary is lifted to
      # :content, exactly where the harness block's body extraction reads it.
      assert completed.payload[:content] =~ "3 entries"
      assert completed.payload[:content] =~ "a.ex"
    end

    test "a message item open when a tool_use arrives seals with its accumulated text" do
      # The pre-tool text run is a real assistant message: it must seal
      # as its own item (ordered BEFORE the tool items) rather than
      # leak into the final answer's item or vanish.
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "let me check"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "call-1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "final answer", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      events = drain_events(session_id)

      messages =
        for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
              events,
            do: p

      assert Enum.map(messages, & &1.content) == [
               "let me check",
               "final answer"
             ]
    end
  end

  describe "empty message suppression (no empty ❮ block, ever)" do
    # A round with tool calls can carry blank message content beside them
    # (LM Studio streams "\n\n" before the call). A message item opens only
    # at the first non-blank text, so a blank run emits no item.

    defp completed_messages(events) do
      for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
            events,
          do: p
    end

    defp message_starteds(events) do
      Enum.filter(
        events,
        &(&1.type == :item_started and &1.payload[:item_type] == :message)
      )
    end

    test "a tool-call-only round emits NO message item for its blank pre-tool text" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # The reported live shape: thinking, a whitespace-only text delta,
      # then the tool round, then the real final answer.
      stream = [
        {:reasoning, "let me look at the project"},
        {:text_delta, "\n\n"},
        {:tool_use, %{name: "read_file", arguments: %{"path" => "mix.exs"}, id: "c1"}},
        {:tool_result, %{name: "read_file", result: "defmodule..."}},
        {:text_delta, "the answer"},
        {:done, %{content: "the answer", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # Exactly ONE sealed message — the real answer. The blank pre-tool
      # run sealed nothing (no empty ❮ block between the ∴ and the tool).
      assert [%{content: "the answer"}] = completed_messages(events)
      assert [_one] = message_starteds(events)

      # The reasoning block still seals ahead of the tool_use.
      reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      tool_use =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_use)
        )

      assert reasoning_seal.id < tool_use.id
    end

    test "a whitespace-only answer stream seals NO message item" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, " "},
        {:text_delta, "\n\t"},
        {:done, %{content: " \n\t", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert completed_messages(events) == []
      assert message_starteds(events) == []

      # The turn still closes honestly.
      final = List.last(events)
      assert final.type == :turn_completed
      assert final.payload.final == true
    end

    test "a blank done after a tool round emits no empty final message item" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert completed_messages(events) == []

      # The tool items and the final turn_completed are untouched.
      assert Enum.any?(
               events,
               &(&1.type == :item_completed and
                   &1.payload[:item_type] == :tool_result)
             )

      assert %Event{type: :turn_completed, payload: %{final: true}} =
               List.last(events)
    end

    test "leading blank text still lands in the pre-tool sealed message when real text follows" do
      session_id = "contract-empty-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:text_delta, "\n"},
        {:text_delta, "checking"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:done, %{content: "final", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # The lazily-opened item's sealed content keeps the leading blank
      # chunk (accumulated untouched before the open), mirroring the
      # reasoning lifecycle's documented behavior.
      assert Enum.map(completed_messages(events), & &1.content) == [
               "\nchecking",
               "final"
             ]

      # The opener's own delta carries the full accumulated-so-far text.
      [opener | _] =
        Enum.filter(
          events,
          &(&1.type == :item_delta and &1.payload[:chunk] != nil and
              &1.payload[:thought] == nil)
        )

      assert opener.payload.chunk == "\nchecking"
    end
  end

  describe "reasoning item lifecycle (durable ∴ blocks)" do
    # Reasoning gets a message's item lifecycle: a lazily opened durable
    # `item_type: :reasoning` item, ephemeral deltas carrying its id, and a
    # seal at the reasoning-to-answer transition or turn end.

    defp reasoning_items(events) do
      for %Event{type: :item_completed, payload: %{item_type: :reasoning} = p} <-
            events,
          do: p
    end

    test "a thought stream opens a durable reasoning item, sealed before the message" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "let me think"},
        {:reasoning, " harder"},
        {:text_delta, "the answer"},
        {:done, %{content: "the answer", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")

      events = drain_events(session_id)

      started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      assert started != nil,
             "a thought must open a durable reasoning item_started"

      assert started.tier == :durable
      assert %{item_id: reasoning_id} = started.payload

      # The sealed reasoning block carries the full accumulated thought.
      [reasoning] = reasoning_items(events)
      assert reasoning.item_id == reasoning_id
      assert reasoning.content == "let me think harder"

      # Reasoning seals BEFORE the message item (its ∴ block renders first).
      msg =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :message)
        )

      reasoning_seal =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      assert reasoning_seal.id < msg.id
      assert msg.payload.content == "the answer"
    end

    test "reasoning deltas are ephemeral, marked thought:true, and carry the item_id" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "aa"},
        {:reasoning, "bb"},
        {:text_delta, "x"},
        {:done, %{content: "x", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      reasoning_deltas =
        for %Event{type: :item_delta, payload: %{thought: true} = p} <- events,
            do: p

      assert length(reasoning_deltas) == 2

      for delta <- reasoning_deltas do
        assert delta.item_id == started.payload.item_id
      end

      for %Event{type: :item_delta} = e <- events,
          do: assert(e.tier == :ephemeral)
    end

    test "whitespace-only thinking seals NO reasoning block" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "  "},
        {:reasoning, "\n\t"},
        {:text_delta, "hi"},
        {:done, %{content: "hi", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert reasoning_items(events) == []

      refute Enum.any?(
               events,
               &(&1.type == :item_started and
                   &1.payload[:item_type] == :reasoning)
             )
    end

    test "think→tool→think→answer produces TWO reasoning blocks in true order" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "first I plan"},
        {:tool_use, %{name: "list_dir", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "list_dir", result: "mix.exs"}},
        {:reasoning, "now I conclude"},
        {:text_delta, "final"},
        {:done, %{content: "final", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      contents = reasoning_items(events) |> Enum.map(& &1.content)
      assert contents == ["first I plan", "now I conclude"]

      # The first reasoning seals BEFORE the tool_use (∴ block ahead of tool).
      first_reasoning =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :reasoning)
        )

      tool_use =
        Enum.find(
          events,
          &(&1.type == :item_completed and &1.payload[:item_type] == :tool_use)
        )

      assert first_reasoning.id < tool_use.id
    end

    test "a pure-thinking turn seals its reasoning at done (no answer text)" do
      session_id = "contract-reason-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:reasoning, "just thinking, no words"},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      assert [%{content: "just thinking, no words"}] = reasoning_items(events)
    end
  end

  describe "wire-boundary markers (durable ⚠ blocks)" do
    # A wire marker (length truncation, unparseable chunk) seals as a durable
    # ⚠ message block, after reasoning and the partial answer.

    defp message_items(events) do
      for %Event{type: :item_completed, payload: %{item_type: :message} = p} <-
            events,
          do: p
    end

    test "a {:marker, text} event seals a durable ⚠ message item" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:marker, "⚠ response truncated — hit token limit"},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      marker =
        Enum.find(events, fn e ->
          e.type == :item_completed and e.payload[:item_type] == :message and
            is_binary(e.payload[:content]) and e.payload.content =~ "truncated"
        end)

      assert marker, "expected a ⚠ truncation marker message"
      assert marker.tier == :durable
    end

    test "a blank marker seals nothing" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:marker, "   "},
        {:done, %{content: "hi", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      # Only the real answer message seals; no empty marker block.
      assert [%{content: "hi"}] = message_items(events)
    end

    test "reasoning seals as ∴ BEFORE a partial answer, which precedes the truncation marker" do
      session_id = "contract-marker-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      # The producer order for a non-empty length-truncated round:
      # reasoning → partial content → marker → done.
      stream = [
        {:reasoning, "deep thought"},
        {:text_delta, "partial"},
        {:marker, "⚠ truncated"},
        {:done, %{content: "partial", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "q")
      events = drain_events(session_id)

      reasoning_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :reasoning)
        )

      answer_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :message and
              &1.payload[:item_id] != marker_item_id(events))
        )

      marker_started =
        Enum.find(
          events,
          &(&1.type == :item_started and &1.payload[:item_type] == :message and
              &1.payload[:item_id] == marker_item_id(events))
        )

      # Render order is first-appearance (item_started): ∴, answer, ⚠.
      assert reasoning_started.id < answer_started.id
      assert answer_started.id < marker_started.id

      # The partial answer and the marker are DISTINCT durable messages
      # (the answer is not double-sealed, the marker is not folded in).
      contents = message_items(events) |> Enum.map(& &1.content)
      assert "partial" in contents
      assert Enum.any?(contents, &(&1 =~ "truncated"))
    end

    # The marker's message item_id is the one whose sealed content carries
    # the ⚠ text; used to tell the answer message from the marker message.
    defp marker_item_id(events) do
      Enum.find_value(events, fn
        %Event{type: :item_completed, payload: %{item_type: :message} = p} ->
          if is_binary(p[:content]) and p.content =~ "truncated",
            do: p[:item_id],
            else: nil

        _ ->
          nil
      end)
    end
  end

  describe "tool_result call_id" do
    defp tool_result_items(id) do
      session_id = "contract-test-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      stream = [
        {:tool_use, %{name: "t", arguments: %{}, id: "c1"}},
        {:tool_result, %{name: "t", result: %{ok: true}, id: id}},
        {:done, %{content: "", usage: %{}}}
      ]

      assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "p")

      for %Event{type: :item_completed, payload: %{item_type: :tool_result} = p} <-
            drain_events(session_id),
          do: p
    end

    test "a short string id is journaled as the result's call_id" do
      assert [%{call_id: "c1"}] = tool_result_items("c1")
    end

    test "an oversized or non-string id is not journaled" do
      for id <- [String.duplicate("x", 257), %{"nested" => [1, 2]}, nil] do
        assert [payload] = tool_result_items(id)
        refute Map.has_key?(payload, :call_id)
      end
    end
  end
end
