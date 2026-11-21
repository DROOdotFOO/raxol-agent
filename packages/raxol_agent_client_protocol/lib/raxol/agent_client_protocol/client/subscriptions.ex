defmodule Raxol.AgentClientProtocol.Client.Subscriptions do
  @moduledoc false
  # Owns the `Client.subscribe/3` table. A long-lived owner keeps the table from
  # disappearing with whichever short-lived process first touched it, and its
  # monitors prune entries for dead subscribers and dead connections.
  #
  # Started by the application; when the application is not running (this
  # package's own test env, or an embedder that has not spliced it in) the first
  # subscriber starts an unsupervised instance.

  use GenServer

  @table :raxol_acp_client_session_subscriptions

  @spec start_link(keyword()) :: GenServer.on_start() | :ignore
  def start_link(_opts \\ []) do
    case GenServer.start_link(__MODULE__, [], name: __MODULE__) do
      {:error, {:already_started, _pid}} -> :ignore
      other -> other
    end
  end

  @spec subscribe(pid(), String.t(), pid()) :: :ok
  def subscribe(conn, session_id, subscriber),
    do: GenServer.call(ensure_started(), {:subscribe, {conn, session_id}, subscriber})

  @spec unsubscribe(pid(), String.t(), pid()) :: :ok
  def unsubscribe(conn, session_id, subscriber),
    do: GenServer.call(ensure_started(), {:unsubscribe, {conn, session_id}, subscriber})

  @spec subscribers(pid(), String.t()) :: [pid()]
  def subscribers(conn, session_id) do
    for {_key, pid} <- :ets.lookup(@table, {conn, session_id}), do: pid
  rescue
    ArgumentError -> []
  end

  defp ensure_started do
    case GenServer.whereis(__MODULE__) do
      nil ->
        case GenServer.start(__MODULE__, [], name: __MODULE__) do
          {:ok, pid} -> pid
          {:error, {:already_started, pid}} -> pid
        end

      pid ->
        pid
    end
  end

  @impl true
  def init(_opts) do
    :ets.new(@table, [:bag, :protected, :named_table, read_concurrency: true])
    {:ok, %{monitored: %{}}}
  end

  @impl true
  def handle_call({:subscribe, {conn, _sid} = key, pid}, _from, state) do
    :ets.insert(@table, {key, pid})
    {:reply, :ok, state |> monitor(pid) |> monitor(conn)}
  end

  def handle_call({:unsubscribe, {conn, _sid} = key, pid}, _from, state) do
    :ets.delete_object(@table, {key, pid})
    {:reply, :ok, state |> release(pid) |> release(conn)}
  end

  # A dead process is pruned both as a subscriber and as a connection.
  @impl true
  def handle_info({:DOWN, _ref, :process, pid, _reason}, state) do
    :ets.match_delete(@table, {:_, pid})
    :ets.match_delete(@table, {{pid, :_}, :_})
    {:noreply, %{state | monitored: Map.delete(state.monitored, pid)}}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  # Drops the monitor once a process neither subscribes nor hosts subscriptions.
  defp release(state, pid) do
    in_use? =
      :ets.match(@table, {:_, pid}) != [] or :ets.match(@table, {{pid, :_}, :_}) != []

    case Map.pop(state.monitored, pid) do
      {ref, monitored} when is_reference(ref) and not in_use? ->
        Process.demonitor(ref, [:flush])
        %{state | monitored: monitored}

      _other ->
        state
    end
  end

  defp monitor(state, pid) when is_map_key(state.monitored, pid), do: state
  defp monitor(state, pid), do: put_in(state.monitored[pid], Process.monitor(pid))
end
