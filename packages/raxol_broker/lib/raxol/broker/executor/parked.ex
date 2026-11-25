defmodule Raxol.Broker.Executor.Parked do
  @moduledoc false

  alias Raxol.Broker.{Intent, Policy}
  alias Raxol.Broker.Executor.ReviewReceipt
  alias Raxol.Broker.Policy.Context

  @type prompts :: [{Policy.rule_id(), String.t()}]
  @type group :: %{
          intent: Intent.t(),
          context: Context.t(),
          receipt: ReviewReceipt.t(),
          prompts: prompts(),
          customer_approval_required: boolean(),
          seq: integer()
        }
  @type t :: %{optional(String.t()) => group()}

  @spec new() :: t()
  def new, do: %{}

  @doc "Park a reviewed group whose post-review verdict was ASK."
  @spec put(t(), String.t(), map(), ReviewReceipt.t(), prompts()) :: t()
  def put(parked, group_id, pending, receipt, prompts) do
    group = %{
      intent: pending.intent,
      context: pending.context,
      receipt: receipt,
      prompts: prompts,
      customer_approval_required: pending.customer_approval_required,
      seq: System.unique_integer([:monotonic])
    }

    Map.put(parked, group_id, group)
  end

  @doc "`[%{group_id, intent, prompts}]`, oldest first."
  @spec list(t()) :: [%{group_id: String.t(), intent: Intent.t(), prompts: prompts()}]
  def list(parked) do
    parked
    |> Enum.sort_by(fn {_id, group} -> group.seq end)
    |> Enum.map(fn {id, group} ->
      %{group_id: id, intent: group.intent, prompts: group.prompts}
    end)
  end

  @doc "`{:error, {:parked, group_id}}` when a group for `intent` is parked."
  @spec check_intent(t(), Intent.t()) :: :ok | {:error, {:parked, String.t()}}
  def check_intent(parked, %Intent{id: intent_id}) do
    case Enum.find(parked, fn {_id, group} -> group.intent.id == intent_id end) do
      nil -> :ok
      {id, _group} -> {:error, {:parked, id}}
    end
  end

  @spec fetch(t(), String.t()) :: {:ok, group()} | {:error, {:not_parked, String.t()}}
  def fetch(parked, token) do
    case Map.fetch(parked, token) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, {:not_parked, token}}
    end
  end

  @spec delete(t(), String.t()) :: t()
  def delete(parked, token), do: Map.delete(parked, token)

  @spec pop(t(), String.t()) :: {:ok, t()} | {:error, {:not_parked, String.t()}}
  def pop(parked, token) do
    case Map.pop(parked, token) do
      {nil, _parked} -> {:error, {:not_parked, token}}
      {_group, parked} -> {:ok, parked}
    end
  end
end
