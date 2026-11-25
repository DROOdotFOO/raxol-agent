defmodule Raxol.Earn.Xochi.SolverAgent.Reattach do
  @moduledoc false
  # Rebuilds a `Raxol.Earn.Xochi.SolverAgent` session lost to a restart between
  # setBudget and fund. The live SSE stream never replays earlier entries, so a
  # funded job with no in-memory session is recovered from the ACP job history.
  #
  # Fails closed: no session is returned unless the history names this solver as
  # provider, carries a valid requirement, the intent resolves on Xochi, and the
  # job reads EXACTLY funded on-chain. Reattach never invents a settlement.

  alias Raxol.Earn.{Agent, ProviderAdapter}
  alias Raxol.Earn.Transport.SSE.Parser
  alias Raxol.Earn.Xochi.{IntentDeriver, SolverAgent}
  alias Raxol.Earn.Xochi.SolverAgent.Requirement

  require Logger

  # AgenticCommerceV3 JobStatus for a funded job, verified on Base mainnet.
  @onchain_status_funded 1

  @doc false
  # Called only from `SolverAgent` on a funded event with no live session.
  @spec rebuild(map(), Raxol.Earn.Transport.job_key(), SolverAgent.t()) ::
          {:ok, SolverAgent.session_state()} | {:error, term()}
  def rebuild(entry, key, state) do
    with {:ok, session} <- rebuild_session(entry, key, state),
         :ok <- confirm_funded_onchain(state, key, session) do
      {:ok, session}
    end
  end

  # `job.funded` is the trusted trigger, but reattach fires for a job this
  # process has no record of, so the on-chain status is read before spending.
  # Below funded the event was premature; past funded the job already settled.
  # An unreadable status fails closed too.
  defp confirm_funded_onchain(state, key, %{job_id_uint: job_id_uint}) do
    case job_status_onchain(state, job_id_uint) do
      {:ok, @onchain_status_funded} ->
        :ok

      {:ok, other} ->
        Logger.warning(
          "[xochi.solver] reattach #{inspect(key)}: on-chain status #{inspect(other)} != funded; not settling"
        )

        {:error, {:not_funded_onchain, other}}

      {:error, reason} ->
        {:error, {:job_status_unavailable, reason}}
    end
  end

  defp job_status_onchain(state, job_id_uint) do
    params = %{
      address: state.acp_core_address,
      signature: "getJob(uint256)",
      args: [{"uint256", job_id_uint}]
    }

    with {:ok, raw} <- ProviderAdapter.read_contract(state.provider, state.chain_id, params) do
      decode_job_status(raw)
    end
  end

  # getJob(uint256) -> (client, status, provider, expiredAt, evaluator, hook,
  # budget, description): a dynamic-struct return, so a leading offset word
  # precedes the head and `status` is word 2. An integer is a canned mock read.
  defp decode_job_status(status) when is_integer(status) and status >= 0, do: {:ok, status}

  defp decode_job_status("0x" <> hex) do
    case Base.decode16(hex, case: :mixed) do
      {:ok, <<_::binary-size(2 * 32), status::unsigned-big-integer-size(256), _::binary>>} ->
        {:ok, status}

      _ ->
        {:error, :undecodable_job_status}
    end
  end

  defp decode_job_status(other), do: {:error, {:unexpected_job_status, other}}

  defp rebuild_session(entry, key, state) do
    with {:ok, entries} <- fetch_history(state, key),
         normalized = Enum.map(entries, &Parser.normalize/1),
         :ok <- confirm_provider(normalized, state),
         {:ok, requirement} <- requirement_from_history(normalized),
         {:ok, %{from_amount: transfer_atomic}} <-
           IntentDeriver.resolve(state.xochi_config, requirement) do
      {:ok, reattached_session(entry, key, requirement, transfer_atomic)}
    else
      # IntentDeriver answers {:reject, _} as well as {:error, _}.
      {_reject_or_error, reason} -> {:error, reason}
    end
  end

  defp reattached_session(entry, {chain_id, job_id}, requirement, transfer_atomic) do
    id = entry["jobId"] || job_id

    %{
      job_id: id,
      chain_id: entry["chainId"] || chain_id,
      job_id_uint: Requirement.job_id_uint(id),
      status: :awaiting_fund,
      requirement: requirement,
      transfer_amount_atomic: transfer_atomic
    }
  end

  defp fetch_history(%{history_fn: history_fn}, key) when is_function(history_fn, 1),
    do: history_fn.(key)

  defp fetch_history(state, key), do: Agent.get_history(state.agent, key)

  # The provider comes from the historical `job.created` entry, not the funded
  # event, which may not carry it.
  defp confirm_provider(entries, state) do
    case Enum.find(entries, &match?(%{"kind" => "system", "event" => "job.created"}, &1)) do
      %{"provider" => provider} when is_binary(provider) ->
        if Requirement.normalize_address(provider) == state.wallet_address,
          do: :ok,
          else: {:error, :not_our_job}

      _ ->
        {:error, :no_created_in_history}
    end
  end

  # The last valid `requirement` message carries the signed intent bundle.
  defp requirement_from_history(entries) do
    entries
    |> Enum.reverse()
    |> Enum.find_value({:error, :no_requirement_in_history}, &valid_requirement/1)
  end

  defp valid_requirement(%{"kind" => "message", "contentType" => "requirement", "content" => c}) do
    case Requirement.decode(c) do
      {:ok, requirement} -> {:ok, requirement}
      {:error, _} -> nil
    end
  end

  defp valid_requirement(_entry), do: nil
end
