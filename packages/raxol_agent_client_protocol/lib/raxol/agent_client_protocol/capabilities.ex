defmodule Raxol.AgentClientProtocol.Capabilities do
  @moduledoc """
  Decides whether a gated method is negotiated, against the receiver's own
  capability snapshot: an agent checks the `AgentCapabilities` it sent in its
  `initialize` response, a client the `ClientCapabilities` it sent in its
  `initialize` request. `MethodTable` says which methods are gated by which
  field path.

  Fails closed: only a truthy leaf (`true` or a present nested struct/map) is
  negotiated. A missing field, `nil`/`false` leaf, `nil` snapshot or `:never`
  gate is not, and the Connection answers `-32601` before decoding. Ungated and
  unknown methods are never denied here.
  """

  alias Raxol.AgentClientProtocol.MethodTable

  @doc """
  Is `method` negotiated given the receiver's own capability snapshot `caps`?

  `caps` is the snapshotted `AgentCapabilities` / `ClientCapabilities` struct
  (or `nil` pre-handshake). Pure and total — never raises, even for a `nil` or
  malformed snapshot (both resolve to "not negotiated" for a gated method).
  """
  @spec negotiated?(term(), String.t()) :: boolean()
  def negotiated?(caps, method) when is_binary(method) do
    case MethodTable.capability_for(method) do
      # Baseline method, or a method not in the table (decode -32601s it): a
      # capability gate must not deny it — only the caps-gated rows can deny.
      :none -> true
      :unknown_method -> true
      # Oracle-gated by a capability the ported struct cannot express.
      :never -> false
      {_side, path} -> resolve(caps, path)
    end
  end

  # Walk the field path. Each step must land on a map/struct to descend; the
  # first non-map (a missing/`nil` intermediate) halts to `nil`. Only the FINAL
  # leaf's truthiness decides — a present intermediate struct is truthy but we
  # keep walking. `Map.get/2` reads struct fields by atom key without creating
  # atoms (the path atoms are compile-time literals from `MethodTable`).
  defp resolve(caps, path) do
    path
    |> Enum.reduce_while(caps, fn segment, acc ->
      case acc do
        %{} = map -> {:cont, Map.get(map, segment)}
        _ -> {:halt, nil}
      end
    end)
    |> truthy?()
  end

  defp truthy?(nil), do: false
  defp truthy?(false), do: false
  defp truthy?(_present), do: true
end
