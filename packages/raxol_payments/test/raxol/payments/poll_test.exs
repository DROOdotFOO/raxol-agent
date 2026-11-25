defmodule Raxol.Payments.PollTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Poll
  alias Raxol.Payments.Test.VirtualClock

  defp terminal?(%{done: done}), do: done

  # A fetch driven by a queue in the process dictionary, so each call returns the
  # next scripted result. Runs in the test process (Poll calls fetch inline).
  defp scripted_fetch(results) do
    Process.put(:poll_script, results)

    fn ->
      [next | rest] = Process.get(:poll_script)
      Process.put(:poll_script, rest)
      next
    end
  end

  describe "run/3" do
    test "returns terminal status and elapsed on the first poll" do
      fetch = scripted_fetch([{:ok, %{done: true}}])

      assert {:ok, %{done: true}, elapsed} = Poll.run(fetch, &terminal?/1)
      assert is_integer(elapsed) and elapsed >= 0
    end

    test "polls until terminal" do
      fetch =
        scripted_fetch([
          {:ok, %{done: false}},
          {:ok, %{done: false}},
          {:ok, %{done: true}}
        ])

      assert {:ok, %{done: true}, _elapsed} =
               Poll.run(fetch, &terminal?/1, fast_interval_ms: 1, slow_interval_ms: 1)
    end

    test "treats a 429 as a transient backoff and keeps polling" do
      fetch =
        scripted_fetch([
          {:error, {:http, 429, %{}}},
          {:ok, %{done: true}}
        ])

      assert {:ok, %{done: true}, _elapsed} =
               Poll.run(fetch, &terminal?/1, fast_interval_ms: 1)
    end

    test "returns a non-retryable fetch error immediately" do
      fetch = scripted_fetch([{:error, {:http, 500, %{}}}])

      assert {:error, {:http, 500, %{}}} = Poll.run(fetch, &terminal?/1)
    end

    test "returns :timeout when the deadline passes before terminal" do
      fetch = fn -> {:ok, %{done: false}} end

      assert {:error, :timeout} = Poll.run(fetch, &terminal?/1, timeout_ms: 0)
    end
  end

  describe "run/3 on an injected clock" do
    # Counts the calls of a fetch that never reaches terminal.
    defp counting_fetch do
      calls = :counters.new(1, [])
      {calls, fn -> :counters.add(calls, 1, 1) && {:ok, %{done: false}} end}
    end

    test "polls exactly as often as the intervals fit in the timeout" do
      {calls, fetch} = counting_fetch()

      assert {:error, :timeout} =
               Poll.run(fetch, &terminal?/1,
                 clock: VirtualClock.new(),
                 budget_ms: 0,
                 slow_interval_ms: 10,
                 timeout_ms: 100
               )

      # At 0, 10, ..., 100; the wait after the last would pass the deadline.
      assert :counters.get(calls, 1) == 11
    end

    test "switches from the fast to the slow interval when the budget is spent" do
      {calls, fetch} = counting_fetch()

      assert {:error, :timeout} =
               Poll.run(fetch, &terminal?/1,
                 clock: VirtualClock.new(),
                 budget_ms: 30,
                 fast_interval_ms: 10,
                 slow_interval_ms: 100,
                 timeout_ms: 230
               )

      # Fast at 0, 10, 20, 30, then slow at 130 and 230.
      assert :counters.get(calls, 1) == 6
    end

    test "reports the elapsed time of the clock it was given" do
      fetch =
        scripted_fetch([{:ok, %{done: false}}, {:ok, %{done: false}}, {:ok, %{done: true}}])

      assert {:ok, %{done: true}, 40} =
               Poll.run(fetch, &terminal?/1,
                 clock: VirtualClock.new(),
                 budget_ms: 0,
                 slow_interval_ms: 20
               )
    end
  end
end
