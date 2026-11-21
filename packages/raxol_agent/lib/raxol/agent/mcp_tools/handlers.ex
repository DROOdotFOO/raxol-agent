defmodule Raxol.Agent.McpTools.Handlers do
  @moduledoc false
  # Tool and resource callbacks of `Raxol.Agent.McpTools`. They run in the
  # MCP server's callback workers, not in the McpTools process.

  alias Raxol.Agent.Comm
  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.McpTools
  alias Raxol.Agent.McpTools.Ownership
  alias Raxol.Agent.McpTools.ToolDefinitions
  alias Raxol.Agent.Session

  @journal_tail 200

  @type result :: {:ok, String.t()} | {:error, String.t()}

  @spec journal_tail() :: pos_integer()
  def journal_tail, do: @journal_tail

  @spec spawn(map()) :: result()
  def spawn(%{"app" => app, "id" => id}) when is_binary(app) and is_binary(id) do
    with {:ok, %{app: module, root: root, continued: continued}} <- McpTools.spawn_agent(app, id) do
      {:ok,
       "started #{id} (#{inspect(module)}); journal root #{root}; #{journal_note(continued)}"}
    end
  end

  def spawn(_arguments), do: {:error, "app and id are required strings"}

  defp journal_note(0), do: "new journal"
  defp journal_note(count), do: "continued #{count} events"

  @spec list(map()) :: result()
  def list(_arguments) do
    owned =
      for {id, agent} <- Ownership.owned_running(),
          do: %{id: id, app: inspect(agent.app), root: agent.root, team: Ownership.team_of(id)}

    exposed =
      for id <- Ownership.exposed(),
          {_session_id, meta} <- List.wrap(Ownership.session_of(id)),
          do: %{id: id, app: inspect(meta.app_module), root: nil, team: Map.get(meta, :team_id)}

    {:ok,
     Jason.encode!(%{agents: owned ++ exposed, spawnable: McpTools.spawnable()}, pretty: true)}
  end

  @spec ask(map()) :: result()
  def ask(%{"id" => id, "message" => message} = arguments)
      when is_binary(id) and is_binary(message) do
    with {:ok, timeout_ms} <- timeout_ms(arguments),
         :ok <- askable(id) do
      do_ask(id, message, timeout_ms)
    end
  end

  def ask(_arguments), do: {:error, "id and message are required strings"}

  defp timeout_ms(%{"timeout_ms" => ms}) when is_integer(ms) and ms >= 1 do
    if ms <= ToolDefinitions.max_timeout_ms(), do: {:ok, ms}, else: timeout_refusal()
  end

  defp timeout_ms(%{"timeout_ms" => _other}), do: timeout_refusal()
  defp timeout_ms(_arguments), do: {:ok, ToolDefinitions.max_timeout_ms()}

  defp timeout_refusal,
    do: {:error, "timeout_ms is an integer from 1 to #{ToolDefinitions.max_timeout_ms()}"}

  defp askable(id) do
    case Ownership.target(id) do
      {:running, _agent} -> :ok
      {:stopped, _agent} -> {:error, Ownership.stopped_refusal(id)}
      :none -> {:error, Ownership.not_owned(id)}
    end
  end

  defp do_ask(id, message, timeout_ms) do
    case Comm.call(id, message, timeout_ms) do
      {:ok, reply} when is_binary(reply) ->
        {:ok, reply}

      {:ok, reply} ->
        {:ok, inspect(reply, pretty: true, limit: 100)}

      {:error, :timeout} ->
        {:error, "agent #{id} did not reply within #{timeout_ms} ms (timeout)"}

      {:error, :agent_down} ->
        {:error, "agent #{id} went down before it replied"}

      {:error, :not_found} ->
        {:error, "agent #{id} is restarting; ask again"}
    end
  end

  @spec status(map()) :: result()
  def status(%{"id" => id}) when is_binary(id) do
    with {:ok, state, agent} <- status_of(id, Ownership.target(id)) do
      status = %{
        id: id,
        app: inspect(agent.app),
        state: state,
        root: agent.root,
        journal: %{
          uri: McpTools.journal_uri(id),
          dir: FileStore.session_dir(agent.session_id, agent.journal_opts),
          events: events(agent)
        }
      }

      {:ok, Jason.encode!(status, pretty: true)}
    end
  end

  def status(_arguments), do: {:error, "id is a required string"}

  defp status_of(id, {:running, agent}) do
    with :ok <- Ownership.refuse_team_member(id, "reported"), do: {:ok, live_state(agent), agent}
  end

  defp status_of(_id, {:stopped, agent}), do: {:ok, "stopped", agent}
  defp status_of(id, :none), do: {:error, Ownership.not_owned(id)}

  # The session tree is up; its session process may be between restarts.
  defp live_state(agent) do
    if is_pid(Session.Supervisor.whereis(agent.session_id)), do: "running", else: "restarting"
  end

  defp events(agent) do
    case FileStore.high_watermark(agent.session_id, agent.journal_opts) do
      offset when is_integer(offset) -> offset
      {:error, _reason} -> 0
    end
  end

  @spec stop(map()) :: result()
  def stop(%{"id" => id}) when is_binary(id) do
    with :ok <- McpTools.stop_agent(id), do: {:ok, "stopped #{id}; its journal stays readable"}
  end

  def stop(_arguments), do: {:error, "id is a required string"}

  @doc "The journal resource. Ownership is checked on every read."
  @spec read_journal(String.t()) :: {:ok, map()} | {:error, String.t()}
  def read_journal(id) do
    case Ownership.target(id) do
      {_state, agent} -> journal(id, agent)
      :none -> {:error, Ownership.not_owned(id)}
    end
  end

  defp journal(id, agent) do
    case FileStore.read_records(agent.session_id, agent.journal_opts) do
      {:ok, records} ->
        {:ok,
         %{
           id: id,
           root: agent.root,
           events: length(records),
           records: Enum.take(records, -@journal_tail)
         }}

      {:error, :damaged} ->
        {:error, "journal #{id} is damaged"}

      {:error, _reason} ->
        {:error, "journal #{id} cannot be read"}
    end
  end
end
