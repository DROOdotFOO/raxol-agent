defmodule Raxol.Agent.McpTools.Ownership do
  @moduledoc false
  # Which agents `Raxol.Agent.McpTools` answers for. Running agents are read
  # from the agent registry on every call; stopped ones come from the ETS
  # table the McpTools process owns.

  alias Raxol.Agent.Session

  @table Raxol.Agent.McpTools
  @registry Raxol.Agent.Registry

  @type agent :: %{
          kind: :owned | :exposed,
          app: module(),
          root: Path.t() | nil,
          session_id: String.t(),
          journal_opts: keyword()
        }

  @spec table() :: atom()
  def table, do: @table

  @spec target(String.t()) :: {:running, agent()} | {:stopped, agent()} | :none
  def target(id) do
    with :none <- running_owned(id),
         :none <- running_exposed(id) do
      stopped(id)
    end
  end

  defp running_owned(id) do
    case Session.Supervisor.owner(id) do
      {:ok, {Raxol.Agent.McpTools, owned}} -> {:running, agent(id, owned)}
      _other -> :none
    end
  end

  defp running_exposed(id) do
    with true <- id in exposed(),
         {session_id, meta} <- session_of(id) do
      {:running,
       %{
         kind: :exposed,
         app: meta.app_module,
         root: nil,
         session_id: session_id,
         journal_opts: []
       }}
    else
      _ -> :none
    end
  end

  defp stopped(id) do
    case :ets.lookup(@table, id) do
      [{^id, agent}] -> if answers?(id, agent), do: {:stopped, agent}, else: :none
      [] -> :none
    end
  rescue
    ArgumentError -> :none
  end

  # A stopped row answers only while nothing of this server's runs under the
  # id: a tree running there now is another owner's, with its own journal.
  defp answers?(id, %{kind: :owned}), do: Session.Supervisor.owner(id) == :error
  defp answers?(id, %{kind: :exposed}), do: id in exposed()

  @spec agent(String.t(), %{app: module(), root: Path.t(), base_dir: Path.t()}) :: agent()
  def agent(id, %{app: app, root: root, base_dir: base_dir}),
    do: %{kind: :owned, app: app, root: root, session_id: id, journal_opts: [base_dir: base_dir]}

  @spec owned_running() :: [{String.t(), agent()}]
  def owned_running do
    for {id, {Raxol.Agent.McpTools, owned}} <- Session.Supervisor.owners(),
        do: {id, agent(id, owned)}
  end

  @doc "Record `agent` under `id`. Only the table's owner may call this."
  @spec remember(String.t(), agent()) :: String.t()
  def remember(id, agent) do
    :ets.insert(@table, {id, agent})
    id
  end

  @spec exposed() :: [String.t()]
  def exposed do
    for id <- Application.get_env(:raxol_agent, :mcp_exposed_agents, []), is_binary(id), do: id
  end

  @spec session_of(String.t()) :: {String.t(), map()} | nil
  def session_of(id),
    do: Enum.find(sessions(), fn {_session_id, meta} -> Map.get(meta, :id) == id end)

  # Only sessions whose process is alive: a just-ended one's entry lingers
  # until the Registry handles its exit.
  defp sessions do
    @registry
    |> Registry.select([{{{:session, :"$1"}, :"$2", :"$3"}, [], [{{:"$2", {{:"$1", :"$3"}}}}]}])
    |> Session.Registration.live()
    |> Enum.map(fn {_pid, session} -> session end)
  rescue
    ArgumentError -> []
  end

  @spec team_of(String.t()) :: term()
  def team_of(id) do
    case session_of(id) do
      {_session_id, meta} -> Map.get(meta, :team_id)
      nil -> nil
    end
  end

  @spec not_owned(String.t()) :: String.t()
  def not_owned(id), do: "no agent #{id} was started by this server"

  @spec stopped_refusal(String.t()) :: String.t()
  def stopped_refusal(id), do: "agent #{id} is stopped; agent_spawn starts it again"

  @spec refuse_team_member(String.t(), String.t()) :: :ok | {:error, String.t()}
  def refuse_team_member(id, what) do
    case team_of(id) do
      nil -> :ok
      team -> {:error, "#{id} belongs to team #{team} and is not #{what} from here"}
    end
  end

  @spec stoppable(String.t()) :: {:ok, agent()} | {:error, String.t()}
  def stoppable(id) do
    case target(id) do
      {:running, agent} -> with :ok <- refuse_team_member(id, "stopped"), do: {:ok, agent}
      {:stopped, _agent} -> {:error, stopped_refusal(id)}
      :none -> {:error, not_owned(id)}
    end
  end
end
