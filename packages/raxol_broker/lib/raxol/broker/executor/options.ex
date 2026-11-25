defmodule Raxol.Broker.Executor.Options do
  @moduledoc false

  alias Raxol.Broker.{Journal, PolicyFile}

  @default_timeout 30_000
  @default_reconnect_ms 1_000
  # `receive after` and `Process.send_after/3` refuse anything above
  # 4_294_967_295 ms; the cap leaves headroom under that.
  @max_timeout 4_294_000_000
  # What a stopping supervisor waits beyond one place call.
  @shutdown_headroom 5_000

  @type t :: %{
          journal: atom() | pid(),
          clock: (-> DateTime.t()),
          account: String.t(),
          policy: keyword(),
          session: keyword(),
          review_timeout: pos_integer(),
          place_timeout: pos_integer(),
          reconnect_ms: pos_integer()
        }

  @spec default_timeout() :: pos_integer()
  def default_timeout, do: @default_timeout

  @spec max_timeout() :: pos_integer()
  def max_timeout, do: @max_timeout

  @doc """
  The executor's start options, checked by pattern matching only.

  `:journal` comes first: a `{:via, module, name}` or `{:global, name}`
  would run caller code in the executor to resolve it.
  """
  @spec check(keyword()) :: {:ok, t()} | {:error, term()}
  def check(opts) do
    with {:ok, journal} <- fetch_journal(opts),
         {:ok, timeouts} <- fetch_timeouts(opts),
         {:ok, clock} <- fetch_clock(opts),
         :ok <- check_mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, account} <- fetch_account(opts),
         {:ok, policy} <- fetch_policy(opts),
         {:ok, session} <- fetch_session(opts) do
      {:ok,
       Map.merge(timeouts, %{
         journal: journal,
         clock: clock,
         account: account,
         policy: policy,
         session: session
       })}
    end
  end

  @doc """
  The child spec's shutdown bound: `:shutdown`, else `place_timeout + 5_000`.
  A `:shutdown` that is not a positive integer raises `ArgumentError`.
  """
  @spec shutdown(keyword()) :: pos_integer()
  def shutdown(opts) do
    case Keyword.fetch(opts, :shutdown) do
      {:ok, ms} when is_integer(ms) and ms > 0 ->
        ms

      {:ok, other} ->
        raise ArgumentError,
              "invalid :shutdown #{inspect(other, structs: false)}, expected a positive integer"

      :error ->
        place_shutdown(Keyword.get(opts, :place_timeout))
    end
  end

  defp place_shutdown(ms) when is_integer(ms) and ms > 0 and ms <= @max_timeout,
    do: ms + @shutdown_headroom

  defp place_shutdown(_unset_or_refused), do: @default_timeout + @shutdown_headroom

  defp fetch_timeouts(opts) do
    with {:ok, review_timeout} <- fetch_timeout(opts, :review_timeout),
         {:ok, place_timeout} <- fetch_timeout(opts, :place_timeout),
         {:ok, reconnect_ms} <- fetch_timeout(opts, :reconnect_ms, @default_reconnect_ms) do
      {:ok,
       %{review_timeout: review_timeout, place_timeout: place_timeout, reconnect_ms: reconnect_ms}}
    end
  end

  defp fetch_journal(opts) do
    case Keyword.get(opts, :journal, Journal) do
      journal when (is_atom(journal) and not is_nil(journal)) or is_pid(journal) ->
        {:ok, journal}

      other ->
        {:error, {:invalid_journal, other}}
    end
  end

  defp fetch_timeout(opts, key, default \\ @default_timeout) do
    case Keyword.get(opts, key, default) do
      ms when is_integer(ms) and ms > 0 and ms <= @max_timeout -> {:ok, ms}
      other -> {:error, {:invalid_timeout, key, other}}
    end
  end

  defp fetch_clock(opts) do
    case Keyword.get(opts, :clock, &DateTime.utc_now/0) do
      clock when is_function(clock, 0) -> {:ok, clock}
      other -> {:error, {:invalid_clock, other}}
    end
  end

  defp check_mode(:dry_run), do: :ok
  defp check_mode(:armed), do: {:error, :not_armed}
  defp check_mode(other), do: {:error, {:invalid_mode, other}}

  defp fetch_account(opts) do
    case Keyword.get(opts, :account_number) do
      account when is_binary(account) and account != "" -> {:ok, account}
      other -> {:error, {:invalid_account_number, other}}
    end
  end

  defp fetch_policy(opts) do
    case PolicyFile.validate(Keyword.get(opts, :policy)) do
      {:ok, policy} -> {:ok, policy}
      {:error, reason} -> {:error, {:invalid_policy, reason}}
    end
  end

  defp fetch_session(opts) do
    case Keyword.get(opts, :session) do
      spec when is_list(spec) and spec != [] -> {:ok, spec}
      _ -> {:error, :session_required}
    end
  end
end
