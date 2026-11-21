defmodule Raxol.AgentClientProtocol.Handler.Wiring do
  @moduledoc false
  # The per-connection supervision subtree shared by `Agent` and `Client`:
  #
  #     ConnectionSupervisor   :one_for_all, auto_shutdown: :any_significant
  #     ├── Task.Supervisor
  #     ├── Session.Supervisor
  #     └── Connection         :temporary, significant
  #
  # The supervisor passes its own pid (`self()` in `init/1`) as the
  # Connection's `parent_sup`; the Connection resolves its siblings from it.

  alias Raxol.AgentClientProtocol.{Connection, Session}

  @type init_arg :: {module(), term(), {module(), term()}}

  @spec init(:agent | :client, init_arg()) :: {:ok, tuple()}
  def init(role, {handler, handler_arg, transport}) do
    connection = %{
      id: Connection,
      start:
        {Connection, :start_link,
         [
           [
             role: role,
             transport: transport,
             handler: handler,
             handler_arg: handler_arg,
             parent_sup: self()
           ]
         ]},
      restart: :temporary,
      significant: true
    }

    Supervisor.init(Session.Supervisor.child_specs() ++ [connection],
      strategy: :one_for_all,
      auto_shutdown: :any_significant
    )
  end

  # One-shot: the subtree shuts down when the Connection exits and is not
  # restarted; recovery is a fresh reattach.
  @spec child_spec(module(), term(), keyword()) :: Supervisor.child_spec()
  def child_spec(sup_mod, default_id, opts) do
    init_arg =
      {Keyword.fetch!(opts, :handler), Keyword.get(opts, :handler_arg),
       Keyword.fetch!(opts, :transport)}

    %{
      id: Keyword.get(opts, :id, default_id),
      start: {sup_mod, :start_link, [init_arg, Keyword.take(opts, [:name])]},
      type: :supervisor,
      restart: :temporary
    }
  end

  @spec start_link(module(), module(), keyword()) :: Supervisor.on_start()
  def start_link(sup_mod, handler, opts) do
    init_arg = {handler, Keyword.get(opts, :handler_arg), Keyword.fetch!(opts, :transport)}
    sup_mod.start_link(init_arg, Keyword.take(opts, [:name]))
  end

  @spec connection(pid()) :: {:ok, pid()} | {:error, :not_found}
  def connection(sup) do
    sup
    |> Supervisor.which_children()
    |> Enum.find_value({:error, :not_found}, fn
      {_id, pid, _type, mods} when is_pid(pid) and is_list(mods) ->
        if Connection in mods, do: {:ok, pid}

      _ ->
        nil
    end)
  end
end
