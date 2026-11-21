defmodule Raxol.AgentClientProtocol.Connection.Dispatch do
  @moduledoc false
  # Runs handler callbacks in tasks on the Connection's Task.Supervisor.

  alias Raxol.AgentClientProtocol.Connection.Ctx
  alias Raxol.AgentClientProtocol.Router

  @spec ctx(map()) :: Ctx.t()
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

  # `async_nolink` raises once the supervisor hits `max_children`.
  @spec start(map(), term(), Ctx.t()) :: {:ok, Task.t()} | {:error, Exception.t()}
  def start(state, dispatchable, ctx) do
    {:ok, Task.Supervisor.async_nolink(state.task_sup, fn -> run(state, dispatchable, ctx) end)}
  rescue
    e -> {:error, e}
  end

  defp run(state, {:ext_request, wire, params}, ctx),
    do: state.handler.handle_ext_request(wire, params, ctx)

  defp run(state, {:ext_notification, wire, params}, ctx),
    do: state.handler.handle_ext_notification(wire, params, ctx)

  defp run(state, dispatchable, ctx),
    do: Router.dispatch(state.role, state.handler, dispatchable, ctx)
end
