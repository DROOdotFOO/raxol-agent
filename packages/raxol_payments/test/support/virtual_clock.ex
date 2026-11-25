defmodule Raxol.Payments.Test.VirtualClock do
  @moduledoc """
  A `t:Raxol.Payments.Poll.clock/0` whose time moves only when the poller
  waits: `sleep_ms` adds to it at once instead of sleeping.

  With it, the polls that fit before a deadline follow from the intervals
  alone, however slowly the host runs the test. The time is a `:counters`
  cell, so any process may read or advance it.
  """

  alias Raxol.Payments.Poll

  @doc "A clock starting at 0 ms."
  @spec new() :: Poll.clock()
  def new do
    time = :counters.new(1, [])

    %{
      now_ms: fn -> :counters.get(time, 1) end,
      sleep_ms: fn ms when is_integer(ms) and ms >= 0 -> :counters.add(time, 1, ms) end
    }
  end
end
