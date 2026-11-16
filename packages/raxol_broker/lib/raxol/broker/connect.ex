defmodule Raxol.Broker.Connect do
  @moduledoc """
  What `mix raxol.broker.connect` checks once signed in: the tools the
  server serves against the frozen capture (`Raxol.Broker.Tools.Catalog.drift/1`),
  and the account pin (`Raxol.Broker.AccountPin`). An order or review tool
  that was added or changed is refused by the executor until the capture is
  refreshed (`mix raxol.broker.capture_tools`).
  """

  alias Raxol.Broker.{AccountPin, Response}
  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Tools.Catalog

  @doc """
  Report lines for the session `client`, or `{:error, reason}`. With
  `account`, `{:error, {:account_pin, _}}` unless `get_accounts` marks it
  as the one agentic account; without, the agentic account is named.
  """
  @spec report(GenServer.server(), String.t() | nil) :: {:ok, [String.t()]} | {:error, term()}
  def report(client, account \\ nil) do
    with {:ok, _read} <- Client.list_tools(client),
         {:ok, live} <- Client.live_tools(client),
         accounts = Response.body(Client.call(client, "get_accounts", %{})),
         {:ok, pin} <- pin(accounts, account) do
      {:ok, ["connected: #{length(live)} tools served", pin | drift_lines(Catalog.drift(live))]}
    end
  end

  defp pin(accounts, nil) do
    case accounts do
      {:ok, body} -> {:ok, "agentic account: #{Enum.join(AccountPin.agentic(body), ", ")}"}
      {:error, reason} -> {:error, {:account_pin, {:unreadable, reason}}}
    end
  end

  defp pin(accounts, account) do
    with :ok <- AccountPin.check(accounts, account),
         do: {:ok, "account #{account} is the agentic account"}
  end

  defp drift_lines(%{added: [], changed: [], missing: []}),
    do: ["no drift from the capture"]

  defp drift_lines(drift) do
    for {label, names} <- [added: drift.added, changed: drift.changed, missing: drift.missing],
        names != [] do
      "#{label}: " <> Enum.map_join(names, ", ", &with_class/1)
    end
  end

  defp with_class(name), do: "#{name} (#{Catalog.classify(name)})"
end
