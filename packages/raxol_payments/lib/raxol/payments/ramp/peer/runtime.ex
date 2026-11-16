defmodule Raxol.Payments.Ramp.Peer.Runtime do
  @moduledoc "Supervised default maker I/O resources; starting it performs no network or wallet action."
  use Supervisor
  alias Raxol.Payments.Ramp.Peer.{Indexer, Mapping}
  def start_link(opts), do: Supervisor.start_link(__MODULE__, opts)
  @impl true
  def init(opts) do
    Supervisor.init(
      [
        {Mapping,
         path: Keyword.fetch!(opts, :mapping_path), name: Keyword.fetch!(opts, :mapping_name)},
        {Indexer, Keyword.take(opts, [:req_options, :now])}
      ],
      strategy: :one_for_one
    )
  end

  @doc "Attach concrete resources to the existing payment context, preserving injected behaviours."
  def context(supervisor, context) do
    children = Supervisor.which_children(supervisor)
    {Mapping, mapping, _, _} = List.keyfind(children, Mapping, 0)
    {Indexer, indexer, _, _} = List.keyfind(children, Indexer, 0)
    context |> Map.put(:maker_mapping, mapping) |> Map.put(:maker_indexer, indexer)
  end
end
