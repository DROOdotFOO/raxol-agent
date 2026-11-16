defmodule Raxol.Broker.Executor do
  @moduledoc """
  The one path every order takes: intent, policy, `review_*`, policy again,
  `placing`, `place_*`, each step journaled before the next one runs.

      run(intent, context)
        open_group       intent + context (policy and counters set here)
        verdict          :pre_review; DENY ends here
        review           the review tool's response; its warnings feed the context
        verdict          :post_review; DENY ends here, ASK parks the group
        [approval]       approve/3 or decline/3 on a parked group
        placing          Raxol.Broker.Executor.Place, with the ReviewReceipt
        order            :placed | :pending_approval | :failed | :unknown

  ## Context

  The executor fills every `Raxol.Broker.Policy.Context` field itself,
  whatever the caller passed:

    * `policy`, from the `:policy` start option.
    * `today_notional` and `orders_last_minute`, read from
      `Raxol.Broker.Journal` at decision time. The day starts at midnight
      America/New_York (`Raxol.Broker.MarketCalendar.day_start/1`).
    * `quotes`, `positions`, `portfolio_value`, `start_of_day_value`,
      `day_pnl` and `market_session`, read through its own session's read
      tools by `Raxol.Broker.Policy.ContextBuilder` when an intent arrives
      (cancels excepted: they need none). A read that fails leaves its
      fields `nil`, and every rule that needs one denies.
    * `review_warnings`, from this executor's own review call (empty
      before it).

  The caller's context is still rebuilt from plain data with
  `Raxol.Broker.Intent.normalize/1` and
  `Raxol.Broker.Policy.Context.normalize/1` in the caller (`run/3`) and
  again in this process before anything else, by pattern matching only.
  A struct, float, pid or function anywhere in it is `{:error,
  {:invalid_intent, reason}}` or `{:error, {:invalid_context, reason}}`
  and nothing is journaled or sent: no protocol of caller data
  (Enumerable, Inspect, ...) ever runs in this process.

  ## Drawdown breaker

  A pre-review DENY by `:drawdown_breaker` (today's loss past the policy's
  `drawdown_halt`) also halts the broker: `Raxol.Broker.Halt.pause/2`
  disarms, journals a `halt` record and pauses every strategy runner. Only
  a fresh arm resumes them.

  ## Guards

  Everything is re-checked here, whatever the caller did:

    * Decisions are serialized through this process, so two callers cannot
      both pass the daily cap before either writes `placing`.
    * One executor per journal: `init/1` claims the journal with
      `Raxol.Broker.Journal.claim/1`, and a second executor on the same
      journal fails to start with `{:journal_claimed, pid}`. The journal
      only grants the claim to a process started as an executor, and
      refuses `placing` from any process but the claimant.
    * The claim lives in the journal's memory. The executor monitors the
      journal and stops with `{:journal_down, reason}` when it goes down,
      so its supervisor restarts it; the new executor claims again and
      closes the groups this one left open. Queued callers get an exit
      from their call, and an in-flight review task dies with the
      executor.
    * Review is mandatory: `Raxol.Broker.Executor.Place` is the only
      module that names an order tool, and it needs a
      `Raxol.Broker.Executor.ReviewReceipt` for the same intent and group,
      verified under a key this process generates and keeps in its own
      process dictionary (`receipt_key/0` is nil in any other process).
      The key is put there only after the claim succeeds. No caller code
      runs in this process: `:journal` must be an atom or pid, and the
      `:clock` runs in a task. The journal refuses every group write from
      any process but the claimant, and `placing` for a group without a
      review record and an ALLOW or an approval after it.
    * Threat model: the BEAM cannot stop code that deliberately writes
      into another module's private state, e.g. `Process.put` into its
      slots or `:sys.replace_state`. The guarantee is that no path through
      public APIs can send an order tool without this review pipeline.
      Every remaining bypass requires impersonating the executor's private
      process-dictionary slots on purpose.
    * Any journal error before `placing` is written, any review error, and
      any intent without an order tool mean no order is sent.
    * Once the order call has been made the result is always `{:ok, map}`.
      If the `order` record could not be written the map has
      `journaled: false` and `journal_error: reason`; the order may exist
      at the broker, so reconcile before retrying.
    * Idempotency: an intent id that already has a group with a `placing`
      record whose outcome is not `:failed` (including a crash closed as
      `crash_outcome_unknown`) returns `{:ok, :duplicate}` and calls
      nothing. Each place also sends a `ref_id` derived from the intent id,
      which Robinhood deduplicates on. Intent ids must be stable for a
      re-run to be recognised: pass `:id` to the `Raxol.Broker.Intent`
      constructor.
    * Trade approvals: when the review says `customer_approval_required`,
      a successful place is `:pending_approval`, not `:placed`. Robinhood
      holds a proposal the owner approves or declines in its app. The group
      keeps counting toward the caps and its intent is a duplicate, since
      the proposal can still become an order. Nothing here resolves it yet.

  ## ASK

  A post-review ASK parks the group and returns `{:ask, group_id, prompts}`;
  the group id is the token. `approve/3` re-fetches quotes, positions,
  portfolio, calendar and journal counters off-process, records the fresh
  context and approval, then evaluates policy again. A fresh DENY ends the
  group; a drawdown DENY also disarms and pauses runners. ASK (the questions
  the human just answered) or ALLOW proceeds to `placing`. `decline/3` and
  `close/3` end the group. The dashboard shows ASKs in terminal, LiveView and SSH.

  The timeout is this process's, not a view's: parking starts a timer of the
  policy's `ask_timeout` (five minutes by default), and a group still parked
  when it fires gets a post-review DENY with rule id `:ask_timeout`, so an
  ASK nobody answers is denied whether or not a dashboard is open.

  `approve/3` and `decline/3` need a non-empty `by`, `close/3` a non-nil
  atom reason; anything else raises `FunctionClauseError` in the caller and
  leaves the group parked. Approval while disarmed closes it `not_armed`.
  An ASK that expires during the context fetch is already terminal; the
  approval's context append fails and sends nothing. A port-down refusal
  before fetching context leaves the group parked.

  Parked groups live in this process. On start, every group the journal
  still has open is closed with `{:close, :executor_restarted}`, so a group
  parked before a restart cannot be approved after it.

  ## Concurrency

  Context, review and reconciliation reads run in tasks, so the executor
  keeps answering while they are in flight. Ordinary requests remain
  serialized in arrival order; halt interrupts the active read stage and
  runs before queued work. Interrupted results cannot resume the pipeline.
  Each queued caller is monitored and dropped if it dies. Only this
  process journals decisions and sends through Place. A place call remains
  synchronous and bounded by `:place_timeout`. At most one queued request
  is dispatched per callback, so the shutdown bound covers the one write
  in progress.

  If the port goes down after the review but before the place (its EXIT
  handled first), the group is closed with `:port_not_ready`, no `placing`
  is written and nothing is sent; a re-run of the intent places once the
  port is back.

  ## Port

  The port is a `Raxol.Broker.Executor.Port.MCP` session built from
  `:session`. `init/1` only checks the spec (`Port.MCP.prepare/2`, so in
  `:dry_run` a live spec fails start); the client starts after `init/1`, linked
  to this process, and a task waits for it to be ready, so the executor
  answers while it connects. Until it is ready, `run/3` and `approve/3`
  return `{:error, :port_not_ready}` before opening or journaling
  anything; `await_port/2` waits for readiness.

  Exits are trapped. When the client dies (also mid-connect) or fails to
  become ready the executor stays up, logs the failure and starts a new
  client after a backoff (`:reconnect_ms`, default 1 s, doubling to 60 s,
  reset once ready); the client itself retries a failed connect on the
  same schedule. A port that is down never restarts the executor, so an
  unreachable endpoint cannot exhaust its supervisor's restart budget.

  ## Reconciliation

  Counted groups whose outcome is open (`Raxol.Broker.Journal.unresolved/1`)
  are checked against Robinhood once the port first connects and every
  `:reconcile_ms` after:

    * an order journaled `:unknown`, or closed `crash_outcome_unknown`, is
      looked up by the `ref_id` its place sent in every page of
      `get_equity_orders` (agent-initiated, since its day). Found, it is
      resolved `placed` and keeps counting. It is resolved `absent` (it
      stops counting and its intent may be sent again; Robinhood
      deduplicates on `ref_id` in any case) only when every page was read,
      its `placing` is at least `:reconcile_min_age_ms` old (default
      120_000, so an order still on its way is not taken for a lost one),
      and its review did not ask for the owner's approval: an order made
      from an approved proposal carries the approval id, not the `ref_id`,
      so for those absence proves nothing and the group keeps counting;
    * a `:pending_approval` proposal is read back with `get_trade_approvals`
      (`approval_ids`, from its place response, 100 per call). `approved`
      keeps counting; `declined` or `expired` releases the cap and the
      intent.

  Each resolution is a `resolve` record in the journal.

  ## Mode

  No order tool is sent unless the latest mode record in the journal is
  `armed` (`Raxol.Broker.Mode`, written by `mix raxol.broker.arm`). The
  record is read when an intent arrives and again just before `placing`:

    * disarmed when the intent arrives: the group opens with `"mode":
      "dry_run"` and closes as `not_armed`, without fetching context or
      reviewing; `run/3` returns `{:error, :not_armed}`;
    * armed when it arrives: the group opens with `"mode": "armed"`;
    * disarmed by the time it would place (a parked ASK approved after a
      disarm, a review in flight): the group is closed as `not_armed`
      before `placing` and `{:error, :not_armed}` returned.

  Cancels are gated like any other intent, and the policy allows a cancel
  only with `:human` provenance, so neither a strategy nor model output can
  cancel the owner's orders.

  The `:mode` option decides which sessions the port may reach.
  `:dry_run` (the default) refuses a live session before connecting
  (`{:error, :live_port_in_dry_run}`): its `:session` must carry `sandbox:
  true` and a URL that is not on `robinhood.com`. `:live` admits any
  session, Robinhood's included.

  ## Live session

  With `:credential`, the session is `Raxol.Broker.Session.spec/2` over the
  credential in `Raxol.Broker.CredentialStore` (read at start, in a task;
  `{:no_credential, reason}` stops the start when there is none) and the
  `:session` keys, Robinhood's URL unless `:session` names another. The
  token is refreshed `refresh_skew` seconds (default 300) before it
  expires, and on a 401 at connect, through `Raxol.Broker.Session.refresh/3`
  in a task; the port then reconnects with the new bearer, after any review
  in flight. A failed refresh is logged and retried after a minute. One
  Robinhood refuses (`invalid_grant`, or no refresh token) also disarms the
  broker (reason `reauth_required`): signing in again stores a credential
  the next retry takes over, and orders need a fresh arm.

  ## Options

    * `:policy` (required) - a policy keyword list, validated with
      `Raxol.Broker.PolicyFile.validate/1`; `{:invalid_policy, reason}`
      otherwise.
    * `:session` (required) - a `Raxol.MCP.Client` spec for
      `Raxol.Broker.Executor.Port.MCP.prepare/2` and `start_client/1`.
    * `:account_number` (required) - the account orders are sent for.
    * `:journal` - the `Raxol.Broker.Journal` server, a registered name
      (atom) or a pid (default that module). Anything else, such as
      `{:via, module, name}` or `{:global, name}`, is
      `{:invalid_journal, value}`: resolving it would run caller code in
      this process.
    * `:mode` - `:dry_run` (default) or `:live`; see "Mode".
    * `:credential` - `[store: store_opts, auth: auth_opts, refresh_skew:
      seconds]` for a live session; see "Live session".
    * `:clock` - zero-arity function returning the UTC `DateTime` used for
      the counters (default `DateTime.utc_now/0`). It runs in a short-lived
      task, never in this process, with a 5 s budget. Its result is rebuilt
      with `Raxol.Broker.Plain.normalize/1` before any `DateTime` function
      sees it; anything but a UTC `DateTime` in the ISO calendar fails the
      call with `{:error, {:context, reason}}` and nothing is opened or sent.
    * `:review_timeout`, `:place_timeout` - per tool call, an integer of
      milliseconds in 1..4_294_000_000 (default 30 s; the cap leaves
      headroom under the VM's timer limit); anything else is
      `{:invalid_timeout, key, value}`.
    * `:reconnect_ms` - the first port reconnect delay, same range
      (default 1 s, doubling to 60 s).
    * `:reconcile_ms` - how often unresolved orders and proposals are
      reconciled after the first, same range (default 300_000); see
      "Reconciliation".
    * `:reconcile_min_age_ms` - how old a `placing` must be before its order
      may be resolved `absent`, a non-negative integer (default 120_000).
    * `:shutdown` - the child spec's shutdown bound in milliseconds, a
      positive integer (default `place_timeout + 5_000`).
    * `:strategies` - the `Raxol.Broker.Strategy.Supervisor` the drawdown
      breaker pauses (default that module).
    * `:name`.

  `child_spec/1` sets `shutdown` from `:shutdown`, else `place_timeout +
  5_000`: a supervisor stopping the executor during a place waits up to
  that bound for the order call. A stop is handled between callbacks, so
  a review in flight is never waited for (its task dies with the
  executor). A journal write stalled past the bound is killed with the
  executor; the group is then closed as `crash_outcome_unknown` on
  restart (counted, never re-placed), and recovery reports it as such.

  `today_notional` counts from the New York midnight that began the
  exchange day on the executor's clock. No caller input moves it.
  """

  use GenServer

  require Logger

  alias Raxol.Broker.Executor.{Place, Port, Read, Review, ReviewReceipt}
  alias Raxol.Broker.Executor.Port.MCP, as: PortMCP
  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.{AccountPin, CredentialStore, Halt, Intent, Journal, MarketCalendar}
  alias Raxol.Broker.{Mode, Plain, Policy}
  alias Raxol.Broker.{PolicyFile, Response, Session}
  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.Policy.{Context, ContextBuilder}
  alias Raxol.Broker.Tools.Catalog

  @default_timeout 30_000
  @default_reconnect_ms 1_000
  @default_reconcile_ms 300_000
  @default_reconcile_min_age_ms 120_000
  @max_backoff 60_000
  @clock_timeout 5_000
  # `receive after` and `Process.send_after/3` refuse anything above
  # 4_294_967_295 ms; the cap leaves headroom under that.
  @max_timeout 4_294_000_000
  @default_skew 300
  @refresh_retry_ms 60_000
  @store_timeout 30_000

  @type placed :: %{
          required(:group_id) => String.t(),
          required(:status) => Place.status(),
          required(:response) => map(),
          required(:journaled) => boolean(),
          optional(:journal_error) => term()
        }

  @type result ::
          {:ok, placed()}
          | {:ok, :duplicate}
          | {:ask, String.t(), [{Policy.rule_id(), String.t()}]}
          | {:deny, String.t(), term()}
          | {:error, term()}

  # -- API ----------------------------------------------------------------------

  @doc "Start the executor. See the moduledoc for options."
  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, gen_opts)
  end

  @doc """
  Run `intent` through the pipeline. See the moduledoc.

  Both structs are rebuilt from plain data here (`Intent.normalize/1`,
  `Context.normalize/1`) and again inside the executor; anything else is
  `{:error, {:invalid_intent, reason}}` or `{:error, {:invalid_context,
  reason}}` and nothing is sent to the executor.
  """
  @spec run(GenServer.server(), Intent.t(), Context.t()) :: result()
  def run(server, %Intent{} = intent, %Context{} = context) do
    with {:ok, intent, context} <- Policy.normalize(intent, context),
         do: GenServer.call(server, {:run, intent, context}, :infinity)
  end

  @doc "Approve a parked ASK; `by` names who approved (non-empty string)."
  @spec approve(GenServer.server(), String.t(), String.t()) :: result()
  def approve(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:approve, token, by}, :infinity)

  @doc "Decline a parked ASK; the group ends as DENY. `by` is a non-empty string."
  @spec decline(GenServer.server(), String.t(), String.t()) :: :ok | {:error, term()}
  def decline(server, token, by) when is_binary(token) and is_binary(by) and by != "",
    do: GenServer.call(server, {:decline, token, by}, :infinity)

  @doc "Abandon a parked ASK with `{:close, reason}`; `reason` is a non-nil atom."
  @spec close(GenServer.server(), String.t(), atom()) :: :ok | {:error, term()}
  def close(server, token, reason)
      when is_binary(token) and is_atom(reason) and not is_nil(reason),
      do: GenServer.call(server, {:close, token, reason}, :infinity)

  @doc "Parked ASKs: `[%{group_id, intent, prompts, expires_at}]`, oldest first."
  @spec parked(GenServer.server(), timeout()) :: [map()]
  def parked(server, timeout \\ :infinity), do: GenServer.call(server, :parked, timeout)

  @doc "The account this executor sends orders for (its `:account_number`)."
  @spec account(GenServer.server(), timeout()) :: String.t()
  def account(server, timeout \\ 5_000), do: GenServer.call(server, :account, timeout)

  @doc """
  The kill switch's order step: list the account's open agent-initiated
  equity orders (`get_equity_orders` with `agent_initiated: true`, once
  per open state, every page) and its pending trade approvals
  (`get_trade_approvals`, every page), then cancel every order and decline
  every approval through `Raxol.Broker.Executor.Place`, all at once, each
  call bounded by `bound` milliseconds. Every cancel and decline is its own
  journaled group, under an intent id unique to this kill
  (`cancel-<order id>-<kill id>`), so a later kill sends again a cancel an
  earlier one could not confirm. Cancels and declines are built with
  `:human` provenance and run whatever the mode.

  `{:ok, %{orders: listed, approvals: listed, results: results}}`, where a
  listing is `{:ok, ids}`, or `{:error, {:incomplete, ids, reasons}}` when
  some listing failed (the ids that were read are still cancelled), and
  `results` are `%{kind, id, group_id, outcome}`; or `{:error,
  :port_not_ready}`.
  """
  @spec halt_orders(GenServer.server(), pos_integer()) :: {:ok, map()} | {:error, term()}
  def halt_orders(server, bound) when is_integer(bound) and bound > 0,
    do: GenServer.call(server, {:halt_orders, bound}, :infinity)

  @doc """
  Reconcile now (see "Reconciliation"), each read bounded by `bound`
  milliseconds: `{:ok, [%{group_id, intent_id, resolution}]}` for the
  groups it resolved, or `{:error, reason}`.
  """
  @spec reconcile(GenServer.server(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def reconcile(server, bound \\ @default_timeout) when is_integer(bound) and bound > 0,
    do: GenServer.call(server, {:reconcile, bound}, :infinity)

  @doc """
  Wait until the port session is ready: `:ok`, or `{:error, :port_not_ready}`
  once `timeout` milliseconds pass first. Answered even while a review is in
  flight. A timeout above 4_294_000_000 ms is `{:error, {:invalid_timeout,
  :await_port, timeout}}`.
  """
  @spec await_port(GenServer.server(), non_neg_integer()) ::
          :ok | {:error, :port_not_ready | {:invalid_timeout, :await_port, term()}}
  def await_port(server, timeout \\ @default_timeout) when is_integer(timeout) and timeout >= 0,
    do: GenServer.call(server, {:await_port, timeout}, :infinity)

  @doc """
  A child spec whose `:shutdown` covers one place call (`place_timeout +
  5_000`, or the `:shutdown` option), so a supervisor stopping the executor
  mid-place waits for the order response. A `:shutdown` that is not a
  positive integer raises `ArgumentError`.
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    %{
      id: __MODULE__,
      start: {__MODULE__, :start_link, [opts]},
      shutdown: shutdown(opts)
    }
  end

  defp shutdown(opts) do
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

  defp place_shutdown(ms) when is_integer(ms) and ms > 0 and ms <= @max_timeout, do: ms + 5_000
  defp place_shutdown(_unset_or_refused), do: @default_timeout + 5_000

  # The receipt key lives in the executor's own process dictionary, so it is
  # nil in every other process. `Raxol.Broker.Executor.Place` verifies
  # receipts with it, which means only this process can place.
  @doc false
  @spec receipt_key() :: binary() | nil
  def receipt_key, do: Process.get({__MODULE__, :receipt_key})

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)

    with {:ok, config} <- check_opts(opts),
         {:ok, client_spec} <- prepare_port(config),
         {:ok, journal_ref} <- monitor_journal(config.journal),
         :ok <- safe(fn -> Journal.claim(config.journal) end) do
      state = base_state(config, client_spec, journal_ref)
      Process.put({__MODULE__, :receipt_key}, state.key)
      close_orphans(state)
      {:ok, state, {:continue, :connect}}
    else
      {:error, reason} -> {:stop, reason}
    end
  end

  # `:journal` comes first: a `{:via, module, name}` or `{:global, name}`
  # would run caller code in this process to resolve it.
  defp check_opts(opts) do
    with {:ok, journal} <- fetch_journal(opts),
         {:ok, timeouts} <- fetch_timeouts(opts),
         {:ok, clock} <- fetch_clock(opts),
         {:ok, mode} <- check_mode(Keyword.get(opts, :mode, :dry_run)),
         {:ok, account} <- fetch_account(opts),
         {:ok, policy} <- fetch_policy(opts),
         {:ok, session} <- fetch_session(opts),
         {:ok, credential} <- fetch_credential(opts) do
      {:ok,
       Map.merge(timeouts, %{
         journal: journal,
         strategies: Keyword.get(opts, :strategies, Raxol.Broker.Strategy.Supervisor),
         clock: clock,
         mode: mode,
         account: account,
         policy: policy,
         session: session,
         credential: credential
       })}
    end
  end

  defp fetch_timeouts(opts) do
    with {:ok, review_timeout} <- fetch_timeout(opts, :review_timeout),
         {:ok, place_timeout} <- fetch_timeout(opts, :place_timeout),
         {:ok, reconnect_ms} <- fetch_timeout(opts, :reconnect_ms, @default_reconnect_ms),
         {:ok, reconcile_ms} <- fetch_timeout(opts, :reconcile_ms, @default_reconcile_ms),
         {:ok, min_age} <- fetch_min_age(opts) do
      {:ok,
       %{
         review_timeout: review_timeout,
         place_timeout: place_timeout,
         reconnect_ms: reconnect_ms,
         reconcile_ms: reconcile_ms,
         reconcile_min_age_ms: min_age
       }}
    end
  end

  defp fetch_min_age(opts) do
    case Keyword.get(opts, :reconcile_min_age_ms, @default_reconcile_min_age_ms) do
      ms when is_integer(ms) and ms >= 0 and ms <= @max_timeout -> {:ok, ms}
      other -> {:error, {:invalid_timeout, :reconcile_min_age_ms, other}}
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

  # Pure: refuses a live spec in dry run before anything connects.
  defp prepare_port(config) do
    PortMCP.prepare(session_spec(config.session, config.credential),
      mode: config.mode,
      call_timeout: max(config.review_timeout, config.place_timeout),
      reconnect_ms: config.reconnect_ms
    )
  end

  defp session_spec(session, nil), do: session
  defp session_spec(session, %{credential: credential}), do: Session.spec(credential, session)

  # The claim lives in the journal's memory, so a journal restart drops it.
  # The executor stops with the journal; its supervisor restarts it, and the
  # new one claims again and closes the groups this one left open.
  defp monitor_journal(journal) when is_pid(journal), do: {:ok, Process.monitor(journal)}

  defp monitor_journal(journal) do
    case Process.whereis(journal) do
      pid when is_pid(pid) -> {:ok, Process.monitor(pid)}
      nil -> {:error, :journal_not_running}
    end
  end

  defp base_state(config, client_spec, journal_ref) do
    %{
      journal: config.journal,
      journal_ref: journal_ref,
      clock: config.clock,
      strategies: config.strategies,
      mode: config.mode,
      account: config.account,
      policy: config.policy,
      review_timeout: config.review_timeout,
      place_timeout: config.place_timeout,
      key: :crypto.strong_rand_bytes(32),
      session: config.session,
      credential: config.credential,
      refresh: nil,
      refresh_timer: nil,
      restart_port: false,
      client_spec: client_spec,
      port: nil,
      port_status: :connecting,
      connect: nil,
      catalog: %{},
      reconnect_ms: config.reconnect_ms,
      backoff: config.reconnect_ms,
      port_waiters: %{},
      parked: %{},
      busy: nil,
      queue: :queue.new(),
      reconcile_ms: config.reconcile_ms,
      reconcile_min_age_ms: config.reconcile_min_age_ms,
      reconciled: false
    }
  end

  defp check_mode(mode) when mode in [:dry_run, :live], do: {:ok, mode}
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

  # A live session's spec may be empty: `Raxol.Broker.Session.spec/2` fills
  # in Robinhood's URL.
  defp fetch_session(opts) do
    case {Keyword.get(opts, :session), Keyword.has_key?(opts, :credential)} do
      {spec, _live} when is_list(spec) and spec != [] -> {:ok, spec}
      {nil, true} -> {:ok, []}
      _ -> {:error, :session_required}
    end
  end

  # The store reads a key through a provider module the caller chose, so the
  # read runs in a task, never in this process.
  defp fetch_credential(opts) do
    case Keyword.fetch(opts, :credential) do
      :error ->
        {:ok, nil}

      {:ok, credential_opts} when is_list(credential_opts) ->
        store = Keyword.get(credential_opts, :store, [])

        case in_task(fn -> CredentialStore.fetch(store) end, @store_timeout) do
          {:ok, %Credential{} = credential} ->
            {:ok,
             %{
               credential: credential,
               store: store,
               auth: Keyword.get(credential_opts, :auth, []),
               skew: Keyword.get(credential_opts, :refresh_skew, @default_skew)
             }}

          {:error, reason} ->
            {:error, {:no_credential, reason}}
        end

      {:ok, other} ->
        {:error, {:invalid_credential, other}}
    end
  end

  defp in_task(fun, timeout) do
    task = Task.async(fun)

    case Task.yield(task, timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, result} -> result
      {:exit, reason} -> {:error, {:crashed, reason}}
      nil -> {:error, :timeout}
    end
  end

  # A group the journal still has open was parked or mid-flight in an
  # executor that is gone; nothing may resume it.
  defp close_orphans(state) do
    case safe(fn -> Journal.open_groups(state.journal) end) do
      {:ok, ids} ->
        Enum.each(ids, &close_group(state, &1, :executor_restarted))

      {:error, reason} ->
        Logger.warning(
          "[Broker.Executor] could not list open groups: #{inspect(reason, structs: false)}"
        )
    end
  end

  @impl GenServer
  def handle_call(:account, _from, state), do: {:reply, state.account, state}

  def handle_call(:parked, _from, state) do
    list =
      state.parked
      |> Enum.sort_by(fn {_id, group} -> group.seq end)
      |> Enum.map(fn {id, group} ->
        %{
          group_id: id,
          intent: group.intent,
          prompts: group.prompts,
          expires_at: group.expires_at
        }
      end)

    {:reply, list, state}
  end

  def handle_call({:await_port, _timeout}, _from, %{port_status: :ready} = state),
    do: {:reply, :ok, state}

  def handle_call({:await_port, timeout}, from, state)
      when is_integer(timeout) and timeout >= 0 and timeout <= @max_timeout do
    timer = Process.send_after(self(), {:await_port_timeout, from}, timeout)
    {:noreply, %{state | port_waiters: Map.put(state.port_waiters, from, timer)}}
  end

  def handle_call({:await_port, timeout}, _from, state),
    do: {:reply, {:error, {:invalid_timeout, :await_port, timeout}}, state}

  # Halt alone bypasses ordinary work. Read tasks never own the journal
  # claim or a receipt key, and their refs are discarded before cancellation.
  def handle_call(
        {:halt_orders, _bound} = request,
        {pid, _tag} = from,
        %{busy: %{stage: :halt}} = state
      ) do
    entry = {request, from, Process.monitor(pid)}
    {:noreply, %{state | queue: :queue.in_r(entry, state.queue)}}
  end

  def handle_call({:halt_orders, _bound} = request, from, state) do
    state = interrupt_read(state)

    case dispatch(request, from, state) do
      {:reply, reply, state} -> {:reply, reply, drain_later(state)}
      {:await, state} -> {:noreply, state}
    end
  end

  # Ordinary requests keep arrival order, even while waiting for :drain.
  def handle_call(request, {pid, _tag} = from, state) do
    if state.busy == nil and :queue.is_empty(state.queue) do
      case dispatch(request, from, state) do
        {:reply, reply, state} -> {:reply, reply, state}
        {:await, state} -> {:noreply, state}
      end
    else
      entry = {request, from, Process.monitor(pid)}
      {:noreply, %{state | queue: :queue.in(entry, state.queue)}}
    end
  end

  @impl GenServer
  def handle_continue(:connect, state), do: {:noreply, state |> schedule_refresh() |> connect()}

  @impl GenServer
  def handle_info({ref, result}, %{busy: %{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    stage_done(state, result)
  end

  def handle_info({ref, result}, %{connect: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, connected(%{state | connect: nil}, result)}
  end

  def handle_info({ref, result}, %{refresh: %Task{ref: ref}} = state) do
    Process.demonitor(ref, [:flush])
    {:noreply, refreshed(%{state | refresh: nil}, result)}
  end

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{busy: %{ref: ref} = pending} = state),
    do: stage_done(state, stage_crashed(pending.stage, reason))

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{connect: %Task{ref: ref}} = state),
    do: {:noreply, connected(%{state | connect: nil}, {:error, {:connect_crashed, reason}})}

  def handle_info({:DOWN, ref, :process, _pid, reason}, %{refresh: %Task{ref: ref}} = state),
    do: {:noreply, refreshed(%{state | refresh: nil}, {:error, {:refresh_crashed, reason}})}

  # Queued callers get an exit from their call; linked read tasks die with
  # this process; the next executor closes groups left open.
  def handle_info({:DOWN, ref, :process, _pid, reason}, %{journal_ref: ref} = state) do
    Logger.warning("[Broker.Executor] journal went down: #{inspect(reason, structs: false)}")
    {:stop, {:journal_down, reason}, state}
  end

  # A queued caller died: drop its request.
  def handle_info({:DOWN, ref, :process, _pid, _reason}, state) do
    {gone, queue} = :queue.to_list(state.queue) |> Enum.split_with(&(elem(&1, 2) == ref))
    Enum.each(gone, fn {request, _from, _ref} -> dropped(request) end)
    {:noreply, %{state | queue: :queue.from_list(queue)}}
  end

  # The connect task is shut down for its side effect only; the state is
  # updated whatever `Task.shutdown/2` returns.
  def handle_info({:EXIT, pid, reason}, %{port: {PortMCP, %PortMCP{pid: pid}}} = state) do
    if state.connect, do: Task.shutdown(state.connect, :brutal_kill)
    {:noreply, port_failed(%{state | port: nil, connect: nil}, {:port_exited, reason})}
  end

  # Review, clock and connect tasks are linked; their exits are handled
  # through their monitors. A port this process stopped exits here too.
  def handle_info({:EXIT, _pid, _reason}, state), do: {:noreply, state}

  def handle_info(:reconnect, %{port: nil} = state), do: {:noreply, connect(state)}

  def handle_info(:refresh_due, state),
    do: {:noreply, start_refresh(%{state | refresh_timer: nil})}

  def handle_info({:ask_timeout, group_id}, state),
    do: {:noreply, ask_timed_out(state, group_id)}

  # Periodic reconciliation uses the same serialized read stage as a
  # caller's request. A busy executor leaves it until the next interval.
  def handle_info(:reconcile, state) do
    Process.send_after(self(), :reconcile, state.reconcile_ms)

    if state.busy == nil and :queue.is_empty(state.queue) do
      case dispatch({:reconcile, state.review_timeout}, nil, state) do
        {:reply, reply, state} ->
          reply_to(nil, reply)
          {:noreply, state}

        {:await, state} ->
          {:noreply, state}
      end
    else
      {:noreply, state}
    end
  end

  # A :drain left over from an earlier turn may arrive during a read stage;
  # stage_done/2 sends a fresh one when it finishes.
  def handle_info(:drain, %{busy: nil} = state), do: {:noreply, drain(state)}
  def handle_info(:drain, state), do: {:noreply, state}

  def handle_info({:await_port_timeout, from}, state) do
    case Map.pop(state.port_waiters, from) do
      {nil, _waiters} ->
        {:noreply, state}

      {_timer, waiters} ->
        GenServer.reply(from, {:error, :port_not_ready})
        {:noreply, %{state | port_waiters: waiters}}
    end
  end

  # Only the shape is logged: the message is any term, and inspecting a
  # struct would run its Inspect implementation here.
  def handle_info(message, state) do
    Logger.debug("[Broker.Executor] unexpected message: #{shape(message)}")
    {:noreply, state}
  end

  # Nothing is cast to the executor. The default clause would crash it, and
  # the crash report would inspect the message in this process.
  @impl GenServer
  def handle_cast(message, state) do
    Logger.debug("[Broker.Executor] unexpected cast: #{shape(message)}")
    {:noreply, state}
  end

  defp shape(message) when is_tuple(message) and tuple_size(message) > 0,
    do: "{#{inspect(elem(message, 0), structs: false)}, ...}"

  defp shape(_message), do: "term"

  @impl GenServer
  def terminate(_reason, %{port: nil}), do: :ok
  def terminate(_reason, state), do: Port.stop(state.port)

  # -- Port ---------------------------------------------------------------------

  # The client connects on its own (retrying a failed connect with backoff
  # from `:reconnect_ms`); a task waits for it, so this process keeps
  # answering meanwhile.
  defp connect(state) do
    case PortMCP.start_client(state.client_spec) do
      {:ok, port} ->
        account = state.account
        task = Task.async(fn -> await_catalog(port, account) end)
        %{state | port: port, port_status: :connecting, connect: task}

      {:error, reason} ->
        port_failed(state, {:connect_failed, reason})
    end
  end

  # The session's tool classes: the live list reconciled against the frozen
  # capture (`Raxol.Broker.Tools.Catalog`). A port whose list cannot be read
  # never becomes ready, so no tool is ever called unclassified; nor one
  # whose `get_accounts` does not mark this executor's account as the
  # agentic one (`Raxol.Broker.AccountPin`).
  defp await_catalog(port, account) do
    with :ok <- PortMCP.await_ready(port),
         {:ok, tools} <- PortMCP.list_tools(port),
         catalog = Catalog.reconcile(tools),
         :ok <- AccountPin.check(Read.call(port, catalog, "get_accounts", %{}, 30_000), account) do
      {:ok, catalog}
    end
  end

  defp connected(state, {:ok, catalog}) do
    Enum.each(state.port_waiters, fn {from, timer} ->
      Process.cancel_timer(timer)
      GenServer.reply(from, :ok)
    end)

    unless state.reconciled, do: send(self(), :reconcile)

    %{
      state
      | port_status: :ready,
        catalog: catalog,
        backoff: state.reconnect_ms,
        port_waiters: %{},
        reconciled: true
    }
  end

  # A 401 at connect means the token is stale: refresh it, and reconnect
  # once the refresh lands.
  defp connected(%{port: port} = state, {:error, reason}) do
    if port, do: Port.stop(port)
    state = %{state | port: nil}

    if state.credential != nil and unauthorized?(reason) do
      Logger.warning("[Broker.Executor] the session's token was refused at connect; refreshing")
      start_refresh(%{state | port_status: {:down, :unauthorized}})
    else
      port_failed(state, {:connect_failed, reason})
    end
  end

  defp unauthorized?({:http, 401}), do: true

  defp unauthorized?(reason) when is_tuple(reason),
    do: reason |> Tuple.to_list() |> Enum.any?(&unauthorized?/1)

  defp unauthorized?(_reason), do: false

  defp port_failed(state, reason) do
    Logger.warning(
      "[Broker.Executor] port not ready (#{inspect(reason, structs: false)}); " <>
        "reconnecting in #{state.backoff} ms"
    )

    Process.send_after(self(), :reconnect, state.backoff)

    %{
      state
      | port_status: {:down, reason},
        backoff: min(state.backoff * 2, @max_backoff)
    }
  end

  @impl GenServer
  def format_status(status) do
    Map.new(status, fn
      # `client_spec` and `session` carry the bearer header of a live session.
      {:state, %{} = state} ->
        {:state,
         %{
           state
           | key: :redacted,
             credential: state.credential && :redacted,
             client_spec: :redacted,
             session: :redacted
         }}

      other ->
        other
    end)
  end

  # -- Credential ---------------------------------------------------------------

  defp schedule_refresh(
         %{credential: %{credential: %Credential{expires_at: %DateTime{}}}} = state
       ) do
    %{credential: credential, skew: skew} = state.credential
    if state.refresh_timer, do: Process.cancel_timer(state.refresh_timer)

    delay =
      credential.expires_at
      |> DateTime.add(-skew, :second)
      |> DateTime.diff(DateTime.utc_now(), :millisecond)
      |> max(0)
      |> min(@max_timeout)

    %{state | refresh_timer: Process.send_after(self(), :refresh_due, delay)}
  end

  defp schedule_refresh(state), do: state

  # The refresh grant and the store run in a task: the store's key provider
  # and the auth options are caller code.
  defp start_refresh(%{refresh: %Task{}} = state), do: state
  defp start_refresh(%{credential: nil} = state), do: state

  defp start_refresh(%{credential: held} = state) do
    task = Task.async(fn -> Session.refresh(held.credential, held.store, held.auth) end)
    %{state | refresh: task}
  end

  defp refreshed(state, {:ok, credential}), do: use_credential(state, credential)

  defp refreshed(state, {:unpersisted, credential, reason}) do
    Logger.error(
      "[Broker.Executor] refreshed, but the rotated credential could not be stored " <>
        "(#{inspect(reason, structs: false)}); it is used until this executor stops"
    )

    use_credential(state, credential)
  end

  # Robinhood refusing the refresh token means the grant is gone: disarm,
  # so signing in again needs a fresh arm. The refresh keeps retrying, and
  # `Session.refresh/3` takes over the credential a new sign-in stores.
  defp refreshed(state, {:error, reason}) do
    if rejected?(reason) do
      Logger.error(
        "[Broker.Executor] Robinhood refused the refresh token " <>
          "(#{inspect(reason, structs: false)}); disarmed until a new sign-in and arm"
      )

      case Journal.mode(state.journal) do
        {:ok, :disarmed, %{"reason" => "reauth_required"}} -> :ok
        _other -> Mode.disarm("reauth_required", journal: state.journal, by: "executor")
      end
    else
      Logger.warning(
        "[Broker.Executor] token refresh failed (#{inspect(reason, structs: false)}); " <>
          "retrying in #{@refresh_retry_ms} ms"
      )
    end

    %{state | refresh_timer: Process.send_after(self(), :refresh_due, @refresh_retry_ms)}
  end

  defp rejected?({:token_rejected, status, _code}) when status in [400, 401], do: true
  defp rejected?(:no_refresh_token), do: true
  defp rejected?(_transient), do: false

  defp use_credential(state, credential) do
    state = %{state | credential: %{state.credential | credential: credential}}

    case prepare_port(state) do
      {:ok, client_spec} ->
        %{state | client_spec: client_spec} |> schedule_refresh() |> restart_port()

      {:error, reason} ->
        Logger.error(
          "[Broker.Executor] refreshed session refused: #{inspect(reason, structs: false)}"
        )

        state
    end
  end

  # A review in flight finishes on the old session first.
  defp restart_port(%{busy: %{}} = state), do: %{state | restart_port: true}

  defp restart_port(state) do
    if state.connect, do: Task.shutdown(state.connect, :brutal_kill)
    if state.port, do: Port.stop(state.port)
    connect(%{state | port: nil, connect: nil, restart_port: false, port_status: :connecting})
  end

  # -- Dispatch -----------------------------------------------------------------

  defp dispatch({:run, intent, context}, from, state) do
    case Policy.normalize(intent, context) do
      {:ok, intent, context} -> awaiting(run_intent(state, intent, context), from)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp dispatch({:approve, token, by}, from, state),
    do: awaiting(approve_parked(state, token, by), from)

  defp dispatch({:decline, token, by}, _from, state),
    do: finish_parked(state, token, {:approval, :declined, by})

  defp dispatch({:close, token, reason}, _from, state),
    do: finish_parked(state, token, {:close, reason})

  defp dispatch({:halt_orders, bound}, from, state),
    do: awaiting(halt_orders_now(state, bound), from)

  defp dispatch({:reconcile, bound}, from, state),
    do: awaiting(reconcile_now(state, bound), from)

  defp dispatch(_request, _from, state), do: {:reply, {:error, :unknown_request}, state}

  defp awaiting({:await, pending, state}, from),
    do: {:await, %{state | busy: Map.put(pending, :from, from)}}

  defp awaiting(done, _from), do: done

  defp stage_done(%{busy: pending} = state, result) do
    case complete_stage(%{state | busy: nil}, pending, result) do
      {:reply, reply, state} ->
        reply_to(pending.from, reply)
        state = if state.restart_port, do: restart_port(state), else: state
        {:noreply, drain_later(state)}

      {:await, next, state} ->
        {:await, state} = awaiting({:await, next, state}, pending.from)
        {:noreply, state}
    end
  end

  defp complete_stage(state, %{stage: :review} = pending, result),
    do: reviewed(state, pending, result)

  defp complete_stage(state, %{stage: :context, intent: intent}, {:ok, context}) do
    with :ok <- port_up(state),
         {:ok, group_id} <- open(state, intent, context, true) do
      pre_review(state, intent, context, group_id, armed?(state, intent))
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp complete_stage(state, %{stage: :approval_context} = pending, {:ok, context}),
    do: approved(state, pending.group_id, pending.group, pending.by, context)

  defp complete_stage(state, %{stage: :reconcile}, {:ok, resolved}),
    do: {:reply, journal_resolutions(state, resolved), state}

  defp complete_stage(state, %{stage: :halt, bound: bound}, {:ok, orders, approvals}),
    do: halt_orders_listed(state, bound, orders, approvals)

  defp complete_stage(state, _pending, {:error, reason}),
    do: {:reply, {:error, reason}, state}

  defp stage_crashed(:review, reason), do: {:error, {:review_crashed, reason}}
  defp stage_crashed(stage, reason), do: {:error, {stage, {:crashed, reason}}}

  defp reply_to(nil, {:error, reason}),
    do: Logger.warning("[Broker.Executor] reconcile failed: #{inspect(reason, structs: false)}")

  defp reply_to(nil, _reply), do: :ok
  defp reply_to(from, reply), do: GenServer.reply(from, reply)

  defp read_stage(state, stage, pending, fun) do
    task = Task.async(fun)
    {:await, Map.merge(pending, %{stage: stage, ref: task.ref, pid: task.pid}), state}
  end

  defp context_stage(state, stage, pending, context, intent) do
    env = Map.take(state, [:clock, :journal, :policy, :port, :catalog, :account, :review_timeout])

    read_stage(state, stage, pending, fn -> fill(env, context, intent) end)
  end

  defp interrupt_read(%{busy: nil} = state), do: state

  defp interrupt_read(%{busy: pending} = state) do
    Process.demonitor(pending.ref, [:flush])
    Process.exit(pending.pid, :kill)

    state =
      case Map.fetch(pending, :group_id) do
        {:ok, group_id} ->
          _ = close_group(state, group_id, :not_armed)
          %{state | parked: Map.delete(state.parked, group_id)}

        :error ->
          state
      end

    reason = if pending.stage == :reconcile, do: :halted, else: :not_armed
    reply_to(pending.from, {:error, reason})
    %{state | busy: nil}
  end

  defp drain(%{busy: nil} = state) do
    case :queue.out(state.queue) do
      {:empty, _queue} ->
        state

      {{:value, entry}, queue} ->
        drain_entry(%{state | queue: queue}, entry)
    end
  end

  # A caller that died while queued is never dispatched: its order would be
  # placed with nobody to receive the result. Its monitor tells: a DOWN
  # already delivered (but not yet handled) makes the demonitor report
  # false. `Process.alive?/1` is only asked about a local pid.
  #
  # At most one request is dispatched per callback, so one callback never
  # runs more than one place call: the rest wait for a `:drain` message,
  # and the shutdown bound covers the one in progress.
  defp drain_entry(state, {request, {pid, _tag} = from, ref}) do
    if Process.demonitor(ref, [:flush, :info]) and (node(pid) != node() or Process.alive?(pid)) do
      case dispatch(request, from, state) do
        {:reply, reply, state} ->
          GenServer.reply(from, reply)
          drain_later(state)

        {:await, state} ->
          state
      end
    else
      dropped(request)
      drain(state)
    end
  end

  defp drain_later(state) do
    unless :queue.is_empty(state.queue), do: send(self(), :drain)
    state
  end

  defp dropped(request),
    do: Logger.info("[Broker.Executor] dropped a queued #{request_kind(request)}: caller is gone")

  defp request_kind(request) when is_tuple(request) and is_atom(elem(request, 0)),
    do: elem(request, 0)

  defp request_kind(_request), do: :request

  # -- Pipeline -----------------------------------------------------------------

  defp run_intent(state, intent, context) do
    with :ok <- port_up(state),
         :ok <- not_parked(state, intent),
         {:ok, nil} <- placed_before(state, intent),
         {:ok, _tool} <- Review.tool(intent) do
      if armed?(state, intent) do
        context_stage(
          state,
          :context,
          %{intent: intent},
          %{context | review_warnings: []},
          intent
        )
      else
        with {:ok, group_id} <- open(state, intent, %Context{policy: state.policy}, false) do
          not_armed(state, group_id)
        else
          {:error, reason} -> {:reply, {:error, reason}, state}
        end
      end
    else
      {:ok, group_id} when is_binary(group_id) -> {:reply, {:ok, :duplicate}, state}
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  # Every intent, cancels included, needs the latest mode record to say armed.
  defp armed?(state, _intent), do: Mode.current(state.journal) == :armed

  defp port_up(%{port_status: :ready}), do: :ok
  defp port_up(_state), do: {:error, :port_not_ready}

  defp not_parked(state, intent) do
    case Enum.find(state.parked, fn {_id, group} -> group.intent.id == intent.id end) do
      nil -> :ok
      {id, _group} -> {:error, {:parked, id}}
    end
  end

  defp placed_before(state, intent),
    do: safe(fn -> Journal.placing_for_intent(intent.id, state.journal) end)

  defp open(state, intent, context, armed?) do
    mode = if armed? and Mode.current(state.journal) == :armed, do: :armed, else: :dry_run
    safe(fn -> Journal.open_group(intent, context, state.journal, mode: mode) end)
  end

  defp pre_review(state, intent, context, group_id, armed?) do
    verdict = Policy.evaluate(intent, context)

    case {append(state, group_id, {:verdict, :pre_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        {:reply, {:error, reason}, state}

      {:ok, {:deny, {:drawdown_breaker, detail} = reason}} ->
        Halt.pause(:drawdown_halt,
          journal: state.journal,
          strategies: state.strategies,
          detail: %{"group_id" => group_id, "detail" => Codec.term(detail)}
        )

        {:reply, {:deny, group_id, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, _allow_or_ask} when not armed? ->
        _ = close_group(state, group_id, :not_armed)
        {:reply, {:error, :not_armed}, state}

      {:ok, _allow_or_ask} ->
        review(state, intent, context, group_id)
    end
  end

  defp review(state, intent, context, group_id) do
    %{port: port, catalog: catalog, account: account, review_timeout: timeout} = state
    task = Task.async(fn -> Review.run(port, catalog, intent, account, timeout) end)
    pending = %{stage: :review, ref: task.ref, pid: task.pid, intent: intent, context: context}
    {:await, Map.put(pending, :group_id, group_id), state}
  end

  defp reviewed(state, %{group_id: group_id}, {:error, reason}) do
    _ = close_group(state, group_id, :review_failed)
    {:reply, {:error, reason}, state}
  end

  defp reviewed(state, pending, {:ok, response, warnings}) do
    pending =
      pending
      |> Map.put(:context, %{pending.context | review_warnings: warnings})
      |> Map.put(:customer_approval_required, Review.customer_approval_required?(response))

    case append(state, pending.group_id, {:review, response}) do
      :ok -> post_review(state, pending)
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp post_review(state, %{intent: intent, group_id: group_id} = pending) do
    receipt = ReviewReceipt.issue(state.key, intent, group_id)
    verdict = Policy.evaluate(intent, pending.context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        {:reply, {:error, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, {:ask, prompts}} ->
        park(state, pending, receipt, prompts)

      {:ok, {:allow, _intent}} ->
        place(state, intent, group_id, receipt, pending.customer_approval_required)
    end
  end

  # The timeout timer is this process's: an ASK nobody answers is denied
  # whether or not anything shows it.
  defp park(state, %{group_id: group_id} = pending, receipt, prompts) do
    timeout = Keyword.fetch!(state.policy, :ask_timeout)
    Process.send_after(self(), {:ask_timeout, group_id}, timeout)

    group = %{
      intent: pending.intent,
      context: pending.context,
      receipt: receipt,
      prompts: prompts,
      customer_approval_required: pending.customer_approval_required,
      expires_at: DateTime.add(DateTime.utc_now(), timeout, :millisecond),
      seq: System.unique_integer([:monotonic])
    }

    parked = Map.put(state.parked, group_id, group)
    {:reply, {:ask, group_id, prompts}, %{state | parked: parked}}
  end

  # A timer for a group answered meanwhile finds nothing parked.
  defp ask_timed_out(state, group_id) do
    case Map.pop(state.parked, group_id) do
      {nil, _parked} ->
        state

      {_group, parked} ->
        verdict = {:deny, {:ask_timeout, %{ms: Keyword.fetch!(state.policy, :ask_timeout)}}}

        with {:error, _reason} <- append(state, group_id, {:verdict, :post_review, verdict}),
             do: close_group(state, group_id, :ask_timeout)

        %{state | parked: parked}
    end
  end

  # Everything before the approval is journaled leaves the group parked.
  defp approve_parked(state, token, by) do
    with :ok <- port_up(state),
         {:ok, group} <- fetch_parked(state, token) do
      if armed?(state, group.intent) do
        context_stage(
          state,
          :approval_context,
          %{group_id: token, group: group, by: by},
          group.context,
          group.intent
        )
      else
        not_armed(%{state | parked: Map.delete(state.parked, token)}, token)
      end
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp fetch_parked(state, token) do
    case Map.fetch(state.parked, token) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, {:not_parked, token}}
    end
  end

  defp approved(state, group_id, group, by, context) do
    unparked = %{state | parked: Map.delete(state.parked, group_id)}

    with :ok <- safe(fn -> Journal.record_context(group_id, context, state.journal) end),
         :ok <- append(state, group_id, {:approval, :approved, by}) do
      recheck(unparked, group_id, group, context)
    else
      {:error, {:invalid_entry, _} = reason} ->
        {:reply, {:error, reason}, state}

      {:error, reason} ->
        _ = close_group(unparked, group_id, :approval_failed)
        {:reply, {:error, reason}, unparked}
    end
  end

  defp recheck(state, group_id, group, context) do
    verdict = Policy.evaluate(group.intent, context)

    case {append(state, group_id, {:verdict, :post_review, verdict}), verdict} do
      {{:error, reason}, _verdict} ->
        _ = close_group(state, group_id, :approval_failed)
        {:reply, {:error, reason}, state}

      {:ok, {:deny, {:drawdown_breaker, detail} = reason}} ->
        Halt.pause(:drawdown_halt,
          journal: state.journal,
          strategies: state.strategies,
          detail: %{"group_id" => group_id, "detail" => Codec.term(detail)}
        )

        {:reply, {:deny, group_id, reason}, state}

      {:ok, {:deny, reason}} ->
        {:reply, {:deny, group_id, reason}, state}

      {:ok, _ask_answered_or_allow} ->
        place(state, group.intent, group_id, group.receipt, group.customer_approval_required)
    end
  end

  # Dropped from the parked map whatever the journal says: without its
  # receipt the group can never reach `placing`.
  defp finish_parked(state, token, entry) do
    case Map.pop(state.parked, token) do
      {nil, _parked} -> {:reply, {:error, {:not_parked, token}}, state}
      {_group, parked} -> {:reply, append(state, token, entry), %{state | parked: parked}}
    end
  end

  # The port can go down between review and here (its EXIT handled before
  # the review result): close the group without `placing`, send nothing.
  # So can the mode: a disarm while the group was parked or in review.
  defp place(%{port_status: status, port: port} = state, _intent, group_id, _receipt, _approval)
       when status != :ready or is_nil(port) do
    _ = close_group(state, group_id, :port_not_ready)
    {:reply, {:error, :port_not_ready}, state}
  end

  defp place(state, intent, group_id, receipt, customer_approval_required) do
    if armed?(state, intent),
      do: send_order(state, intent, group_id, receipt, customer_approval_required),
      else: not_armed(state, group_id)
  end

  defp not_armed(state, group_id) do
    _ = close_group(state, group_id, :not_armed)
    {:reply, {:error, :not_armed}, state}
  end

  defp send_order(state, intent, group_id, receipt, customer_approval_required) do
    env = %{
      port: state.port,
      catalog: state.catalog,
      journal: state.journal,
      account: state.account,
      timeout: state.place_timeout,
      customer_approval_required: customer_approval_required
    }

    reply =
      case Place.run(receipt, intent, group_id, env) do
        {:ok, status, response} ->
          {:ok, %{group_id: group_id, status: status, response: response, journaled: true}}

        {:error, {:order_unjournaled, status, response, reason}} ->
          {:ok,
           %{
             group_id: group_id,
             status: status,
             response: response,
             journaled: false,
             journal_error: reason
           }}

        # `placing` was refused, the receipt failed, or the intent has no
        # order tool: nothing was sent.
        {:error, reason} ->
          _ = close_group(state, group_id, :placing_refused)
          {:error, reason}
      end

    {:reply, reply, state}
  end

  # -- Reconciliation -------------------------------------------------------------

  @approvals_per_call 100

  defp reconcile_now(state, bound) do
    with :ok <- port_up(state),
         {:ok, entries} <- safe(fn -> Journal.unresolved(state.journal) end) do
      env = Map.take(state, [:port, :catalog, :account, :clock, :reconcile_min_age_ms])

      read_stage(state, :reconcile, %{}, fn ->
        {unknown, pending} = Enum.split_with(entries, &(&1["status"] == "unknown"))
        {:ok, resolve_unknown(env, unknown, bound) ++ resolve_pending(env, pending, bound)}
      end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp journal_resolutions(state, resolved) do
    for {entry, resolution, detail} <- resolved do
      with {:error, reason} <-
             Journal.resolve(entry["group_id"], resolution, detail, state.journal) do
        Logger.warning(
          "[Broker.Executor] resolution of #{entry["group_id"]} not journaled: " <>
            inspect(reason, structs: false)
        )
      end
    end

    {:ok,
     Enum.map(resolved, fn {entry, resolution, _detail} ->
       %{group_id: entry["group_id"], intent_id: entry["intent_id"], resolution: resolution}
     end)}
  end

  # Matched on the `ref_id` the place sent, across every page. Absence is
  # concluded only from a complete listing, for a `placing` old enough that
  # the order cannot still be on its way, and never for a group whose
  # review asked for the owner's approval (see "Reconciliation").
  defp resolve_unknown(_state, [], _bound), do: []

  defp resolve_unknown(state, [first | _] = entries, bound) do
    args = %{
      "account_number" => state.account,
      "agent_initiated" => true,
      "created_at_gte" => String.slice(first["at"], 0, 10)
    }

    case Read.listing(
           state.port,
           state.catalog,
           "get_equity_orders",
           args,
           ["orders", "results"],
           bound
         ) do
      {:ok, orders} ->
        by_ref = orders |> Enum.filter(&is_map/1) |> Map.new(&{order_ref(&1), &1})
        now = now(state.clock)

        Enum.flat_map(entries, fn entry ->
          case Map.fetch(by_ref, Place.ref_id(entry["intent_id"])) do
            {:ok, order} -> [{entry, "placed", order_detail(order)}]
            :error -> if absent?(state, entry, now), do: [{entry, "absent", %{}}], else: []
          end
        end)

      {:error, reason} ->
        Logger.warning(
          "[Broker.Executor] reconcile: orders unreadable or incomplete: " <>
            inspect(reason, structs: false)
        )

        []
    end
  end

  defp absent?(_state, %{"approval_required" => true}, _now), do: false
  defp absent?(_state, _entry, {:error, _reason}), do: false

  defp absent?(state, %{"at" => at}, {:ok, now}) do
    case DateTime.from_iso8601(at) do
      {:ok, placed_at, _offset} ->
        DateTime.diff(now, placed_at, :millisecond) >= state.reconcile_min_age_ms

      {:error, _reason} ->
        false
    end
  end

  defp order_ref(order), do: order["ref_id"] || get_in(order, ["args", "ref_id"])

  defp order_detail(order),
    do: %{"order_id" => order["order_id"] || order["id"], "state" => order["state"]}

  # Proposals are read back by the approval ids their place responses
  # carried; one still pending stays unresolved.
  defp resolve_pending(state, entries, bound) do
    entries
    |> Enum.filter(&is_binary(&1["approval_id"]))
    |> Enum.chunk_every(@approvals_per_call)
    |> Enum.flat_map(&resolve_pending_chunk(state, &1, bound))
  end

  defp resolve_pending_chunk(state, entries, bound) do
    ids = Enum.map(entries, & &1["approval_id"])
    args = %{"account_number" => state.account, "approval_ids" => ids}

    case Read.call(state.port, state.catalog, "get_trade_approvals", args, bound) do
      {:ok, body} ->
        approvals =
          body
          |> Response.list(["approvals", "results"])
          |> Enum.filter(&is_map/1)
          |> Map.new(&{&1["approval_id"] || &1["id"], &1})

        Enum.flat_map(entries, &approval_resolution(&1, approvals[&1["approval_id"]]))

      {:error, reason} ->
        Logger.warning(
          "[Broker.Executor] reconcile: approvals unreadable: #{inspect(reason, structs: false)}"
        )

        []
    end
  end

  defp approval_resolution(_entry, nil), do: []

  defp approval_resolution(entry, approval) do
    detail = %{
      "approval_id" => entry["approval_id"],
      "state" => approval["state"] || approval["status"],
      "order_id" => approval["order_id"]
    }

    case detail["state"] do
      state when state in ["approved", "auto_approved", "auto-approved"] ->
        [{entry, "approved", detail}]

      "declined" ->
        [{entry, "declined", detail}]

      "expired" ->
        [{entry, "expired", detail}]

      _pending ->
        []
    end
  end

  # -- Halt -----------------------------------------------------------------------

  # Robinhood lists open and closed orders together, newest first, a fixed
  # number per page: one listing per open state, every page, keeps closed
  # orders from pushing open ones off the first page. The states are read in
  # lifecycle order, so an order that moves on between two listings is read
  # by the later one.
  @open_states ["new", "unconfirmed", "queued", "confirmed", "partially_filled"]
  @closed_states ["filled", "cancelled", "canceled", "rejected", "failed", "expired", "voided"]

  # Open orders and pending approvals are listed through the read stage;
  # every cancel and decline gets its own group (no review tool, ALLOW by
  # policy), then `Place.run_many/3` sends them all at once under `bound`.
  defp halt_orders_now(state, bound) do
    with :ok <- port_up(state) do
      env = Map.take(state, [:port, :catalog, :account])

      read_stage(state, :halt, %{bound: bound}, fn ->
        account = %{"account_number" => env.account}

        orders =
          listings(env, bound, ["orders", "results"], "order_id", fn ->
            for s <- @open_states,
                do:
                  {"get_equity_orders",
                   Map.merge(account, %{"agent_initiated" => true, "state" => s})}
          end)

        approvals =
          listings(env, bound, ["approvals", "results"], "approval_id", fn ->
            [{"get_trade_approvals", account}]
          end)

        {:ok, orders, approvals}
      end)
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp halt_orders_listed(state, bound, orders, approvals) do
    with :ok <- port_up(state) do
      kill = Base.url_encode64(:crypto.strong_rand_bytes(6), padding: false)

      intents =
        halt_intents(orders, &Intent.cancel(&1, provenance: :human, id: "cancel-#{&1}-#{kill}")) ++
          halt_intents(
            approvals,
            &Intent.decline(&1, provenance: :human, id: "decline-#{&1}-#{kill}")
          )

      {ready, refused} =
        intents
        |> Enum.map(&open_unreviewed(state, &1))
        |> Enum.split_with(&match?({:ok, _item}, &1))

      sent = Place.run_many(Enum.map(ready, &elem(&1, 1)), send_env(state), bound)
      intent_of = Map.new(ready, fn {:ok, {_receipt, intent, group_id}} -> {group_id, intent} end)

      results =
        Enum.map(sent, fn {group_id, outcome} ->
          halt_result(Map.fetch!(intent_of, group_id), group_id, outcome)
        end) ++
          Enum.map(refused, fn {:error, intent, reason} -> halt_result(intent, nil, reason) end)

      {:reply, {:ok, %{orders: orders, approvals: approvals, results: results}}, state}
    else
      {:error, reason} -> {:reply, {:error, reason}, state}
    end
  end

  defp listings(state, bound, keys, id_key, calls) do
    {ids, errors} =
      Enum.reduce(calls.(), {[], []}, fn {tool, args}, {ids, errors} ->
        case Read.listing(state.port, state.catalog, tool, args, keys, bound) do
          {:ok, items} -> {ids ++ open_ids(items, id_key), errors}
          {:error, reason} -> {ids, [{tool, args["state"], reason} | errors]}
        end
      end)

    ids = Enum.uniq(ids)
    if errors == [], do: {:ok, ids}, else: {:error, {:incomplete, ids, Enum.reverse(errors)}}
  end

  defp open_ids(items, id_key) do
    items
    |> Enum.filter(&is_map/1)
    |> Enum.reject(&(&1["state"] in @closed_states))
    |> Enum.map(&(&1[id_key] || &1["id"]))
    |> Enum.filter(&(is_binary(&1) and &1 != ""))
  end

  defp halt_intents(listed, build) do
    ids =
      case listed do
        {:ok, ids} -> ids
        {:error, {:incomplete, ids, _reasons}} -> ids
      end

    Enum.flat_map(ids, fn id ->
      case build.(id) do
        {:ok, intent} -> [intent]
        {:error, _invalid_id} -> []
      end
    end)
  end

  defp open_unreviewed(state, intent) do
    # Human cancels and declines bypass trading rules and need no fetched
    # context, counters or caller clock, even when that clock is held.
    context = %Context{policy: state.policy}

    with {:ok, nil} <- placed_before(state, intent),
         {:ok, group_id} <- open(state, intent, context, true),
         verdict = Policy.evaluate(intent, context),
         :ok <- append(state, group_id, {:verdict, :pre_review, verdict}),
         {:ok, response, []} <- Review.run(nil, %{}, intent, state.account, state.review_timeout),
         :ok <- append(state, group_id, {:review, response}),
         :ok <- append(state, group_id, {:verdict, :post_review, verdict}) do
      {:ok, {ReviewReceipt.issue(state.key, intent, group_id), intent, group_id}}
    else
      {:ok, group_id} when is_binary(group_id) -> {:error, intent, {:duplicate, group_id}}
      {:error, reason} -> {:error, intent, reason}
    end
  end

  defp halt_result(intent, group_id, outcome) do
    %{kind: intent.kind, id: intent.order_id, group_id: group_id, outcome: outcome}
  end

  defp send_env(state) do
    %{
      port: state.port,
      catalog: state.catalog,
      journal: state.journal,
      account: state.account,
      timeout: state.place_timeout,
      customer_approval_required: false
    }
  end

  # -- Context and journal ------------------------------------------------------

  # The day starts at the New York midnight before this executor's clock;
  # no caller input moves it. With an intent, the fields the executor
  # fetches are read first (a cancel needs none).
  defp fill(state, %Context{} = context, intent) do
    with {:ok, now} <- now(state.clock),
         day_start = MarketCalendar.day_start(now),
         {:ok, notional} <- safe(fn -> Journal.today_notional(day_start, state.journal) end),
         {:ok, count} <- safe(fn -> Journal.orders_last_minute(now, state.journal) end) do
      context = fetched(state, context, intent, now)

      {:ok,
       %{context | policy: state.policy, today_notional: notional, orders_last_minute: count}}
    else
      {:error, reason} -> {:error, {:context, reason}}
    end
  end

  defp fetched(_state, context, %Intent{kind: kind}, _now) when kind in [:cancel, :decline],
    do: context

  defp fetched(state, context, intent, now) do
    env = %{
      port: state.port,
      catalog: state.catalog,
      account: state.account,
      timeout: state.review_timeout,
      now: now
    }

    ContextBuilder.build(intent, context, env)
  end

  # The clock is caller code, so it runs in a task: never in this process,
  # where it would hold the executor's identity and receipt key. Its result
  # is rebuilt by pattern matching before any Calendar function sees it.
  defp now(clock) do
    task = Task.async(clock)

    case Task.yield(task, @clock_timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %DateTime{} = now} -> utc(Plain.normalize(now))
      {:ok, other} -> {:error, {:invalid_clock, other}}
      {:exit, reason} -> {:error, {:clock_crashed, reason}}
      nil -> {:error, :clock_timeout}
    end
  end

  # Plain rebuilds an ISO DateTime with integer fields; the offsets and the
  # field ranges are checked here so no Calendar.ISO function can raise.
  defp utc(
         {:ok,
          %DateTime{
            time_zone: "Etc/UTC",
            utc_offset: 0,
            std_offset: 0,
            microsecond: {micro, precision}
          } = now}
       )
       when precision in 0..6 do
    if Calendar.ISO.valid_date?(now.year, now.month, now.day) and
         Calendar.ISO.valid_time?(now.hour, now.minute, now.second, {micro, precision}),
       do: {:ok, now},
       else: {:error, {:invalid_clock, now}}
  end

  defp utc({:ok, other}), do: {:error, {:invalid_clock, other}}
  defp utc({:error, reason}), do: {:error, {:invalid_clock, reason}}

  defp close_group(state, group_id, reason) do
    with {:error, error} <- append(state, group_id, {:close, reason}) do
      Logger.warning(
        "[Broker.Executor] could not close group #{group_id} (#{reason}): " <>
          inspect(error, structs: false)
      )

      {:error, error}
    end
  end

  defp append(state, group_id, entry),
    do: safe(fn -> Journal.append_to_group(group_id, entry, state.journal) end)

  defp safe(fun) do
    fun.()
  catch
    :exit, reason -> {:error, {:journal_down, reason}}
  end
end
