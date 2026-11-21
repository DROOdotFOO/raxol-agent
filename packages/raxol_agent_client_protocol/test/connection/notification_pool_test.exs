defmodule Raxol.AgentClientProtocol.Connection.NotificationPoolTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Raxol.AgentClientProtocol.Connection.NotificationPool, as: Pool

  defp item(n), do: {"session/update", n, nil}

  test "runs up to the cap, then queues up to the backlog, then refuses" do
    pool = Pool.new(2, 1)
    assert {:run, pool} = Pool.admit(pool, item(1))
    assert {:run, pool} = Pool.admit(pool, item(2))
    assert {:queued, pool} = Pool.admit(pool, item(3))
    assert :full = Pool.admit(pool, item(4))
    assert %{running: 2, queued: 1} = pool
  end

  test "a released slot starts the oldest waiting item" do
    {:run, pool} = Pool.admit(Pool.new(1, 3), item(1))
    {:queued, pool} = Pool.admit(pool, item(2))
    {:queued, pool} = Pool.admit(pool, item(3))

    assert {[{_, 2, _}], pool} = Pool.release(pool)
    assert %{running: 1, queued: 1} = pool
    assert {[{_, 3, _}], pool} = Pool.release(pool)
    assert {[], %{running: 0, queued: 0}} = Pool.release(pool)
  end

  test "a new item does not overtake a waiting one, even with a free slot" do
    pool = %{Pool.new(2, 2) | running: 1, queued: 1, backlog: :queue.from_list([item(1)])}
    assert {:queued, %{running: 1, queued: 2}} = Pool.admit(pool, item(2))
  end

  test "reset forgets running and waiting items" do
    {:run, pool} = Pool.admit(Pool.new(1, 1), item(1))
    {:queued, pool} = Pool.admit(pool, item(2))
    assert %{running: 0, queued: 0} = pool = Pool.reset(pool)
    assert :queue.is_empty(pool.backlog)
  end

  # Any sequence of arrivals and completions keeps both bounds and loses no
  # item: each admitted item eventually starts, in arrival order.
  property "bounds hold and admitted items start in order" do
    check all(
            max_running <- integer(1..4),
            max_queued <- integer(1..4),
            ops <- list_of(member_of([:arrive, :finish]), max_length: 60)
          ) do
      {pool, started, admitted, _n} =
        Enum.reduce(ops, {Pool.new(max_running, max_queued), [], [], 0}, fn op, acc ->
          {pool, _, _, _} = acc = step(op, acc)
          assert pool.running <= max_running
          assert pool.queued <= max_queued
          acc
        end)

      {waiting, _} = drain(pool, [])
      assert Enum.reverse(started) ++ waiting == Enum.reverse(admitted)
    end
  end

  defp step(:arrive, {pool, started, admitted, n}) do
    case Pool.admit(pool, item(n)) do
      {:run, pool} -> {pool, [n | started], [n | admitted], n + 1}
      {:queued, pool} -> {pool, started, [n | admitted], n + 1}
      :full -> {pool, started, admitted, n + 1}
    end
  end

  defp step(:finish, {%{running: 0}, _, _, _} = acc), do: acc

  defp step(:finish, {pool, started, admitted, n}) do
    {ready, pool} = Pool.release(pool)
    {pool, Enum.reverse(Enum.map(ready, &elem(&1, 1))) ++ started, admitted, n}
  end

  defp drain(%{running: 0, queued: 0} = pool, acc), do: {Enum.reverse(acc), pool}

  defp drain(pool, acc) do
    {ready, pool} = Pool.release(pool)
    drain(pool, Enum.reverse(Enum.map(ready, &elem(&1, 1))) ++ acc)
  end
end
