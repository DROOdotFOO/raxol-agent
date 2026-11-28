defmodule Raxol.Web3.Router do
  @moduledoc """
  Resolves a chain reference and a callback to a backend, in health order, with
  failover.

  ADR-0033 decision 3: each chain has a primary and at least one fallback.

  ## Health

  Health is gated by `Raxol.MCP.CircuitBreaker` inside `Raxol.Web3.HTTP`. This
  module reads the verdict through `Backend.health_key/1` to order candidates and
  never records outcomes itself (that would double-count failures). An open
  breaker demotes a backend to last rather than removing it.

  ## Per callback

  A backend is a candidate only if it declares and exports the callback
  (`Backend.supports?/2`). `coverage/2` reports which callbacks currently have a
  healthy source.

  ## Failover vs final

  Errors about the SOURCE fail over: an open breaker, transport failure,
  timeout, DNS failure, rate limit, an unhealthy status, an undecodable body, a
  too-large response, and:

    * `{:upstream_refused, :auth}` / `{:upstream_refused, :rate_limit}` -- a
      credential this deployment lacks is a fact about the source (a withdrawn
      key prefix can answer healthy 404s, so health alone will not move on).
    * `{:unsupported_chain, _}` -- this source does not serve the chain; decided
      on a read because some upstreams resolve their network set at runtime.
    * `{:source_unavailable, _}` -- an endpoint the source must serve is gone.

  Errors about the QUESTION are final, since another source would give the same
  answer: `{:upstream_refused, :not_found}`, `{:upstream_refused, :unknown}`,
  `{:unsupported_account_ref, _}`, `{:unsupported, _}`,
  `{:blocked, :invalid_url}` and `{:invalid_cursor, _}`.

  ## Which error a failed walk reports

  The walk ends on a final error, or on the last candidate's. What the caller
  is told is not always that error, because an error from a later source can
  be about that source rather than the question:

    1. An answer that does not depend on the source stands, whichever source
       gave it: `{:upstream_refused, :not_found}`, `{:unsupported_account_ref,
       _}` (decided by the chain's address family) and `{:missing_argument,
       _}`.
    2. Otherwise, after a failover, the caller is told the FIRST source fault
       in walk order, skipping `{:breaker_open, _}` unless every fault is one:
       an open breaker is a fact about earlier calls, not this one. A bare
       status the backend could not classify, an unclassified refusal, or a
       reason only that source would give (`{:invalid_cursor, _}` for a cursor
       another source minted, `{:unsupported, _}`, `{:invalid_argument, _}`
       from its own path rules, `{:blocked, :invalid_url}`) does not stand in
       for it. Last-wins told a client "Check the arguments" for a 400 from a
       fallback when the primary had timed out, and hid that timeout from the
       tool's breaker, which reads a 400 as an answer.
    3. With no failover, the one source asked answered, and its error stands.

  ## Paging walks are pinned

  A cursor carries the origin that minted it (`Raxol.Web3.Cursor`), so
  `{:invalid_cursor, _}` is terminal: failing over mid-walk would return the
  second backend's first page labelled as page two. An interrupted walk gets an
  error and restarts.
  """

  require Logger

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Tables

  @enforce_keys [:chains]
  defstruct chains: %{}, breaker: []

  @type t :: %__MODULE__{
          chains: %{Backend.chain_ref() => [Backend.t()]},
          breaker: keyword()
        }

  @doc """
  Build a router from an ordered list of handles.

  Declaration order is preference order, per chain: the first handle that
  declares a chain is that chain's primary. A handle that declares several
  chains takes its place in each of their orders.

  `:breaker` is forwarded to `Raxol.MCP.CircuitBreaker.check/3`, so a
  deployment can widen the recovery window without touching the outbound path.
  """
  @spec new([Backend.t()], keyword()) :: t()
  def new(handles, opts \\ []) when is_list(handles) do
    %__MODULE__{chains: index(handles), breaker: Keyword.get(opts, :breaker, [])}
  end

  # Prepend then reverse, rather than append: declaration order is the whole
  # meaning of this list, so it is restored once at the end instead of being
  # rebuilt per handle.
  defp index(handles) do
    handles
    |> Enum.reduce(%{}, fn {module, state} = handle, acc ->
      Enum.reduce(module.supported_chain_ids(state), acc, fn chain_ref, acc ->
        Map.update(acc, chain_ref, [handle], &[handle | &1])
      end)
    end)
    |> Map.new(fn {chain_ref, for_chain} -> {chain_ref, Enum.reverse(for_chain)} end)
  end

  @doc "The chains this router can route, in no particular order."
  @spec chains(t()) :: [Backend.chain_ref()]
  def chains(%__MODULE__{chains: chains}), do: Map.keys(chains)

  @doc """
  The candidates for one callback on one chain, healthy first.

  Exposed because "why did that go to the fallback" is a question an operator
  asks, and answering it by reading the router's source is worse than asking
  the router.
  """
  @spec candidates(t(), Backend.chain_ref(), atom()) :: [Backend.t()]
  def candidates(%__MODULE__{} = router, chain_ref, callback) do
    router.chains
    |> Map.get(chain_ref, [])
    |> Enum.filter(&answers?(&1, callback))
    |> order_by_health(router.breaker)
  end

  @doc """
  What is answerable on a chain right now.

  A callback maps to the backends that declare it and are not open-breakered,
  in preference order. A callback absent from the map has no healthy source at
  this moment, which is the degradation ADR-0038 leaves open as a question and
  which is otherwise invisible until a caller gets an error.
  """
  @spec coverage(t(), Backend.chain_ref()) :: %{optional(atom()) => [atom()]}
  def coverage(%__MODULE__{} = router, chain_ref) do
    handles = Map.get(router.chains, chain_ref, [])

    for callback <- callbacks(),
        healthy = healthy_backends(handles, callback, router.breaker),
        healthy != [],
        into: %{} do
      {callback, healthy}
    end
  end

  @doc """
  Call a callback on the first candidate that can answer it.

  `{:error, :no_backend}` when the chain is not routed at all, and
  `{:error, {:unsupported, callback}}` when it is routed but nothing on it
  answers that callback: two different operator problems, so two different
  errors.
  """
  @spec call(t(), Backend.chain_ref(), atom(), [term()]) :: {:ok, term()} | {:error, term()}
  def call(%__MODULE__{} = router, chain_ref, callback, args \\ []) do
    case Map.get(router.chains, chain_ref) do
      nil -> {:error, :no_backend}
      _handles -> attempt(candidates(router, chain_ref, callback), callback, args)
    end
  end

  defp attempt(candidates, callback, args, first_fault \\ nil)

  defp attempt([], callback, _args, _first_fault), do: {:error, {:unsupported, callback}}

  defp attempt([handle | rest], callback, args, first_fault) do
    case Backend.call(handle, callback, args) do
      {:ok, _value} = ok ->
        ok

      {:error, reason} ->
        if rest != [] and failover?(reason) do
          log_failover(handle, callback, reason)
          attempt(rest, callback, args, earliest_fault(first_fault, reason))
        else
          {:error, reported(handle, callback, reason, first_fault)}
        end
    end
  end

  # The moduledoc's three rules, in order.
  defp reported(_handle, _callback, reason, nil), do: reason

  defp reported(handle, callback, reason, first_fault) do
    cond do
      source_independent?(reason) ->
        reason

      failover?(reason) ->
        earliest_fault(first_fault, reason)

      true ->
        Logger.debug(fn ->
          "raxol_web3: #{Backend.name(handle)} answered #{callback} " <>
            "(#{inspect(reason)}) after a failover; reporting #{inspect(first_fault)}"
        end)

        first_fault
    end
  end

  # The first fault in walk order, except that an open breaker gives way to
  # the first fault that came from a call actually made.
  defp earliest_fault(nil, reason), do: reason
  defp earliest_fault({:breaker_open, _} = first, {:breaker_open, _}), do: first
  defp earliest_fault({:breaker_open, _}, reason), do: reason
  defp earliest_fault(first, _reason), do: first

  defp source_independent?({:upstream_refused, :not_found}), do: true
  defp source_independent?({:unsupported_account_ref, _}), do: true
  defp source_independent?({:missing_argument, _}), do: true
  defp source_independent?(_reason), do: false

  # The reason, never the response: a failover decision is made from the error
  # tuple, which by construction carries no upstream text and names an origin
  # only by id.
  defp log_failover(handle, callback, reason) do
    Logger.debug(fn ->
      "raxol_web3: #{Backend.name(handle)} failed #{callback} (#{inspect(reason)}), failing over"
    end)
  end

  @source_errors [
    :breaker_open,
    :transport,
    :timeout,
    :dns_failed,
    :rate_limited,
    :too_large,
    :decode_failed,
    :unsupported_chain,
    :source_unavailable
  ]

  defp failover?({kind, _detail}) when kind in @source_errors, do: true
  # Only these two of the four refusal classes: a not-found is an answer about
  # the question, and a refusal we could not classify is not evidence that
  # another source would do better.
  defp failover?({:upstream_refused, class}), do: class in [:auth, :rate_limit]
  # The status policy is `Raxol.Web3.HTTP`'s, not a second copy of it: the
  # statuses that record a breaker failure there are the statuses worth
  # failing over from here, and two lists drift.
  defp failover?({:http, status}), do: HTTP.unhealthy_status?(status)
  defp failover?({:blocked, :address}), do: true
  defp failover?(_question), do: false

  defp answers?(handle, callback) do
    Keyword.has_key?(Backend.required(), callback) or Backend.supports?(handle, callback)
  end

  # `Backend.name/1`, not `module.backend()`: one module can carry several
  # upstreams (the Tron backend has three), and a coverage map reading
  # `[:tron, :tron, :tron]` tells an operator how many sources survive but not
  # which one dropped out, which is the whole question.
  defp healthy_backends(handles, callback, breaker_opts) do
    for handle <- handles,
        answers?(handle, callback),
        health(handle, breaker_opts) != :open,
        do: Backend.name(handle)
  end

  # A stable partition rather than a sort: within a health class, declaration
  # order is the operator's stated preference and must survive.
  defp order_by_health(handles, breaker_opts) do
    {healthy, open} = Enum.split_with(handles, &(health(&1, breaker_opts) != :open))
    healthy ++ open
  end

  defp health(handle, breaker_opts) do
    case Backend.health_key(handle) do
      nil -> :closed
      key -> CircuitBreaker.check(Tables.breakers(), key, breaker_opts)
    end
  end

  # Every callback, so `coverage/2` reports the whole surface. Everything except
  # chain identity and height sits in this list rather than in
  # `Backend.required/0` after ADR-0039: a read about a thing on the chain needs
  # an index over things of that kind, which a node does not have and an archive
  # has only over ranges, and a chain whose only source is partial is exactly
  # what coverage is for.
  defp callbacks do
    Keyword.keys(Backend.required()) ++
      [
        :get_transaction,
        :account_info,
        :list_transactions,
        :token_balances,
        :get_block,
        :list_token_transfers,
        :read_contract,
        :contract_metadata,
        :get_logs,
        :resolve_name,
        :list_nfts,
        :raw_request
      ]
  end
end
