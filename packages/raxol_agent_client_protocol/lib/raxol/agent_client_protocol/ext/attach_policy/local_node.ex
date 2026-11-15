defmodule Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode do
  @moduledoc """
  The DEFAULT deny-by-default attach policy.

  Grants iff the attach arrives over a transport that implies OS-level
  co-residency; denies everything else — including a **nil / absent** transport
  (fail-closed: if the Connection didn't say where the peer is, we do not guess).

  ```
  authorize_attach(ctx):
    case ctx.transport do
      %{kind: :process} -> {:ok, grant(via: :local_node)}   # in-BEAM paired transport
      %{kind: :stdio}   -> {:ok, grant(via: :local_node)}   # pipe to a co-resident process
      _other_or_nil     -> {:error, :not_local}             # tcp, websocket, unknown, ABSENT
    end
  ```

  `ctx.transport` is **Connection-sourced only** and NEVER peer-asserted, so a
  network peer cannot present as `kind: :process` to steal a local grant.
  LocalNode never reads `ctx.capability` (a token sent here is ignored, not an
  error — stock-client compatibility).

  Every LocalNode grant carries the same actor,
  `%{"id" => "local", "kind" => "local_node"}`. A `ctx.actor` is not used:
  under this policy nothing authenticates it, and a handler may have taken
  it from the peer.

  **Why this is not a hole:** anyone who can present a co-resident transport can
  already read the journal files directly; the token would add zero security
  against that principal. LocalNode refuses a *network listener* transport,
  which is the actual attacker.
  """

  @behaviour Raxol.AgentClientProtocol.Ext.AttachPolicy

  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.Grant

  @local_actor %{"id" => "local", "kind" => "local_node"}

  @impl true
  @spec authorize_attach(map()) :: {:ok, Grant.t()} | {:error, :not_local}
  def authorize_attach(ctx) when is_map(ctx) do
    case Map.get(ctx, :transport) do
      %{kind: :process} -> {:ok, grant(ctx)}
      %{kind: :stdio} -> {:ok, grant(ctx)}
      _other_or_nil -> {:error, :not_local}
    end
  end

  @spec grant(map()) :: Grant.t()
  defp grant(ctx) do
    %Grant{
      actor: @local_actor,
      scope: :attach,
      session_id: Map.get(ctx, :session_id),
      via: :local_node,
      expires_at: nil,
      lens: nil
    }
  end
end
