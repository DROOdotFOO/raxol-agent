defmodule Raxol.Payments.Actions.Payments.ListHistory do
  @moduledoc """
  Agent Action that lists the agent's most recent ledger entries (20 by
  default) with amount, currency, time, domain, protocol and transaction hash.
  With no `:ledger` in the context it returns an empty list.
  """

  @compile {:no_warn_undefined, Raxol.Agent.Action}

  use Raxol.Agent.Action,
    name: "payment_list_history",
    description: "List recent payment history",
    schema: [
      input: [
        limit: [type: :integer, description: "Max entries to return (default: 20)"]
      ]
    ]

  alias Raxol.Payments.Ledger

  @spec run(map(), map()) :: {:ok, map()} | {:error, term()}
  @impl true
  def run(params, context) do
    case Map.get(context, :ledger) do
      nil ->
        {:ok, %{entries: [], count: 0}}

      ledger ->
        agent_id = Map.get(context, :agent_id, :unknown)
        limit = Map.get(params, :limit, 20)
        entries = Ledger.get_history(ledger, agent_id, limit: limit)

        formatted =
          Enum.map(entries, fn entry ->
            %{
              amount: Decimal.to_string(entry.amount),
              currency: entry.currency,
              timestamp: entry.timestamp_ms,
              domain: Map.get(entry.metadata, :domain, "unknown"),
              protocol: Map.get(entry.metadata, :protocol, "unknown"),
              tx_hash: Map.get(entry.metadata, :tx_hash)
            }
          end)

        {:ok, %{entries: formatted, count: length(formatted)}}
    end
  end
end
