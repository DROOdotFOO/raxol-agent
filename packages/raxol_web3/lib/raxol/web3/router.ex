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
    * `{:blocked, :invalid_url}` -- this source's base URL does not parse, so
      it refuses every read. A fact about its configuration: the operator is
      warned once per source, by name, and the walk moves on. The other
      `blocked` reasons are unchanged: `:address` fails over as before, and
      `:no_address`, `:not_an_address` and `:forbidden_transport_opts` are
      final. None of them can come from a request's own arguments, which reach
      a URL only through `Raxol.Web3.Backend.PathSegment` or a verified cursor.

  Every other error is FINAL: the walk stops there, whichever source gave it.
  Final is not the same as "about the question". Three final reasons are
  answers any source would give: `{:upstream_refused, :not_found}`,
  `{:unsupported_account_ref, _}` (decided by the chain's address family) and
  `{:missing_argument, _}`. The rest are about the one source that gave them:
  `{:invalid_cursor, _}`, `{:unsupported, _}` (this handle does not answer the
  callback), `{:invalid_argument, _}` from a backend's own path rules, a bare
  `{:http, status}` that is not unhealthy, and `{:upstream_refused,
  :unknown}`. They stop the walk anyway: which of them should fail over is a
  routing decision this module has not made, apart from cursors (below).

  ## Which error a failed walk reports

  What the caller is told is not always the error the walk stopped on. An open
  breaker and a URL that does not parse are SKIPS, not faults from a call:
  each is a fact about the source (earlier calls, or its configuration), not
  about this request.

    1. An answer any source would give stands, whichever source gave it.
    2. Otherwise, after a failover from a call, the caller is told the FIRST
       fault from a call in walk order. A source-specific final reason from a
       later source does not stand in for it, nor does a later skip or the
       last candidate's fault. Last-wins told a client "Check the arguments"
       for a 400 from a fallback when the primary had timed out, and hid that
       timeout from the tool's breaker, which reads a 400 as an answer.
    3. With no failover from a call, the first source actually called answered
       for itself, and its error stands whatever its class. A walk whose only
       earlier problems are skips is in this case; when every source was
       skipped, the first skip is reported, an open breaker before a
       misconfiguration, since "retry later" is the one a client can act on.

  ## Paging walks are pinned

  A cursor is bound to the scope of the source that minted it
  (`Raxol.Web3.Cursor`), and no other source can serve it: one that tried
  would return its first page labelled as page two. So a request that carries
  a cursor goes only to the handles whose `Raxol.Web3.Backend.cursor_scopes/1`
  includes the scope the cursor claims, in health order among them. The claim
  is read without verification and used for nothing but that choice; the
  handle asked verifies the cursor in full, so a forged or altered cursor gets
  whatever its claimed source answers. A handle that declares no scopes mints
  no cursors and is not asked.

    * The minter answers: page two, even when its open breaker had demoted it.
    * The minter's breaker is open: the caller hears the pause
      (`{:breaker_open, _}`), and a later retry with the same cursor is the
      right next step.
    * No configured source has the claimed scope (the router changed after
      the cursor was minted): `{:invalid_cursor, :wrong_scope}` without asking
      anyone, and the walk restarts.
    * A cursor whose claim cannot be read is routed as any request is, and the
      first source refuses it (rule 3).
  """

  require Logger

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Cursor
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
      _handles -> router |> candidates(chain_ref, callback) |> route(callback, args)
    end
  end

  defp route(candidates, callback, args) do
    case for_cursor(candidates, args) do
      {:ok, handles} -> attempt(handles, callback, args)
      {:error, _reason} = error -> error
    end
  end

  # A request that carries a cursor goes only to the handles whose scope the
  # cursor claims, in health order among them: no other source can serve it.
  # The claim is read unverified (`Raxol.Web3.Cursor.claimed_scope/1`) and
  # used for nothing but this choice; the handle asked still verifies the
  # cursor in full. A cursor whose claim cannot be read is routed as before,
  # so the first source refuses it as it does today. A handle that declares no
  # scopes (`nil`) mints no cursors, so it is not asked: one that ignored the
  # cursor would answer its first page labelled as the next.
  defp for_cursor(candidates, args) do
    case claimed_scope(args) do
      {:ok, scope} ->
        case Enum.filter(candidates, &mints?(&1, scope)) do
          [] when candidates != [] -> {:error, {:invalid_cursor, :wrong_scope}}
          matching -> {:ok, matching}
        end

      :none ->
        {:ok, candidates}
    end
  end

  defp claimed_scope(args) do
    with cursor when is_binary(cursor) <- Enum.find_value(args, &cursor_in/1),
         {:ok, scope} <- Cursor.claimed_scope(cursor) do
      {:ok, scope}
    else
      _no_readable_claim -> :none
    end
  end

  defp cursor_in(opts) when is_list(opts) do
    if Keyword.keyword?(opts), do: Keyword.get(opts, :cursor)
  end

  defp cursor_in(_arg), do: nil

  defp mints?(handle, scope), do: scope in (Backend.cursor_scopes(handle) || [])

  # `seen` keeps the first fault from a call actually made and, apart, the
  # first source that was skipped rather than called: an open breaker is a
  # fact about earlier calls, and a URL that does not parse is a fact about
  # the source's configuration. A walk whose only earlier problems are skips
  # has not failed over from a call, so the first source called answers for
  # itself (rule 3).
  defp attempt(candidates, callback, args, seen \\ %{fault: nil, skipped: nil})

  defp attempt([], callback, _args, _seen), do: {:error, {:unsupported, callback}}

  defp attempt([handle | rest], callback, args, seen) do
    case Backend.call(handle, callback, args) do
      {:ok, _value} = ok ->
        ok

      {:error, reason} ->
        if reason == {:blocked, :invalid_url}, do: warn_misconfigured(handle)

        if rest != [] and failover?(reason) do
          log_failover(handle, callback, reason)
          attempt(rest, callback, args, note(seen, reason))
        else
          {:error, reported(handle, callback, reason, seen)}
        end
    end
  end

  defp skip?({:breaker_open, _}), do: true
  defp skip?({:blocked, :invalid_url}), do: true
  defp skip?(_reason), do: false

  defp note(seen, reason) do
    if skip?(reason),
      do: %{seen | skipped: first_skip(seen.skipped, reason)},
      else: %{seen | fault: seen.fault || reason}
  end

  # The first skip, except that a pause outranks a misconfiguration: "retry
  # later" is the one a client can act on, and it will work once the paused
  # source recovers. The operator is already warned about the other.
  defp first_skip(nil, reason), do: reason
  defp first_skip({:blocked, :invalid_url}, {:breaker_open, _} = paused), do: paused
  defp first_skip(first, _reason), do: first

  # The moduledoc's three rules. No fault from a call: rule 3, unless every
  # source was skipped, when the first skip is reported, a pause before a
  # misconfiguration.
  defp reported(_handle, _callback, reason, %{fault: nil, skipped: skipped}),
    do: if(skip?(reason), do: first_skip(skipped, reason), else: reason)

  defp reported(handle, callback, reason, %{fault: first_fault}) do
    cond do
      source_independent?(reason) ->
        reason

      failover?(reason) ->
        first_fault

      true ->
        log_replaced(handle, callback, reason, first_fault)
        first_fault
    end
  end

  defp log_replaced(handle, callback, reason, first_fault) do
    Logger.debug(fn ->
      "raxol_web3: #{Backend.name(handle)} answered #{callback} " <>
        "(#{inspect(reason)}) after a failover; reporting #{inspect(first_fault)}"
    end)
  end

  # Once per handle per node, not per call: a misconfigured source refuses
  # every read the same way, and a line per call would bury everything else.
  # The marker is a `:persistent_term` keyed by a hash of the handle, so the
  # lines are bounded by the number of configured sources. The source is named
  # by `Backend.name/1` and its chains, never by URL: the URL is what is wrong,
  # and it may carry a key.
  defp warn_misconfigured({module, state} = handle) do
    marker = {__MODULE__, :misconfigured, :erlang.phash2(handle)}

    unless :persistent_term.get(marker, false) do
      :persistent_term.put(marker, true)

      Logger.warning(
        "raxol_web3: #{Backend.name(handle)} (#{Enum.join(module.supported_chain_ids(state), ", ")}) " <>
          "has a base URL that does not parse; skipping it until it is reconfigured"
      )
    end
  end

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
  # A source whose URL does not parse refuses every read; the next may not.
  defp failover?({:blocked, :invalid_url}), do: true
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
