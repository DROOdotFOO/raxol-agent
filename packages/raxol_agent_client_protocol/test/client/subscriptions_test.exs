defmodule Raxol.AgentClientProtocol.Client.SubscriptionsTest do
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Client
  alias Raxol.AgentClientProtocol.Client.Subscriptions

  defp sleeper, do: spawn(fn -> receive do: (:stop -> :ok) end)

  defp wait_until(fun, n \\ 50) do
    cond do
      fun.() -> :ok
      n == 0 -> flunk("condition never held")
      true -> Process.sleep(10) && wait_until(fun, n - 1)
    end
  end

  test "the table survives the short-lived process that first used it" do
    conn = sleeper()
    task = Task.async(fn -> Client.broadcast_update(conn, "s", :u) end)
    Task.await(task)

    :ok = Client.subscribe(conn, "s")
    Client.broadcast_update(conn, "s", :u)
    assert_receive {:acp_session_update, "s", :u}
  end

  test "a dead subscriber is pruned" do
    conn = sleeper()
    sub = sleeper()
    :ok = Client.subscribe(conn, "s", sub)
    assert Subscriptions.subscribers(conn, "s") == [sub]

    send(sub, :stop)
    wait_until(fn -> Subscriptions.subscribers(conn, "s") == [] end)
  end

  test "a dead connection's registrations are pruned" do
    conn = sleeper()
    :ok = Client.subscribe(conn, "s")
    send(conn, :stop)
    wait_until(fn -> Subscriptions.subscribers(conn, "s") == [] end)
  end

  test "start_link ignores an already running owner" do
    _ = Subscriptions.subscribers(sleeper(), "s")
    :ok = Client.subscribe(sleeper(), "s")
    assert Subscriptions.start_link() == :ignore
  end

  test "unsubscribing the last registration releases the monitor" do
    conn = sleeper()
    :ok = Client.subscribe(conn, "s")
    :ok = Client.unsubscribe(conn, "s")
    monitored = :sys.get_state(Subscriptions).monitored
    refute Map.has_key?(monitored, self())
    refute Map.has_key?(monitored, conn)
  end
end
