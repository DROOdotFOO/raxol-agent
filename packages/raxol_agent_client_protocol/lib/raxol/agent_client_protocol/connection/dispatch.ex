defmodule Raxol.AgentClientProtocol.Connection.Dispatch do
  @moduledoc false
  # Runs handler callbacks in tasks on the Connection's Task.Supervisor.

  alias Raxol.AgentClientProtocol.Connection.Ctx
  alias Raxol.AgentClientProtocol.Router

  @spec ctx(Raxol.AgentClientProtocol.Connection.t()) :: Ctx.t()
  def ctx(state) do
    %Ctx{
      conn: self(),
      role: state.role,
      caps: state.caps,
      handler_state: state.handler_state,
      session_sup: state.session_sup,
      task_sup: state.task_sup
    }
  end

  # `async_nolink` raises once the request supervisor hits `max_children` (the
  # notification supervisor has none; `NotificationPool` bounds it).
  @spec start(Raxol.AgentClientProtocol.Connection.t(), term(), Ctx.t(), pid() | nil) ::
          {:ok, Task.t()} | {:error, Exception.t()}
  def start(state, dispatchable, ctx, sup \\ nil) do
    # Capture only what the task needs, not the whole Connection state.
    %{role: role, handler: handler} = state

    {:ok,
     Task.Supervisor.async_nolink(sup || state.task_sup, fn ->
       run(role, handler, dispatchable, ctx)
     end)}
  rescue
    e -> {:error, e}
  end

  defp run(_role, handler, {:ext_request, wire, params}, ctx),
    do: handler.handle_ext_request(wire, params, ctx)

  defp run(_role, handler, {:ext_notification, wire, params}, ctx),
    do: handler.handle_ext_notification(wire, params, ctx)

  defp run(role, handler, dispatchable, ctx),
    do: Router.dispatch(role, handler, dispatchable, ctx)
end
