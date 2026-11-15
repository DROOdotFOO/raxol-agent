defmodule Raxol.Broker.Executor.Read do
  @moduledoc """
  Read tools on the executor's own session: the context the policy needs
  (`Raxol.Broker.Policy.ContextBuilder`), the account pin, and the order
  and approval lists the kill switch and reconciliation work from.

  Only a tool the session's `Raxol.Broker.Tools.Catalog` classes say is
  `:read` is called; anything else is `{:error, {:tool_refused, tool,
  class}}` and nothing is sent. The answer is read with
  `Raxol.Broker.Response.body/1`.
  """

  alias Raxol.Broker.Executor.Port
  alias Raxol.Broker.Response
  alias Raxol.Broker.Tools.Catalog

  @doc "Call read tool `tool` with `args`; `{:ok, body}` or `{:error, reason}`."
  @spec call(Port.t() | nil, Catalog.session(), String.t(), map(), timeout()) ::
          {:ok, map() | list()} | {:error, term()}
  def call(port, catalog, tool, args, timeout) do
    with :ok <- Catalog.permit(catalog, tool, :read),
         do: Response.body(Port.call(port, tool, args, timeout))
  end
end
