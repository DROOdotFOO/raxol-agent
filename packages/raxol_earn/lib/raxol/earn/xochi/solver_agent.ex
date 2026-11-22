defmodule Raxol.Earn.Xochi.SolverAgent do
  @moduledoc """
  Runtime that drives a Xochi cross-chain transfer ACP job from acceptance
  through settlement, as the storefront PROVIDER.

  Subscribes to a `Raxol.Earn.Agent`, filters for plain jobs whose `provider` is
  this solver's wallet address, and runs the lifecycle:

  1. **`job.created`** -- record the job, wait for the buyer's requirement
     message.
  2. **`message` (contentType "requirement")** -- parse the requirement JSON
     against `Raxol.Earn.Xochi.Offering.requirement_schema/0` (which carries the
     buyer's signed intent bundle), compute the storefront fee (default 8 bps
     via `:fee_bps`), and propose the budget on-chain via
     `Raxol.Earn.HookClient.set_budget/6`. This is a PLAIN job (hook =
     `address(0)`), so `set_budget` carries no hook data -- the budget is the
     storefront fee, not the transfer. The transfer moves through Xochi
     off-escrow, so the ACP core's take never bites it.
  3. **`budget.set`** (echoed back via SSE) -- no-op for the solver; observe.
  4. **`job.funded`** -- run `settle_fn` (default: a `Raxol.Earn.Xochi.Settler`
     relay) which relays the buyer's pre-signed intent through Xochi and, on
     success, submits the deliverable (the settlement tx hashes) on-chain.
  5. **`job.completed`** -- mark the session completed.

  ## Configuration

      Raxol.Earn.Xochi.SolverAgent.start_link(
        agent: my_acp_agent,
        provider: my_provider_adapter,
        wallet_address: "0xfeed...",
        evaluator_address: "0xevaluator...",
        chain_id: 8453,
        acp_core_address: "0x238E541BfefD82238730D00a2208E5497F1832E0",
        fee_bps: 8,
        settle_fn: Raxol.Earn.Xochi.Settler.build(xochi_config: %{base_url: "..."})
      )

  ## Sessions

  One internal `session_state()` per active job. Stored in process
  state keyed by `{chain_id, job_id}`. State machine:

      :awaiting_requirement -> :budget_proposed -> :settling
        -> :submitted -> :completed

  A session rebuilt from history after a restart enters at `:awaiting_fund`.
  `:rejected` and `:failed` are terminal.

  ## Telemetry

  Emits `[:raxol, :earn, :xochi, :solver, :event]` on every entry it
  acts on, with metadata `%{key, event, payload}`.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Secret
  alias Raxol.Earn.{Agent, HookClient}
  alias Raxol.Earn.Xochi.IntentDeriver
  alias Raxol.Earn.Xochi.SolverAgent.{Budget, Reattach, Requirement}
  alias Raxol.Payments.Xochi.Client, as: XochiClient

  @type session_status ::
          :awaiting_requirement
          | :budget_proposed
          | :awaiting_fund
          | :settling
          | :submitted
          | :completed
          | :rejected
          | :failed

  @type session_state :: %{
          required(:job_id) => String.t() | non_neg_integer(),
          required(:chain_id) => pos_integer(),
          required(:status) => session_status(),
          required(:job_id_uint) => non_neg_integer(),
          optional(:requirement) => map(),
          optional(:budget_atomic) => non_neg_integer(),
          optional(:transfer_amount_atomic) => non_neg_integer(),
          optional(:deliverable) => map(),
          optional(:settle_tx_hashes) => map()
        }

  @type t :: %__MODULE__{
          agent: pid() | atom(),
          provider: Raxol.Earn.ProviderAdapter.adapter(),
          wallet_address: String.t(),
          evaluator_address: String.t(),
          chain_id: pos_integer(),
          acp_core_address: String.t(),
          fee_bps: non_neg_integer(),
          min_fee_atomic: non_neg_integer(),
          settle_fn: fun(),
          history_fn:
            (Raxol.Earn.Transport.job_key() ->
               {:ok, [map()]} | {:error, term()})
            | nil,
          xochi_config: map(),
          sessions: %{Raxol.Earn.Transport.job_key() => session_state()}
        }

  defstruct [
    :agent,
    :provider,
    :wallet_address,
    :evaluator_address,
    :chain_id,
    :acp_core_address,
    :xochi_config,
    settle_fn: nil,
    history_fn: nil,
    fee_bps: 8,
    min_fee_atomic: 1,
    sessions: %{}
  ]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    name = Keyword.get(opts, :name)

    if name do
      GenServer.start_link(__MODULE__, opts, name: name)
    else
      GenServer.start_link(__MODULE__, opts)
    end
  end

  @doc "Return the current per-session state map."
  @spec sessions(GenServer.server()) :: map()
  def sessions(server), do: GenServer.call(server, :sessions)

  @doc "Return the state for a specific `{chain_id, job_id}` key, or nil."
  @spec session(GenServer.server(), Raxol.Earn.Transport.job_key()) ::
          session_state() | nil
  def session(server, key), do: GenServer.call(server, {:session, key})

  @impl GenServer
  def init(opts) do
    case Budget.min_fee(opts) do
      {:ok, min_fee_atomic} -> start_solver(opts, min_fee_atomic)
      {:error, reason} -> {:stop, reason}
    end
  end

  defp start_solver(opts, min_fee_atomic) do
    state = %__MODULE__{
      agent: Keyword.fetch!(opts, :agent),
      provider: Keyword.fetch!(opts, :provider),
      wallet_address: Requirement.normalize_address(Keyword.fetch!(opts, :wallet_address)),
      evaluator_address: Keyword.fetch!(opts, :evaluator_address),
      chain_id: Keyword.fetch!(opts, :chain_id),
      acp_core_address: Keyword.fetch!(opts, :acp_core_address),
      fee_bps: Keyword.get(opts, :fee_bps, 8),
      min_fee_atomic: min_fee_atomic,
      settle_fn: Keyword.get(opts, :settle_fn, &default_settle/1),
      history_fn: Keyword.get(opts, :history_fn),
      xochi_config: XochiClient.protect_config(Keyword.get(opts, :xochi_config, %{}))
    }

    :ok = Agent.subscribe(state.agent)

    {:ok, state}
  end

  @impl GenServer
  def handle_call(:sessions, _from, state), do: {:reply, state.sessions, state}

  def handle_call({:session, key}, _from, state) do
    {:reply, Map.get(state.sessions, key), state}
  end

  @impl GenServer
  def handle_info({Raxol.Earn.Agent, _agent_pid, session_pid, entry}, state) do
    {:noreply, dispatch(entry, session_pid, state)}
  end

  # Ignore anything we don't recognise.
  def handle_info(_msg, state), do: {:noreply, state}

  # The Xochi token and the provider's key and RPC URLs are `Secret`s, which
  # `:sys.get_status` and an Erlang-formatted crash report print raw.
  @impl GenServer
  def format_status(status),
    do: Secret.redact_status(status, [:provider, :xochi_config], failure: true)

  defp dispatch(%{"kind" => "system", "event" => "job.created"} = entry, _session, state) do
    handle_job_created(entry, state)
  end

  defp dispatch(%{"kind" => "system", "event" => "job.funded"} = entry, _session, state) do
    handle_job_funded(entry, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.completed"} = entry,
         _session,
         state
       ) do
    handle_job_completed(entry, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.rejected"} = entry,
         _session,
         state
       ) do
    finalize(entry, :rejected, state)
  end

  defp dispatch(
         %{"kind" => "system", "event" => "job.expired"} = entry,
         _session,
         state
       ) do
    finalize(entry, :failed, state)
  end

  defp dispatch(%{"kind" => "message", "contentType" => "requirement"} = entry, _session, state) do
    handle_requirement(entry, state)
  end

  defp dispatch(_entry, _session, state), do: state

  defp handle_job_created(entry, state) do
    key = job_key(entry)
    job_id_uint = Requirement.job_id_uint(entry["jobId"])

    # Filter: only act on jobs where we're the provider.
    if interested?(entry, state) do
      session = %{
        job_id: entry["jobId"],
        chain_id: entry["chainId"],
        job_id_uint: job_id_uint,
        status: :awaiting_requirement
      }

      emit(state, key, :job_created, :await_requirement)
      Logger.info("[xochi.solver] accepted job.created key=#{inspect(key)}; awaiting requirement")
      put_session(state, key, session)
    else
      state
    end
  end

  defp handle_requirement(entry, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, %{status: :awaiting_requirement} = session} ->
        case Requirement.decode(entry["content"]) do
          {:ok, req} ->
            propose_budget(state, key, session, req)

          {:error, reason} ->
            emit(state, key, :requirement_error, reason)
            put_session(state, key, %{session | status: :failed})
        end

      _ ->
        state
    end
  end

  # Settle only the session the funded event names. A single job.funded must
  # never fan-settle every pending session -- doing so spends real funds via
  # settle/3 for jobs that were not funded.
  defp handle_job_funded(entry, state) do
    key = job_key(entry)
    live_status = live_session_status(state, key)

    emit(state, key, :job_funded, %{session_status: live_status})

    Logger.info(
      "[xochi.solver] job.funded key=#{inspect(key)} live_session=#{inspect(live_status)}"
    )

    case settle_target(state.sessions, key) do
      {:ok, key, session} ->
        settle(state, key, session)

      :none ->
        # An absent session means a restart lost it: rebuild from history. A
        # session past funding is a duplicate or late event and is left alone.
        if live_status == :absent do
          reattach_and_settle(entry, key, state)
        else
          Logger.info(
            "[xochi.solver] job.funded ignored for #{inspect(key)} (session #{inspect(live_status)})"
          )

          state
        end
    end
  end

  defp live_session_status(state, key) do
    case Map.fetch(state.sessions, key) do
      {:ok, %{status: status}} -> status
      :error -> :absent
    end
  end

  defp reattach_and_settle(entry, key, state) do
    Logger.info("[xochi.solver] no live session for #{inspect(key)}; reattaching from history")

    case Reattach.rebuild(entry, key, state) do
      {:ok, session} ->
        emit(state, key, :reattached, :from_history)
        Logger.info("[xochi.solver] reattached #{inspect(key)} from history; settling")
        settle(put_session(state, key, session), key, session)

      {:error, reason} ->
        emit(state, key, :reattach_failed, reason)
        Logger.warning("[xochi.solver] reattach aborted for #{inspect(key)}: #{inspect(reason)}")
        state
    end
  end

  @doc false
  # Pure routing decision behind `handle_job_funded/2`: a funded event settles
  # the session at its own `{chain_id, job_id}` and only when that session is
  # awaiting funding. Any other key -- absent, or in a non-fundable state --
  # returns `:none`. Selecting anything but the named key would re-open the
  # fan-settle hole. Exposed for property tests.
  @spec settle_target(%{optional(Raxol.Earn.Transport.job_key()) => session_state()}, term()) ::
          {:ok, Raxol.Earn.Transport.job_key(), session_state()} | :none
  def settle_target(sessions, key) do
    case Map.fetch(sessions, key) do
      {:ok, %{status: status} = session} when status in [:budget_proposed, :awaiting_fund] ->
        {:ok, key, session}

      _ ->
        :none
    end
  end

  defp handle_job_completed(entry, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, session} ->
        emit(state, key, :job_completed, :ok)
        put_session(state, key, %{session | status: :completed})

      :error ->
        state
    end
  end

  defp finalize(entry, status, state) do
    key = job_key(entry)

    case Map.fetch(state.sessions, key) do
      {:ok, session} ->
        emit(state, key, status, :ok)
        put_session(state, key, %{session | status: status})

      :error ->
        state
    end
  end

  @doc false
  @spec budget_for(non_neg_integer(), non_neg_integer()) :: non_neg_integer()
  defdelegate budget_for(transfer_atomic, fee_bps), to: Budget

  # The fee is sized on the amount the buyer signed, read from Xochi by intent
  # id, never the relayed `amount_atomic` a buyer could understate. An intent
  # that cannot be resolved fails the job closed.
  defp propose_budget(state, key, session, requirement) do
    with {:ok, %{intent: intent, from_amount: transfer_atomic}} <-
           IntentDeriver.resolve(state.xochi_config, requirement),
         {:ok, budget_atomic} <-
           Budget.fee_budget(intent, transfer_atomic, state.fee_bps, state.min_fee_atomic) do
      set_budget(state, key, session, requirement, transfer_atomic, budget_atomic)
    else
      {reject_or_error, reason} when reject_or_error in [:reject, :error] ->
        emit(state, key, :requirement_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  defp set_budget(state, key, session, requirement, transfer_atomic, budget_atomic) do
    case HookClient.set_budget(
           state.provider,
           state.chain_id,
           state.acp_core_address,
           session.job_id_uint,
           budget_atomic
         ) do
      {:ok, tx_hash} ->
        emit(state, key, :budget_proposed, %{tx_hash: tx_hash, budget_atomic: budget_atomic})

        Logger.info(
          "[xochi.solver] setBudget #{budget_atomic} for #{inspect(key)} tx=#{tx_hash}; awaiting fund"
        )

        updated =
          session
          |> Map.put(:status, :budget_proposed)
          |> Map.put(:requirement, requirement)
          |> Map.put(:budget_atomic, budget_atomic)
          |> Map.put(:transfer_amount_atomic, transfer_atomic)

        put_session(state, key, updated)

      {:error, reason} ->
        emit(state, key, :budget_error, reason)
        put_session(state, key, %{session | status: :failed})
    end
  end

  defp settle(state, key, session) do
    session = %{session | status: :settling}
    state = put_session(state, key, session)
    emit(state, key, :settling, :start)
    Logger.info("[xochi.solver] settling #{inspect(key)} via Xochi relay")

    case state.settle_fn.(%{
           requirement: session.requirement,
           signed_intent: session.requirement["signed_intent"],
           transfer_amount_atomic: session.transfer_amount_atomic
         }) do
      {:ok, %{intent_id: intent_id} = deliverable} ->
        Logger.info("[xochi.solver] settled #{inspect(key)} intent=#{intent_id}; submitting")
        submit_deliverable(state, key, session, deliverable, intent_id)

      {:error, reason} ->
        emit(state, key, :settle_error, reason)
        Logger.error("[xochi.solver] settle failed for #{inspect(key)}: #{inspect(reason)}")
        put_session(state, key, %{session | status: :failed})
    end
  end

  defp submit_deliverable(state, key, session, deliverable, intent_id) do
    deliverable_hash = compute_deliverable_hash(deliverable)

    case HookClient.submit(
           state.provider,
           state.chain_id,
           state.acp_core_address,
           session.job_id_uint,
           deliverable_hash
         ) do
      {:ok, tx_hash} ->
        emit(state, key, :submitted, %{tx_hash: tx_hash, intent_id: intent_id})
        Logger.info("[xochi.solver] submitted deliverable for #{inspect(key)} tx=#{tx_hash}")

        session =
          session
          |> Map.put(:status, :submitted)
          |> Map.put(:deliverable, deliverable)
          |> Map.put(:settle_tx_hashes, %{
            submit: tx_hash,
            intent_id: intent_id
          })

        put_session(state, key, session)

      {:error, reason} ->
        emit(state, key, :submit_error, reason)
        Logger.error("[xochi.solver] submit failed for #{inspect(key)}: #{inspect(reason)}")
        put_session(state, key, %{session | status: :failed})
    end
  end

  # Deterministic stub used when no `:settle_fn` is given; production passes a
  # `Raxol.Earn.Xochi.Settler` relay closure.
  defp default_settle(%{transfer_amount_atomic: transfer_atomic}) do
    {:ok,
     %{
       intent_id: "stub-intent-#{:erlang.unique_integer([:positive])}",
       quote_id: "stub-quote",
       settlement_tx_hash: "0x" <> String.duplicate("a", 64),
       receiving_tx_hash: "0x" <> String.duplicate("b", 64),
       status: "settled",
       fee_atomic: "0",
       dst_amount_atomic: transfer_atomic && to_string(transfer_atomic)
     }}
  end

  defp interested?(entry, state) do
    job_provider =
      entry["provider"] ||
        get_in(entry, ["payload", "provider"]) ||
        get_in(entry, ["data", "provider"])

    case job_provider do
      nil -> false
      addr -> Requirement.normalize_address(addr) == state.wallet_address
    end
  end

  defp job_key(entry) do
    {entry["chainId"], entry["jobId"]}
  end

  defp compute_deliverable_hash(deliverable) do
    deliverable
    |> Jason.encode!()
    |> ExKeccak.hash_256()
  end

  defp put_session(state, key, session) do
    %{state | sessions: Map.put(state.sessions, key, session)}
  end

  defp emit(_state, key, event, payload) do
    :telemetry.execute(
      [:raxol, :earn, :xochi, :solver, :event],
      %{},
      %{key: key, event: event, payload: payload}
    )
  end
end
