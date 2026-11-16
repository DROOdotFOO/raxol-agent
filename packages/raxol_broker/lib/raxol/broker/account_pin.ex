defmodule Raxol.Broker.AccountPin do
  @moduledoc """
  The account pin: the broker trades one account, and it must be the one
  Robinhood marks `agentic_allowed: true` in `get_accounts` (Robinhood says
  exactly one is). Checked when arming, when `mix raxol.broker.connect` is
  given an account, and every time the executor's session connects; a
  session that fails it never becomes ready.
  """

  alias Raxol.Broker.Response

  @type refusal ::
          {:account_pin,
           :no_agentic_account
           | :several_agentic_accounts
           | {:not_the_agentic_account, String.t()}
           | {:unreadable, term()}}

  @doc """
  Check a `get_accounts` answer (`{:ok, body}` as `Raxol.Broker.Response.body/1`
  gives it, or `{:error, reason}`) against `account`.
  """
  @spec check({:ok, map() | list()} | {:error, term()}, String.t()) :: :ok | {:error, refusal()}
  def check({:ok, body}, account) when is_binary(account) do
    case agentic(body) do
      [^account] -> :ok
      [] -> {:error, {:account_pin, :no_agentic_account}}
      [other] -> {:error, {:account_pin, {:not_the_agentic_account, other}}}
      _several -> {:error, {:account_pin, :several_agentic_accounts}}
    end
  end

  def check({:error, reason}, _account), do: {:error, {:account_pin, {:unreadable, reason}}}

  @doc "The account numbers `get_accounts` marks `agentic_allowed: true`."
  @spec agentic(map() | list()) :: [String.t()]
  def agentic(body) do
    for %{"agentic_allowed" => true, "account_number" => number} <-
          Response.list(body, ["accounts", "results"]),
        is_binary(number),
        do: number
  end
end
