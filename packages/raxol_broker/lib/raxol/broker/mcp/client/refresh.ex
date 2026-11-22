defmodule Raxol.Broker.MCP.Client.Refresh do
  @moduledoc false

  # The token-refresh work `Raxol.Broker.MCP.Client` runs in a task, and the
  # timing of the next proactive refresh.

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Agent.Auth.Robinhood
  alias Raxol.Broker.CredentialStore
  alias Raxol.Broker.MCP.Client.{Backoff, State}

  @type result ::
          {:ok, Credential.t()}
          | {:unpersisted, Credential.t(), term()}
          | {:error, term()}

  @doc """
  The refresh to run in a task. The persist happens inside it, before the
  result reaches the client: a rotated credential is never used before it
  is on disk. A credential that refreshed but failed to persist is kept
  (the old refresh token is spent) and the next attempt only retries the
  write.
  """
  @spec work(State.t()) :: (-> result())
  def work(%State{unpersisted: %Credential{} = pending, config: config}),
    do: fn -> persist(pending, config.store) end

  def work(%State{credential: credential, config: config}) do
    fn ->
      case Robinhood.refresh(credential, config.auth) do
        {:ok, rotated} -> persist(rotated, config.store)
        {:error, reason} -> {:error, reason}
      end
    end
  end

  defp persist(credential, store_opts) do
    case CredentialStore.put(credential, store_opts) do
      :ok -> {:ok, credential}
      {:error, reason} -> {:unpersisted, credential, reason}
    end
  end

  @doc """
  Milliseconds until a refresh `skew` seconds before the credential
  expires, or nil when it has no expiry.
  """
  @spec delay(Credential.t(), non_neg_integer(), DateTime.t()) :: non_neg_integer() | nil
  def delay(%Credential{expires_at: nil}, _skew, _now), do: nil

  def delay(%Credential{expires_at: %DateTime{} = at}, skew, now) do
    at
    |> DateTime.add(-skew, :second)
    |> DateTime.diff(now, :millisecond)
    |> max(0)
    |> min(Backoff.max_timer_ms())
  end

  @spec expired?(Credential.t()) :: boolean()
  def expired?(credential), do: Credential.expired?(credential, DateTime.utc_now(), 0)
end
