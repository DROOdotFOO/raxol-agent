defmodule Raxol.AgentClientProtocol.Connection.InboundTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Connection.Inbound

  defp state(entry) do
    ref = make_ref()
    {ref, %{reply_refs: %{ref => 20}, pending_in: %{20 => entry}}}
  end

  defp entry(fields),
    do:
      Map.merge(
        %{cancelled?: false, adopter: nil, reply_ref: nil, task_ref: nil, task_pid: nil},
        fields
      )

  test "delegating a cancelled entry is refused and leaves it untouched" do
    {ref, st} = state(entry(%{cancelled?: true}))
    assert {:error, :cancelled} = Inbound.delegate(st, ref, self())
  end

  test "delegating an unknown ref is refused" do
    {_ref, st} = state(entry(%{}))
    assert {:error, :unknown_ref} = Inbound.delegate(st, make_ref(), self())
  end

  test "delegating a live entry records a monitored adopter" do
    {ref, st} = state(entry(%{}))
    assert {:ok, st} = Inbound.delegate(st, ref, self())
    assert {pid, mon} = st.pending_in[20].adopter
    assert pid == self() and is_reference(mon)
  end
end
