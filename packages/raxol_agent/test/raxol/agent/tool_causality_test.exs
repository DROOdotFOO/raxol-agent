defmodule Raxol.Agent.ToolCausalityTest do
  @moduledoc """
  Tool-call causality on the journal `Raxol.Agent.StreamPump` produces from a
  real `Raxol.Agent.Stream.react/2` loop: every `tool_result` names, by
  `call_id`, a `tool_use` of the same tool earlier in the same turn; each
  `tool_use` gets exactly one result; and a call that failed is reported
  failed, never as a success.
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

  @max_turns 3
  @max_rounds 3
  @max_calls_per_round 3

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

  defp turn_gen do
    call_gen()
    |> list_of(min_length: 1, max_length: @max_calls_per_round)
    |> list_of(max_length: @max_rounds)
  end

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

    assert {:ok, _} = StreamPump.pump(session_id, stream, prompt: "go")
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

  # Walks the journal in order, matching each result to the open use of
  # its turn with the same call_id. Fails on a result that answers no open
  # use: one from another turn, one already answered, or one with no id.
  defp pair(items) do
    {pairs, open} =
      Enum.reduce(items, {[], %{}}, fn
        {turn, :tool_use, use}, {pairs, open} ->
          {pairs, Map.put(open, {turn, use.call_id}, use)}

        {turn, :tool_result, result}, {pairs, open} ->
          case Map.pop(open, {turn, Map.get(result, :call_id)}) do
            {nil, _open} ->
              flunk("tool_result #{inspect(result)} in #{turn} answers no open tool_use")

            {use, open} ->
              {[{use, result} | pairs], open}
          end
      end)

    {Enum.reverse(pairs), open}
  end

  property "every tool_result answers one prior same-turn tool_use, and failures stay failures" do
    check all(turns <- list_of(turn_gen(), min_length: 1, max_length: @max_turns)) do
      session_id = "causality-#{System.unique_integer([:positive])}"
      :ok = SessionStreamer.subscribe(session_id)

      Enum.each(turns, &run_turn(session_id, &1))
      items = session_id |> drain() |> tool_items()

      {pairs, unanswered} = pair(items)
      uses = for {_turn, :tool_use, use} <- items, do: use

      assert unanswered == %{}
      assert length(uses) == length(List.flatten(turns))
      assert length(pairs) == length(uses)

      for {use, {name, n}} <- Enum.zip(uses, List.flatten(turns)) do
        assert use.name == name
        assert use.arguments == %{"n" => n}
      end

      for {use, result} <- pairs do
        assert result.name == use.name

        case @outcomes[use.name] do
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
