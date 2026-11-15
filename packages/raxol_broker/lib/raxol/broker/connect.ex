defmodule Raxol.Broker.Connect do
  @moduledoc """
  What `mix raxol.broker.connect` checks once signed in: the tools the
  server serves against the frozen capture (`Raxol.Broker.Tools.Catalog.drift/1`).
  An order or review tool that was added or changed is refused by the
  executor until the capture is refreshed (`mix raxol.broker.capture_tools`).
  """

  alias Raxol.Broker.MCP.Client
  alias Raxol.Broker.Tools.Catalog

  @doc "Report lines for the session `client`, or `{:error, reason}`."
  @spec report(GenServer.server()) :: {:ok, [String.t()]} | {:error, term()}
  def report(client) do
    with {:ok, _read} <- Client.list_tools(client),
         {:ok, live} <- Client.live_tools(client) do
      {:ok, ["connected: #{length(live)} tools served" | drift_lines(Catalog.drift(live))]}
    end
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
