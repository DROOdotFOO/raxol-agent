defmodule Raxol.Agent.ToolCausalityTest do
  @moduledoc """
  Tool-call causality on the journal `Raxol.Agent.StreamPump` produces from a
  real `Raxol.Agent.Stream.react/2` loop: every `tool_result` follows a
  `tool_use` of the same name in the same turn, each `tool_use` gets at most
  one result, and a call that failed is reported failed, never as a success.
  """
  use ExUnit.Case, async: false
  use ExUnitProperties

  alias Raxol.Agent.Contract.Event
  alias Raxol.Agent.SessionStreamer
  alias Raxol.Agent.StreamPump

  defmodule Echo do
    use Raxol.Agent.Action,
      name: "echo",
      description: "Return its input",
      schema: [input: [n: [type: :integer, required: true, description: "Value"]]]

    @impl true
    def run(%{n: n}, _ctx), do: {:ok, %{n: n}}
  end

  defmodule Refuse do
    use Raxol.Agent.Action,
      name: "refuse",
      description: "Always fail",
      schema: [input: [n: [type: :integer, required: true, description: "Value"]]]

    @impl true
    def run(_params, _ctx), do: {:error, :refused}
  end

  # "missing" names no action, so dispatch fails before any action runs.
  @outcomes %{"echo" => :ok, "refuse" => :error, "missing" => :error}

  setup do
    start_supervised!({SessionStreamer, []})
    :ok
  end

  defp call_gen do
    gen all(
          name <- member_of(Map.keys(@outcomes)),
          n <- integer(0..99)
        ) do
      {name, n}
    end
  end

  # A turn is up to three tool rounds of one to three calls each.
  defp turn_gen, do: list_of(list_of(call_gen(), min_length: 1, max_length: 3), max_length: 3)

  # Each round is answered once, then the backend gives a plain answer.
  defp run_turn(session_id, rounds) do
    scripted =
      rounds
      |> Enum.with_index()
      |> Enum.map(fn {calls, r} ->
        calls
        |> Enum.with_index()
        |> Enum.map(fn {{name, n}, i} ->
          %{"id" => "c#{r}-#{i}", "name" => name, "arguments" => %{"n" => n}}
        end)
      end)

    {:ok, queue} = Agent.start_link(fn -> scripted end)

    next_round = fn ->
      Agent.get_and_update(queue, fn
        [] -> {nil, []}
        [round | rest] -> {round, rest}
      end)
    end

    stream =
      Raxol.Agent.Stream.react("go",
        backend: Raxol.Agent.Backend.Mock,
        backend_opts: [tool_calls_fn: next_round, response: "done"],
        actions: [Echo, Refuse]
      )

    {:ok, _} = StreamPump.pump(session_id, stream, prompt: "go")
    Agent.stop(queue)
  end

  # `emit/2` is a cast; the unsubscribe call returns only after the
  # streamer has delivered every event this process emitted before it.
  defp drain(session_id) do
    :ok = SessionStreamer.unsubscribe(session_id)
    collect(session_id, [])
  end

  defp collect(session_id, acc) do
    receive do
      {:session_event, ^session_id, %Event{} = event} -> collect(session_id, [event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp tool_items(events) do
    for %Event{type: :item_completed, payload: %{item_type: type} = p} = ev <- events,
        type in [:tool_use, :tool_result],
        do: {ev.turn_id, type, p}
  end

  # Walks the journal in order, pairing each result with the oldest
  # unanswered use of its turn. Fails on a result with no use to answer.
  defp pair(items) do
    {pairs, open} =
      Enum.reduce(items, {[], %{}}, fn
        {turn, :tool_use, use}, {pairs, open} ->
          {pairs, Map.update(open, turn, [use], &(&1 ++ [use]))}

        {turn, :tool_result, result}, {pairs, open} ->
          case Map.get(open, turn, []) do
            [use | rest] ->
              {[{use, result} | pairs], Map.put(open, turn, rest)}

            [] ->
              flunk("tool_result #{inspect(result.name)} in #{turn} has no prior tool_use")
          end
      end)

    {Enum.reverse(pairs), open}
  end

  property "every tool_result answers one prior same-turn tool_use, and failures stay failures" do
    check all(turns <- list_of(turn_gen(), min_length: 1, max_length: 3), max_runs: 50) do
      session_id = "causality-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      Enum.each(turns, &run_turn(session_id, &1))
      events = drain(session_id)

      {pairs, unanswered} = events |> tool_items() |> pair()
      calls = turns |> List.flatten()

      assert length(pairs) == length(calls)
      assert Enum.all?(Map.values(unanswered), &(&1 == []))

      for {{use, result}, {name, _n}} <- Enum.zip(pairs, calls) do
        assert use.name == name
        assert result.name == use.name

        case @outcomes[name] do
          :ok -> assert result.result == %{n: use.arguments["n"]}
          :error -> assert match?({:error, _}, result.result)
        end
      end
    end
  end

  test "a turn with no tool calls journals no tool_result" do
    session_id = "causality-#{System.unique_integer([:positive])}"
    :ok = SessionStreamer.subscribe(session_id)

    run_turn(session_id, [])

    assert session_id |> drain() |> tool_items() == []
  end
end
