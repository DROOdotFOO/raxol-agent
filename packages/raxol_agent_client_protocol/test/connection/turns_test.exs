defmodule Raxol.AgentClientProtocol.Connection.TurnsTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Connection.Turns

  defp state(oot_seq), do: %{turns: %{}, turn_ids: %{}, oot_seq: oot_seq}

  test "out-of-turn ordinals are per session and monotone" do
    s = state(%{})
    {d0, s} = Turns.stamp_update(s, %{session_id: "a"}, 1)
    {d1, s} = Turns.stamp_update(s, %{session_id: "a"}, 2)
    {b0, _s} = Turns.stamp_update(s, %{session_id: "b"}, 3)
    assert {d0.ordinal, d1.ordinal, b0.ordinal} == {0, 1, 0}
  end

  test "out-of-turn tracking stops growing at the session cap" do
    full = Map.new(1..Turns.max_oot_sessions(), &{"s#{&1}", 5})

    {stamp, s} = Turns.stamp_update(state(full), %{session_id: "new"}, 1)
    assert stamp.ordinal == 0
    assert map_size(s.oot_seq) == Turns.max_oot_sessions()

    # Already-tracked sessions keep counting.
    {known, s} = Turns.stamp_update(s, %{session_id: "s1"}, 2)
    assert known.ordinal == 5
    assert s.oot_seq["s1"] == 6
  end
end
