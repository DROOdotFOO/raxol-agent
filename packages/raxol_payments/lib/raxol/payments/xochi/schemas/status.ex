defmodule Raxol.Payments.Xochi.Schemas.Status do
  @moduledoc false
  # The intent lifecycle statuses the Xochi worker reports, parsed from wire
  # strings without minting atoms: unknown input reads as `:unknown`.

  @type t :: Raxol.Payments.Xochi.Schemas.IntentStatus.status()

  @statuses ~w(idle pending pull_pending quoting quoted signing executing bridging
               settling source_finalized completed refund_pending failed expired
               refunded unknown)a
  @by_name Map.new(@statuses, &{Atom.to_string(&1), &1})

  @spec parse(term()) :: t()
  def parse(name), do: Map.get(@by_name, name, :unknown)

  @doc "Parse `name`, reading any status outside `allowed` as `:unknown`."
  @spec parse(term(), [t()]) :: t()
  def parse(name, allowed) do
    status = parse(name)
    if status in allowed, do: status, else: :unknown
  end
end
