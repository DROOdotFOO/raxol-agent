defmodule Raxol.Broker.Session do
  @moduledoc """
  The Robinhood session both broker connections share: the endpoint, the
  `Raxol.MCP.Client` spec for a credential, and the token refresh.

  Robinhood rotates the refresh token on every refresh, so two connections
  refreshing the same stored credential on their own would spend each
  other's token. `refresh/3` runs under one VM-wide lock and re-reads the
  store first: when another connection already stored a newer credential,
  that one is returned and no request is made. Otherwise the refresh grant
  runs and the rotated credential is stored before it is returned.
  """

  alias Raxol.Agent.Auth.{Credential, Robinhood}
  alias Raxol.Broker.CredentialStore

  @url "https://agent.robinhood.com/mcp/trading"

  @doc "Robinhood's trading MCP endpoint."
  @spec url() :: String.t()
  def url, do: @url

  @doc """
  A `Raxol.MCP.Client` spec for `credential`: `extra` (its own `:url` wins,
  e.g. a sandbox), the legacy era Robinhood speaks, pooled concurrency, and
  the bearer header. A legacy session defaults to one request in flight;
  Robinhood's own tool descriptions call for parallel calls on one session,
  and the kill switch sends its cancels in parallel.
  """
  @spec spec(Credential.t(), keyword()) :: keyword()
  def spec(%Credential{} = credential, extra \\ []) do
    headers = [
      {"authorization", Credential.bearer(credential)} | Keyword.get(extra, :headers, [])
    ]

    extra
    |> Keyword.put_new(:url, @url)
    |> Keyword.put_new(:era, :legacy)
    |> Keyword.put_new(:concurrency, :pooled)
    |> Keyword.put(:headers, headers)
  end

  @doc """
  Refresh `credential` (see the moduledoc). `{:ok, credential}`,
  `{:unpersisted, credential, reason}` when the rotated credential could not
  be stored (the old refresh token is spent), or `{:error, reason}`.
  """
  @spec refresh(Credential.t(), keyword(), keyword()) ::
          {:ok, Credential.t()} | {:unpersisted, Credential.t(), term()} | {:error, term()}
  def refresh(%Credential{} = credential, store_opts, auth_opts) do
    lock = {{__MODULE__, :refresh}, self()}
    :global.trans(lock, fn -> locked_refresh(credential, store_opts, auth_opts) end, [node()])
  end

  defp locked_refresh(credential, store_opts, auth_opts) do
    case CredentialStore.fetch(store_opts) do
      {:ok, stored} when stored.access_token != credential.access_token ->
        if Credential.expired?(stored, DateTime.utc_now(), 0),
          do: grant(stored, store_opts, auth_opts),
          else: {:ok, stored}

      _same_or_unreadable ->
        grant(credential, store_opts, auth_opts)
    end
  end

  defp grant(credential, store_opts, auth_opts) do
    with {:ok, rotated} <- Robinhood.refresh(credential, auth_opts) do
      case CredentialStore.put(rotated, store_opts) do
        :ok -> {:ok, rotated}
        {:error, reason} -> {:unpersisted, rotated, reason}
      end
    end
  end
end
