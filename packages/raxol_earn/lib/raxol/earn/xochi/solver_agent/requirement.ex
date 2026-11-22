defmodule Raxol.Earn.Xochi.SolverAgent.Requirement do
  @moduledoc false
  # Pure decoding of ACP job entries shared by `Raxol.Earn.Xochi.SolverAgent`
  # and its reattach path: the buyer's requirement message, the on-chain job
  # id, and the address form provider checks compare.

  alias Raxol.Earn.Xochi.Offering

  @spec decode(term()) :: {:ok, map()} | {:error, atom()}
  def decode(content) when is_binary(content) do
    case Jason.decode(content) do
      {:ok, req} when is_map(req) ->
        if Offering.valid_requirement?(req), do: {:ok, req}, else: {:error, :invalid_requirement}

      _ ->
        {:error, :requirement_not_json}
    end
  end

  def decode(_), do: {:error, :requirement_missing}

  @spec job_id_uint(non_neg_integer() | String.t()) :: non_neg_integer()
  def job_id_uint(id) when is_integer(id), do: id

  def job_id_uint(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, _} -> n
      :error -> :erlang.phash2(id)
    end
  end

  @spec normalize_address(String.t()) :: String.t()
  def normalize_address(addr) when is_binary(addr), do: String.downcase(addr)
end
