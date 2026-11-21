defmodule Raxol.Broker.Journal do
  @moduledoc """
  The broker's decision journal: one hash-chained `Raxol.Agent.Journal.FileStore`
  per install, at `~/.raxol/broker/journal` (`$RAXOL_BROKER_JOURNAL` or the
  `:path` option), opened private (directory 0700, files 0600).

  Every order decision is a group of consecutive records sharing a
  `group_id`: the intent, a snapshot of the policy context, each verdict
  (`:pre_review`, then `:post_review`), the review response, any human
  approval of an ASK, a `placing` record, and a terminal record (the order
  response, a DENY verdict, a declined approval, or a close). This process is
  the journal's only appender, so a group written with `append_group/1` is
  one Writer call and lands contiguously. A write-ahead caller opens the
  group with `open_group/2` before any review or order call and adds records
  with `append_to_group/2` as they happen; every broker record is synced to
  disk before the call returns.

  ## Claim

  One executor writes orders per journal. `claim/1` claims the journal for
  the calling process and monitors it; the claim is released when that
  process exits. Only a `Raxol.Broker.Executor` may claim: a caller whose
  proc_lib initial call is not `{Raxol.Broker.Executor, :init, 1}` is
  refused with `{:error, :not_an_executor}`. The same process may claim
  again; any other process is refused with `{:error, {:journal_claimed,
  pid}}` while the claimant lives. A claim is taken even on a damaged
  journal; group writes are still refused there.

  Every group record (`open_group/4`, `append_to_group/4`, `append_group/3`,
  any entry type) is written only for the claimant, and the claimant check is
  the first thing the journal does with a group write: nothing the caller
  sent is read, built into a record or encoded before it. With no claim held
  the write is refused with `{:error, :unclaimed}`; with one held, any other
  caller is refused with `{:error, {:not_claimant, id}}` (`id` is nil for a
  group not yet written). Nothing is written in either case, so no other
  process can open a group, forge a review, verdict or approval into the
  executor's open group, close it, or write `placing`. `append_fill/2` is
  not a group write and takes no claim.

  Only then are the intent and context of a new group rebuilt from plain data
  (`Raxol.Broker.Intent.normalize/1`, `Raxol.Broker.Policy.Context.normalize/1`),
  before anything is encoded. A struct, function, pid or other non-plain value
  anywhere inside them is refused with `{:error, {:invalid_intent, reason}}`
  or `{:error, {:invalid_context, reason}}` and nothing is written, so no
  protocol implementation from caller data ever runs in the journal.

  Threat model: the BEAM cannot stop code that deliberately writes into
  another module's private state, e.g. `Process.put(:"$initial_call", ...)`
  in its own process or `:sys.replace_state/2` on this one. The guarantee is
  that no path through public APIs writes a group record (and so sends an
  order) without the Executor's review pipeline; every remaining bypass
  requires impersonating the Executor's private process-dictionary slots on
  purpose.

  ## Write timeouts

  Callers wait as long as the journal takes: `open_group/4`,
  `append_to_group/4` and `append_group/3` wait `:infinity` by default (pass
  a timeout to override). A caller that gives up does not undo its write: the
  request stays queued and lands later.

  The journal bounds each call to its Writer
  (`Raxol.Agent.Journal.FileStore.append_many/3`) with `:write_deadline`
  (default 60_000 ms), including for fills and the crash closes written on
  start. A Writer that misses the deadline may still be about to land the
  records, so the journal never answers `{:error, _}` for it: it kills the
  Writer, waits for it to die, and stops with `{:writer_stalled, ms}`. Every
  caller waiting on the journal exits, and the Executor, which monitors the
  journal, stops too. The kill does not guarantee nothing lands: a dirty IO
  NIF already running may still complete the write after it. Recovery reads
  the disk, not the journal's memory, so on restart the disk is the truth: a `placing` that reached disk is closed as
  `crash_outcome_unknown` and keeps counting, and one that did not leaves
  its group closed as `crash_before_verdict`.

  The trade-off: a fsync slower than the deadline costs a journal and
  Executor restart instead of a slow write, and a journal whose Writer cannot
  write at all stops rather than hanging every order and cancel behind it.
  Answering `{:error, _}` on a timeout instead would let a `placing` land
  after the Executor closed its group as refused, turning an order that was
  never sent into a counted unknown outcome and a permanent duplicate.

  ## Placing

  `{:placing}` is written immediately before the order call, and only when
  all of these hold (otherwise nothing is written):

    * the caller is the claimant, as for every group write (`{:error,
      :unclaimed}` or `{:error, {:not_claimant, id}}`, see "Claim");
    * the group has a `review` record and either its latest `:post_review`
      verdict is ALLOW or it has an approved `approval` record
      (`{:error, {:not_reviewed, id}}`);
    * no other group for the same intent id reached `placing` with an
      outcome other than `:failed` (`{:error, {:duplicate_intent, other_id}}`).

  The journal prices the order from the group's own intent and context
  (`Raxol.Broker.Policy.notional/2`) and records that notional; it refuses an
  order it cannot price (`{:error, {:unpriced_order, reason}}`), so nothing
  unpriced is ever sent. Cancels record a `nil` notional. After `placing` the
  only records a group takes are its order response (`:placed`,
  `:pending_approval`, `:failed` or `:unknown`) or a close, and an order
  response is refused for a group with no
  `placing` record (`{:error, {:not_placing, id}}`). A close after `placing`
  records an `unknown` outcome: the order may exist.

  ## Recovery

  On start the chain is verified. A damaged journal (`{:damaged, offset}`)
  keeps the process up but refuses every append and every query: no order
  can be sized against a journal that cannot be trusted. On a healthy
  journal, every group left open by a crash is closed before anything else
  is written:

    * no `placing` record: closed as DENY `crash_before_verdict`, no order
      was sent;
    * a `placing` record but no order response: closed as
      `crash_outcome_unknown`. The order call may have gone out, so the
      group keeps counting toward notional and order rate.

  The journal traps exits: a supervisor shutdown closes the Writer it started,
  and if the Writer dies (including one this journal joined rather than
  started) the journal stops so its supervisor restarts it.

  ## Index

  Queries read an ETS table (named after the server) built from the journal
  on start and kept current on append. An order counts toward
  `today_notional/1` and `orders_last_minute/1` from its `placing` record, at
  that record's time and notional, until an order response says `:failed`;
  cancels never count. Only recorded notionals are used, never recomputed, so
  the live index and the one rebuilt on start agree. `realized_pnl_today/1`
  sums `append_fill/1` records. The exchange-day boundary is the caller's:
  pass the start of the day as a UTC instant. Queries return `{:error,
  reason}` while the journal is damaged or not running; a policy context left
  `nil` then denies.

  `placing_for_intent/2` answers whether a group for an intent id reached
  `placing` with an outcome other than `:failed`: the executor's idempotency
  check, so a re-run of the same intent after a restart never sends a second
  order, while an intent whose order definitely failed may be retried. The
  same index backs the duplicate-intent gate on `placing`.

  Arming must check `verify/1` first: it walks the chain on disk now,
  where `status/1` reports what was found at start.

  ## Events

  Records outside any group, each written only through the function named
  for it (there is no generic event writer, so no caller can forge a record
  of a type it was not given), with no claim needed, and refused, like every
  other write, on a damaged journal:

    * `emit`: a strategy runner's intent, written before the runner hands it
      to the executor (`emit/3`). It stays pending (`pending_intents/2`)
      until a `dispatch` record names its id (`dispatched/3`), so a runner
      that restarts re-sends it and the executor's idempotency check decides
      whether it was already placed.
    * `strategy`: a strategy added or stopped (`put_strategy/2`,
      `drop_strategy/2`); `strategies/1` lists the ones still added.
    * `mode`: `armed` (`record_armed/2`) or `disarmed` (`record_disarmed/2`).
      `mode/1` reads the latest; with none the broker is disarmed. Only
      `Raxol.Broker.Mode.arm/1`, after its checks, may write an `armed`
      record: `Raxol.Broker.Executor.StructureTest` fails if any other
      module references `record_armed/2`. Disarming is open to anyone.
    * `halt`: strategies paused or stopped and why (`Raxol.Broker.Halt`).
    * `resolve`: how an order whose outcome was unknown, or a proposal
      pending the owner's approval, turned out (`resolve/4`). An order the
      broker never received, or a proposal declined or expired, stops
      counting and frees its intent id.
    * `day_baseline`: the first live USD account total observed in the first
      60 seconds after New York midnight (`record_day_baseline/2`).
      Only `Raxol.Broker.DailyBaseline` references that writer in production.
      `day_baseline/3` reads the exact account/day's durable value; duplicate
      writes cannot reset losses, and invalid or duplicate recovery records
      make the journal unavailable. There is no intraday/manual substitute.
  """

  use GenServer

  require Logger

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Agent.OperatorFile
  alias Raxol.Broker.{Intent, Policy}
  alias Raxol.Broker.Executor.Review
  alias Raxol.Broker.Journal.{Codec, Groups}
  alias Raxol.Broker.Policy.Context

  @recent 20
  @event_types ~w(emit dispatch strategy mode halt resolve)
  @releasing ~w(absent declined expired)
  # Halt reasons that pause the strategy runners, and the pause they set;
  # and the reasons that end one, written only by `record_resume/2`.
  @pauses %{"drawdown_halt" => :drawdown_halt, "dead_man_pause" => :dead_man}
  @resumes %{"dead_man_resume" => :dead_man}
  @types ~w(intent context verdict review approval placing order close fill day_baseline) ++
           @event_types
  @phases [:pre_review, :post_review]
  @order_statuses [:placed, :pending_approval, :failed, :unknown]
  @decisions [:approved, :declined]
  @before_placing [:context, :verdict, :review, :approval, :placing]
  @minute_us 60_000_000
  @default_write_deadline 60_000

  @type server :: atom()
  @type group_id :: String.t()
  @type entry ::
          {:verdict, :pre_review | :post_review, Policy.result()}
          | {:context, Context.t()}
          | {:review, map()}
          | {:approval, :approved | :declined, String.t()}
          | {:placing}
          | {:order, :placed | :pending_approval | :failed | :unknown, map()}
          | {:close, atom()}
  @type group :: %{intent: Intent.t(), context: Context.t(), entries: [entry()]}
  @type fill :: %{
          order_id: String.t(),
          symbol: String.t(),
          side: :buy | :sell,
          qty: Decimal.t(),
          price: Decimal.t(),
          realized_pnl: Decimal.t()
        }
  @type status :: :ok | {:damaged, pos_integer()} | {:error, term()}

  # -- Lifecycle ----------------------------------------------------------------

  @doc """
  Start the journal. Options: `:name` (default `#{inspect(__MODULE__, structs: false)}`, also
  the ETS table name), `:path`, `:clock`, a zero-arity function returning
  the UTC `DateTime` stamped on records (default `DateTime.utc_now/0`), and
  `:write_deadline`, the milliseconds each Writer call may take before the
  journal kills the Writer and stops (default 60_000, see "Write timeouts").
  """
  def start_link(opts \\ []) do
    name = Keyword.get(opts, :name, __MODULE__)
    GenServer.start_link(__MODULE__, Keyword.put(opts, :name, name), name: name)
  end

  def child_spec(opts) do
    %{id: Keyword.get(opts, :name, __MODULE__), start: {__MODULE__, :start_link, [opts]}}
  end

  @doc "The journal directory: `:path`, `$RAXOL_BROKER_JOURNAL`, or `~/.raxol/broker/journal`."
  @spec path(keyword()) :: Path.t() | nil
  def path(opts \\ []),
    do: Keyword.get(opts, :path) || OperatorFile.path("RAXOL_BROKER_JOURNAL", "broker/journal")

  @doc "Split a journal path into `{base_dir, session_id}` for FileStore's read-side functions."
  @spec location(Path.t()) :: {Path.t(), String.t()}
  def location(path) do
    path = Path.expand(path)
    {Path.dirname(path), Path.basename(path)}
  end

  @impl GenServer
  def init(opts) do
    Process.flag(:trap_exit, true)
    name = Keyword.fetch!(opts, :name)

    with {:ok, deadline} <- write_deadline(opts),
         path when is_binary(path) <- path(opts) || {:error, :no_journal_path},
         {:ok, handle} <- open_store(path) do
      table = :ets.new(name, [:named_table, :ordered_set, :protected, read_concurrency: true])
      :ets.insert(table, {:halt_request_path, Raxol.Broker.HaltRequest.path(path)})
      :ets.insert(table, {:arm_generation, make_ref()})

      state = %{
        handle: handle,
        table: table,
        clock: Keyword.get(opts, :clock, &DateTime.utc_now/0),
        write_deadline: deadline,
        open: %{},
        claimant: nil,
        status: :ok
      }

      recover(state)
    else
      {:error, reason} -> {:stop, {:journal_open_failed, reason}}
    end
  end

  # The largest timeout a receive accepts.
  @max_deadline 4_294_967_295

  defp write_deadline(opts) do
    case Keyword.get(opts, :write_deadline, @default_write_deadline) do
      ms when is_integer(ms) and ms > 0 and ms <= @max_deadline -> {:ok, ms}
      _other -> {:error, :invalid_write_deadline}
    end
  end

  defp open_store(path) do
    {base, session} = location(path)

    opts = [
      base_dir: base,
      chain: true,
      private: true,
      immediate_sync_types: @types,
      title: "raxol broker journal"
    ]

    with {:ok, handle} <- FileStore.open(session, opts) do
      # A joined Writer was started by (and is linked to) another process:
      # link it here too, so its death stops this journal instead of leaving
      # it appending into a dead handle.
      unless handle.owner?, do: Process.link(handle.writer)
      {:ok, handle}
    end
  end

  @impl GenServer
  def terminate(_reason, state) do
    FileStore.close(state.handle)
  catch
    :exit, _ -> :ok
  end

  # -- Writes -------------------------------------------------------------------

  @doc """
  Write the intent and its context snapshot, durable before any review or
  order call. Returns the new group's id. Only the claimant may open a group
  (`{:error, :unclaimed}` or `{:error, {:not_claimant, nil}}`, see "Claim").

  `opts[:mode]` (`:dry_run` or `:armed`) is stored on the intent record and
  shown by replay; it is omitted when not given. `opts[:timeout]` bounds the
  call (default `:infinity`, see "Write timeouts").
  """
  @spec open_group(Intent.t(), Context.t(), server(), keyword()) ::
          {:ok, group_id()} | {:error, term()}
  def open_group(%Intent{} = intent, %Context{} = context, server \\ __MODULE__, opts \\ []) do
    {timeout, opts} = Keyword.pop(opts, :timeout, :infinity)

    case Keyword.get(opts, :mode) do
      mode when mode in [nil, :dry_run, :armed] ->
        GenServer.call(server, {:append_group, intent, context, [], opts}, timeout)

      mode ->
        {:error, {:invalid_mode, mode}}
    end
  end

  @doc """
  Add one record to an open group (see `t:entry/0`). Only the claimant may
  add any record (`{:error, :unclaimed}` or `{:error, {:not_claimant, id}}`,
  see "Claim"):

    * `{:verdict, phase, result}`: a DENY finishes the group;
    * `{:review, response}`;
    * `{:approval, :approved | :declined, by}`: a human's answer to an ASK; a
      decline finishes the group as DENY;
    * `{:placing}`: written immediately before the order call; refused unless
      the group was reviewed and allowed or approved (`{:not_reviewed, id}`),
      and no other group placed this intent without failing
      (`{:duplicate_intent, other}`).
      The journal records the order's notional and counts it from here, and
      refuses with `{:unpriced_order, reason}` when a non-cancel intent cannot
      be priced;
    * `{:order, :placed | :pending_approval | :failed | :unknown, response}`:
      finishes the group; refused with `{:not_placing, id}` before
      `{:placing}`. `:failed` stops the order counting and frees the intent
      for a retry; `:pending_approval` (a proposal the owner has yet to
      approve at the broker) keeps both, like `:placed`;
    * `{:close, reason}`: finishes the group, as DENY before `{:placing}` and
      as an unknown outcome (still counted) after it.

  Only an order response or a close may follow `{:placing}`
  (`{:already_placing, id}` otherwise).

  `timeout` bounds the call (default `:infinity`, see "Write timeouts").
  """
  @spec append_to_group(group_id(), entry(), server(), timeout()) :: :ok | {:error, term()}
  def append_to_group(group_id, entry, server \\ __MODULE__, timeout \\ :infinity)
      when is_binary(group_id),
      do: GenServer.call(server, {:append_to_group, group_id, entry}, timeout)

  @doc "Record a refreshed approval context, only from the claimant, before placing."
  @spec record_context(group_id(), Context.t(), server()) :: :ok | {:error, term()}
  def record_context(group_id, context, server \\ __MODULE__),
    do: append_to_group(group_id, {:context, context}, server)

  @doc """
  Write a whole group (intent, context, then `entries` in order) as one
  contiguous run of records, with the same rules as `append_to_group/2`.
  Returns the group's id. `timeout` bounds the call (default `:infinity`,
  see "Write timeouts").
  """
  @spec append_group(group(), server(), timeout()) :: {:ok, group_id()} | {:error, term()}
  def append_group(group, server \\ __MODULE__, timeout \\ :infinity)

  def append_group(
        %{intent: %Intent{} = intent, context: %Context{} = context, entries: entries},
        server,
        timeout
      )
      when is_list(entries),
      do: GenServer.call(server, {:append_group, intent, context, entries, []}, timeout)

  def append_group(other, _server, _timeout), do: {:error, {:invalid_group, other}}

  @doc "Record a fill with the realized P&L the broker reported for it."
  @spec append_fill(fill(), server()) :: :ok | {:error, term()}
  def append_fill(fill, server \\ __MODULE__), do: GenServer.call(server, {:append_fill, fill})

  @doc "Persist the first boundary observation for an account/day; never replace it."
  @spec record_day_baseline(map(), server()) :: :ok | {:error, term()}
  def record_day_baseline(fields, server \\ __MODULE__),
    do: GenServer.call(server, {:day_baseline, fields}, :infinity)

  @doc "Read the durable boundary value for this exact account and New York day."
  @spec day_baseline(String.t(), DateTime.t(), server()) ::
          {:ok, Decimal.t() | nil} | {:error, term()}
  def day_baseline(account, %DateTime{} = day, server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn ->
        case :ets.lookup(server, {:day_baseline, account, to_us(day)}) do
          [{_key, value}] -> {:ok, value}
          [] -> {:ok, nil}
        end
      end)
    end
  end

  @doc """
  Claim the journal for the calling process, the only one allowed to write
  group records (see "Claim"). Only a `Raxol.Broker.Executor` process may
  claim (proc_lib initial call `{Raxol.Broker.Executor, :init, 1}`); any
  other caller gets `{:error, :not_an_executor}`. Released when the claimant
  exits; the claimant may claim again. Returns `{:error, {:journal_claimed,
  pid}}` while another live process holds the claim.
  """
  @spec claim(server()) :: :ok | {:error, term()}
  def claim(server \\ __MODULE__), do: GenServer.call(server, :claim)

  # -- Queries ------------------------------------------------------------------

  @doc "USD notional of counted orders at or after `since` (both sides)."
  @spec today_notional(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def today_notional(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: select(fn -> {:ok, sum(server, :order, to_us(since))} end)
  end

  @doc "Counted orders in the 60 seconds ending at `now` (exclusive start, inclusive end)."
  @spec orders_last_minute(DateTime.t(), server()) :: {:ok, non_neg_integer()} | {:error, term()}
  def orders_last_minute(%DateTime{} = now, server \\ __MODULE__) do
    with :ok <- healthy(server) do
      to = to_us(now)
      from = to - @minute_us
      spec = [{{{:order, :"$1", :_}, :_}, [{:>, :"$1", from}, {:"=<", :"$1", to}], [true]}]
      select(fn -> {:ok, :ets.select_count(server, spec)} end)
    end
  end

  @doc "Realized P&L of fills at or after `since`."
  @spec realized_pnl_today(DateTime.t(), server()) :: {:ok, Decimal.t()} | {:error, term()}
  def realized_pnl_today(%DateTime{} = since, server \\ __MODULE__) do
    with :ok <- healthy(server), do: select(fn -> {:ok, sum(server, :fill, to_us(since))} end)
  end

  @doc """
  The id of a group for `intent_id` that reached `placing` with an outcome
  other than `:failed`, or nil when none did.
  """
  @spec placing_for_intent(String.t(), server()) :: {:ok, group_id() | nil} | {:error, term()}
  def placing_for_intent(intent_id, server \\ __MODULE__) when is_binary(intent_id) do
    with :ok <- healthy(server), do: select(fn -> intent_placing(server, intent_id) end)
  end

  defp intent_placing(table, intent_id) do
    case :ets.lookup(table, {:intent_placing, intent_id}) do
      [{_key, group_id}] -> {:ok, group_id}
      [] -> {:ok, nil}
    end
  end

  @doc "Ids of the groups still open (no terminal record), oldest first."
  @spec open_groups(server()) :: {:ok, [group_id()]} | {:error, term()}
  def open_groups(server \\ __MODULE__), do: GenServer.call(server, :open_groups)

  @doc """
  What start-up recovery found: `:ok`, `{:damaged, offset}`, or `{:error,
  reason}` when recovery or indexing failed.
  """
  @spec status(server()) :: status()
  def status(server \\ __MODULE__) do
    case :ets.lookup(server, :status) do
      [{:status, status}] -> status
      [] -> {:error, :journal_not_ready}
    end
  rescue
    ArgumentError -> {:error, :journal_not_running}
  end

  @doc """
  Walk the chain on disk now: `:ok`, `{:broken, offset}`, or `{:error,
  reason}` when the chain cannot be checked at all (e.g. `:unchained`, the
  chain flag gone from `meta.json`). Anything but `:ok` also marks the journal
  damaged, so later appends and queries are refused.

  The walk reads the whole journal inside this process with no timeout, and
  every append waits behind it.
  """
  @spec verify(server()) :: :ok | {:broken, pos_integer()} | {:error, term()}
  def verify(server \\ __MODULE__), do: GenServer.call(server, :verify, :infinity)

  # -- Events -------------------------------------------------------------------

  # The only event writer. Each public writer below names its own type.
  defp event(type, fields, server) when type in @event_types,
    do: GenServer.call(server, {:event, type, Codec.term(fields)}, :infinity)

  @doc "Record that strategy `strategy_id` emitted `intent` (see \"Events\")."
  @spec emit(Intent.t(), String.t(), server()) :: :ok | {:error, term()}
  def emit(%Intent{} = intent, strategy_id, server \\ __MODULE__) when is_binary(strategy_id) do
    fields = %{"strategy_id" => strategy_id, "intent" => Codec.encode_intent(intent)}
    event("emit", fields, server)
  end

  @doc "Record that the emitted intent `intent_id` reached the executor, and how it ended."
  @spec dispatched(String.t(), String.t(), server()) :: :ok | {:error, term()}
  def dispatched(intent_id, outcome, server \\ __MODULE__)
      when is_binary(intent_id) and is_binary(outcome),
      do: event("dispatch", %{"intent_id" => intent_id, "outcome" => outcome}, server)

  @doc "Intents `strategy_id` emitted that no `dispatch` record names yet, oldest first."
  @spec pending_intents(String.t(), server()) :: {:ok, [Intent.t()]} | {:error, term()}
  def pending_intents(strategy_id, server \\ __MODULE__) when is_binary(strategy_id) do
    with {:ok, emissions} <- pending_emissions(strategy_id, server) do
      {:ok, Enum.map(emissions, & &1.intent)}
    end
  end

  @doc "Pending intents with their journal emit timestamp, oldest first. Invalid timestamps are preserved for fail-closed expiry."
  @spec pending_emissions(String.t(), server()) ::
          {:ok, [%{intent: Intent.t(), at: term()}]} | {:error, term()}
  def pending_emissions(strategy_id, server \\ __MODULE__) when is_binary(strategy_id) do
    with :ok <- healthy(server),
         {:ok, emitted} <-
           select(fn -> {:ok, by_seq(server, {{:emit, :_}, :_, strategy_id, :_, :_})} end) do
      decode_all(emitted, fn {_key, _seq, _strategy, intent, at} ->
        with {:ok, intent} <- Codec.decode_intent(intent), do: {:ok, %{intent: intent, at: at}}
      end)
    end
  end

  @doc "Record a strategy as added: `spec` holds a string `\"id\"`."
  @spec put_strategy(map(), server()) :: :ok | {:error, term()}
  def put_strategy(%{"id" => id} = spec, server \\ __MODULE__) when is_binary(id),
    do: event("strategy", %{"action" => "add", "strategy_id" => id, "spec" => spec}, server)

  @doc "Record the strategy `id` as stopped."
  @spec drop_strategy(String.t(), server()) :: :ok | {:error, term()}
  def drop_strategy(id, server \\ __MODULE__) when is_binary(id),
    do: event("strategy", %{"action" => "stop", "strategy_id" => id}, server)

  @doc "Specs of the strategies added and not stopped, in the order they were added."
  @spec strategies(server()) :: {:ok, [map()]} | {:error, term()}
  def strategies(server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn -> {:ok, Enum.map(by_seq(server, {{:strategy, :_}, :_, :_}), &elem(&1, 2))} end)
    end
  end

  defp by_seq(table, pattern),
    do: table |> :ets.match_object(pattern) |> Enum.sort_by(&elem(&1, 1))

  defp decode_all(items, decode) do
    Enum.reduce_while(items, {:ok, []}, fn item, {:ok, acc} ->
      case decode.(item) do
        {:ok, value} -> {:cont, {:ok, [value | acc]}}
        {:error, _} = error -> {:halt, error}
      end
    end)
    |> case do
      {:ok, values} -> {:ok, Enum.reverse(values)}
      error -> error
    end
  end

  @doc """
  Record the broker as armed, with `fields` (who, what was checked). Only
  `Raxol.Broker.Mode.arm/1` calls this, after its checks; see "Events".
  """
  @spec record_armed(map(), server()) :: :ok | {:error, term()}
  def record_armed(fields, server \\ __MODULE__) when is_map(fields),
    do: record_armed(fields, server, :any)

  @doc "Arm only if no mode change or halt occurred during the checks."
  @spec record_armed(map(), server(), reference() | :any) :: :ok | {:error, term()}
  def record_armed(fields, server, generation) when is_map(fields),
    do: GenServer.call(server, {:arm, Codec.term(fields), generation}, :infinity)

  @doc "The journal-local generation invalidated by every mode record or restart."
  @spec arm_generation(server()) :: {:ok, reference()} | {:error, term()}
  def arm_generation(server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn ->
        case :ets.lookup(server, :arm_generation) do
          [{:arm_generation, generation}] -> {:ok, generation}
          [] -> {:error, :journal_not_ready}
        end
      end)
    end
  end

  @doc "Record the broker as disarmed, with `fields` (who, why). Open to any caller."
  @spec record_disarmed(map(), server()) :: :ok | {:error, term()}
  def record_disarmed(fields, server \\ __MODULE__) when is_map(fields),
    do: event("mode", Map.put(fields, "mode", "disarmed"), server)

  @doc """
  Record a halt (see `Raxol.Broker.Halt`): `fields` hold its `\"reason\"`. A
  reason that ends a pause is refused (`{:error, {:resume_reason, reason}}`):
  only `record_resume/2` writes those.
  """
  @spec record_halt(map(), server()) :: :ok | {:error, term()}
  def record_halt(%{"reason" => reason} = fields, server \\ __MODULE__) when is_binary(reason) do
    if Map.has_key?(@resumes, reason),
      do: {:error, {:resume_reason, reason}},
      else: event("halt", fields, server)
  end

  @doc """
  Record the end of a pause (`#{inspect(Map.keys(@resumes))}`). Only
  `Raxol.Broker.Heartbeat` calls this: `Raxol.Broker.Executor.StructureTest`
  fails if any other module references it.
  """
  @spec record_resume(map(), server()) :: :ok | {:error, term()}
  def record_resume(%{"reason" => reason} = fields, server \\ __MODULE__)
      when is_map_key(@resumes, reason),
      do: event("halt", fields, server)

  @doc """
  The latest mode record: `{:ok, :armed | :disarmed, record}`, or
  `{:ok, :disarmed, nil}` when there is none.
  """
  @spec mode(server()) :: {:ok, :armed | :disarmed, map() | nil} | {:error, term()}
  def mode(server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn ->
        case :ets.lookup(server, :mode) do
          [{:mode, %{"mode" => "armed"} = record}] -> {:ok, :armed, record}
          [{:mode, record}] -> {:ok, :disarmed, record}
          [] -> {:ok, :disarmed, nil}
        end
      end)
    end
  end

  @doc "Whether a cross-process halt marker exists; unreadable state blocks arming."
  @spec halt_pending?(server()) :: boolean()
  def halt_pending?(server \\ __MODULE__) do
    case select(fn -> :ets.lookup(server, :halt_request_path) end) do
      [{:halt_request_path, path}] -> Raxol.Broker.HaltRequest.pending?(path)
      _unreadable -> true
    end
  end

  @doc """
  The reasons strategy runners are paused for now, sorted: a `halt` record
  pauses (`#{inspect(Map.keys(@pauses))}`), an `armed` record ends the
  drawdown pause. A runner reads them when it starts, so a runner restarted
  or added during a pause starts paused.
  """
  @spec pauses(server()) :: {:ok, [atom()]} | {:error, term()}
  def pauses(server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn ->
        {:ok, server |> :ets.match({{:pause, :"$1"}, :_}) |> Enum.map(&hd/1) |> Enum.sort()}
      end)
    end
  end

  @doc """
  The last `count` finished decision groups, newest first: `%{"group_id",
  "at", "intent", "outcome"}` with the intent and outcome as one-line text.
  At most 20 are kept.
  """
  @spec recent(server(), pos_integer()) :: {:ok, [map()]} | {:error, term()}
  def recent(server \\ __MODULE__, count \\ 10) do
    with :ok <- healthy(server) do
      select(fn ->
        decisions =
          server
          |> :ets.match_object({{:decision, :_}, :_})
          |> Enum.sort_by(&elem(&1, 0), :desc)
          |> Enum.take(count)
          |> Enum.map(&elem(&1, 1))

        {:ok, decisions}
      end)
    end
  end

  @doc """
  Counted groups whose outcome is still open: an order journaled `:unknown`
  (or closed `crash_outcome_unknown`) and a `:pending_approval` proposal.
  Each is `%{"group_id", "intent_id", "status", "at", "approval_id",
  "approval_required"}`, oldest first; `"at"` is the `placing` time,
  `"approval_id"` is read from the order response when it carries one, and
  `"approval_required"` says the review asked for the owner's approval (the
  order Robinhood makes from an approved proposal carries the approval id,
  not the `ref_id` sent).
  """
  @spec unresolved(server()) :: {:ok, [map()]} | {:error, term()}
  def unresolved(server \\ __MODULE__) do
    with :ok <- healthy(server) do
      select(fn ->
        entries =
          server
          |> :ets.match_object({{:unresolved, :_}, :_})
          |> Enum.map(&elem(&1, 1))
          |> Enum.sort_by(& &1["at"])

        {:ok, entries}
      end)
    end
  end

  @doc """
  Record how an unresolved group turned out: `"placed"` or `"approved"` (an
  order exists and keeps counting), or `"absent"`, `"declined"` or
  `"expired"` (none does: the group stops counting and its intent id is
  free again). `detail` is journaled with it. Only the journal's claimant
  (the executor) may write one: `{:error, {:not_claimant, group_id}}` for
  any other caller, `{:error, :unclaimed}` when nothing holds the claim.
  """
  @spec resolve(group_id(), String.t(), map(), server()) :: :ok | {:error, term()}
  def resolve(group_id, resolution, detail, server \\ __MODULE__)
      when resolution in ~w(placed approved absent declined expired) and is_map(detail) do
    fields = %{"group_id" => group_id, "resolution" => resolution, "detail" => detail}
    GenServer.call(server, {:resolve, Codec.term(fields)}, :infinity)
  end

  # -- Server -------------------------------------------------------------------

  @impl GenServer
  def handle_call(:verify, _from, state) do
    case FileStore.verify(state.handle) do
      :ok ->
        {:reply, :ok, state}

      {:broken, offset} ->
        {:reply, {:broken, offset}, set_status(state, {:damaged, offset})}

      {:error, reason} ->
        {:reply, {:error, reason}, set_status(state, {:error, {:unverifiable, reason}})}
    end
  end

  def handle_call(:claim, {pid, _tag}, state) do
    cond do
      not executor?(pid) ->
        {:reply, {:error, :not_an_executor}, state}

      match?({^pid, _ref}, state.claimant) ->
        {:reply, :ok, state}

      claimed_by_other?(state.claimant) ->
        {:reply, {:error, {:journal_claimed, elem(state.claimant, 0)}}, state}

      true ->
        {:reply, :ok, take_claim(state, pid)}
    end
  end

  def handle_call(_request, _from, %{status: status} = state) when status != :ok,
    do: {:reply, {:error, refusal(status)}, state}

  def handle_call(:open_groups, _from, state) do
    ids = state.open |> Enum.sort_by(fn {_id, group} -> group.seq end) |> Enum.map(&elem(&1, 0))
    {:reply, {:ok, ids}, state}
  end

  def handle_call({:day_baseline, fields}, _from, state) do
    with {:ok, {fields, at}} <- Raxol.Broker.Plain.normalize({fields, state.clock.()}),
         {:ok, record} <- Codec.encode_day_baseline(fields, at),
         key = {:day_baseline, fields.account, to_us(fields.day_start)},
         [] <- :ets.lookup(state.table, key),
         {:ok, _offsets} <- write(state, [record]) do
      :ets.insert(state.table, {key, fields.value})
      {:reply, :ok, state}
    else
      [_existing] -> {:reply, {:error, :day_baseline_exists}, state}
      {:error, {:not_plain, _path}} -> refuse(state, :invalid_day_baseline)
      {:error, reason} -> refuse(state, reason)
    end
  end

  def handle_call({:append_group, intent, context, entries, opts}, {caller, _tag}, state) do
    with :ok <- claimant(state, caller, nil),
         {:ok, id, group, records} <- build_group(state, intent, context, entries, opts),
         {:ok, _offsets} <- write(state, records) do
      {:reply, {:ok, id}, settle(state, id, group, records)}
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  def handle_call({:append_to_group, id, entry}, {caller, _tag}, state) do
    with :ok <- claimant(state, caller, id),
         {:ok, group} <- fetch_open(state, id),
         {:ok, records, group} <- apply_entries([entry], id, group, state),
         {:ok, _offsets} <- write(state, records) do
      {:reply, :ok, settle(state, id, group, records)}
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  def handle_call({:append_fill, fill}, _from, state) do
    with {:ok, fields} <- encode_fill(fill),
         at = state.clock.(),
         record = %{"kind" => "broker", "type" => "fill", "at" => iso(at), "fill" => fields},
         {:ok, [offset]} <- write(state, [record]) do
      :ets.insert(state.table, {{:fill, to_us(at), offset}, fill.realized_pnl})
      {:reply, :ok, state}
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  def handle_call({:arm, fields, expected}, from, state) do
    [{:arm_generation, current}] = :ets.lookup(state.table, :arm_generation)

    cond do
      halt_pending?(state.table) ->
        {:reply, {:error, :halt_requested}, state}

      expected != :any and expected != current ->
        {:reply, {:error, :mode_changed}, state}

      true ->
        handle_call({:event, "mode", Map.put(fields, "mode", "armed")}, from, state)
    end
  end

  def handle_call({:event, type, fields}, _from, state) do
    record = Map.merge(fields, %{"kind" => "broker", "type" => type, "at" => iso(state.clock.())})

    case write(state, [record]) do
      {:ok, _offsets} ->
        index_event(state.table, record)
        {:reply, :ok, state}

      {:error, reason} ->
        refuse(state, reason)
    end
  end

  # A resolution can release the cap and free an intent id, so it is a
  # claimant's write, like a group record.
  def handle_call({:resolve, %{"group_id" => id} = fields}, {caller, _tag}, state) do
    record =
      Map.merge(fields, %{"kind" => "broker", "type" => "resolve", "at" => iso(state.clock.())})

    with :ok <- claimant(state, caller, id),
         {:ok, _offsets} <- write(state, [record]) do
      index_event(state.table, record)
      {:reply, :ok, state}
    else
      {:error, reason} -> refuse(state, reason)
    end
  end

  @impl GenServer
  def handle_info({:EXIT, writer, reason}, %{handle: %{writer: writer}} = state),
    do: {:stop, {:journal_writer_down, reason}, state}

  def handle_info({:DOWN, ref, :process, pid, _reason}, %{claimant: {pid, ref}} = state),
    do: {:noreply, %{state | claimant: nil}}

  # `structs: false`: a message from any process may hold a struct, and its
  # Inspect implementation must not run here.
  def handle_info(message, state) do
    Logger.warning(
      "#{inspect(__MODULE__, structs: false)} ignored an unexpected message: " <>
        inspect(message, structs: false)
    )

    {:noreply, state}
  end

  # The journal takes no casts. Overriding the `use GenServer` default keeps
  # it from raising, which would make the crash report inspect the cast term
  # with structs on inside this process.
  @impl GenServer
  def handle_cast(_message, state) do
    Logger.warning("#{inspect(__MODULE__, structs: false)} ignored an unexpected cast")
    {:noreply, state}
  end

  # -- Claim --------------------------------------------------------------------

  # The claim goes only to a process started as `Raxol.Broker.Executor`
  # (proc_lib records its initial call). Reading another process's dictionary
  # is how the BEAM exposes that; a dead caller has none and is refused.
  defp executor?(pid) do
    case Process.info(pid, :dictionary) do
      {:dictionary, dictionary} ->
        List.keyfind(dictionary, :"$initial_call", 0) ==
          {:"$initial_call", {Raxol.Broker.Executor, :init, 1}}

      nil ->
        false
    end
  end

  defp claimed_by_other?(nil), do: false
  defp claimed_by_other?({other, _ref}), do: Process.alive?(other)

  # A dead claimant's :DOWN may still be queued; drop it with the old monitor.
  defp take_claim(%{claimant: {_other, ref}} = state, pid) do
    Process.demonitor(ref, [:flush])
    take_claim(%{state | claimant: nil}, pid)
  end

  defp take_claim(state, pid), do: %{state | claimant: {pid, Process.monitor(pid)}}

  # Every group record comes from the claimant: with no claim held nothing
  # may write a group, and with one held only its holder may. A claimant
  # that died before its :DOWN arrived still holds the claim here, so every
  # other caller stays refused until the claim is released.
  defp claimant(%{claimant: nil}, _caller, _id), do: {:error, :unclaimed}
  defp claimant(%{claimant: {caller, _ref}}, caller, _id), do: :ok
  defp claimant(_state, _caller, id), do: {:error, {:not_claimant, id}}

  # -- Entries ------------------------------------------------------------------

  # A new group's id, open state and records (intent, context, then
  # `entries`), built only after the claimant check and only from the
  # normalized intent and context.
  defp build_group(state, intent, context, entries, opts) do
    with {:ok, intent, context} <- Policy.normalize(intent, context) do
      id = Base.encode16(:crypto.strong_rand_bytes(12), case: :lower)
      group = new_group(intent, context, System.unique_integer([:monotonic]))
      head = group_head(state, id, intent, context, Keyword.get(opts, :mode))

      with {:ok, records, group} <- apply_entries(entries, id, group, state),
           do: {:ok, id, group, head ++ records}
    end
  end

  defp group_head(state, id, intent, context, mode) do
    intent_fields = %{"intent" => Codec.encode_intent(intent)}

    intent_fields =
      if mode, do: Map.put(intent_fields, "mode", mode_name(mode)), else: intent_fields

    [
      record(state, "intent", id, intent_fields),
      record(state, "context", id, %{"context" => Codec.encode_context(context)})
    ]
  end

  defp mode_name(:dry_run), do: "dry_run"
  defp mode_name(:armed), do: "armed"

  defp new_group(intent, context, seq) do
    %{
      intent: intent,
      context: context,
      placing: nil,
      finished?: false,
      seq: seq,
      reviewed?: false,
      approval_required?: false,
      post_action: nil,
      approved?: false
    }
  end

  # Validate entries in order against the group's state and build their
  # records. The group state carries what the rules need: the group's own
  # intent and context (to price `placing`), whether it was reviewed, its
  # latest post-review action and whether an ASK was approved (to gate
  # `placing`), its `placing` record (an order response needs one; nothing but
  # an order response or a close may follow it) and whether a terminal record
  # has been written.
  defp apply_entries(entries, id, group, state) do
    Enum.reduce_while(entries, {:ok, [], group}, fn
      _entry, {:ok, _records, %{finished?: true}} ->
        {:halt, {:error, {:group_finished, id}}}

      entry, {:ok, records, group} ->
        case entry_record(entry, id, group, state) do
          {:ok, record, group} -> {:cont, {:ok, [record | records], group}}
          {:error, _} = error -> {:halt, error}
        end
    end)
    |> case do
      {:ok, records, group} -> {:ok, Enum.reverse(records), group}
      error -> error
    end
  end

  defp entry_record(entry, id, %{placing: %{}}, _state)
       when is_tuple(entry) and tuple_size(entry) > 0 and elem(entry, 0) in @before_placing,
       do: {:error, {:already_placing, id}}

  defp entry_record({:context, context}, id, group, state) do
    with {:ok, context} <- Context.normalize(context) do
      record = record(state, "context", id, %{"context" => Codec.encode_context(context)})
      {:ok, record, %{group | context: context, post_action: nil, approved?: false}}
    end
  end

  defp entry_record({:verdict, phase, result}, id, group, state) when phase in @phases do
    with {:ok, encoded} <- Codec.encode_result(result) do
      fields = %{
        "phase" => Atom.to_string(phase),
        "result" => encoded,
        "rule_ids" => Enum.map(Policy.rule_ids(), &Atom.to_string/1)
      }

      group = finish_if(group, encoded["action"] == "deny")
      group = if phase == :post_review, do: %{group | post_action: encoded["action"]}, else: group
      {:ok, record(state, "verdict", id, fields), group}
    end
  end

  defp entry_record({:review, response}, id, group, state) when is_map(response) do
    record = record(state, "review", id, %{"response" => Codec.term(response)})
    approval? = Review.customer_approval_required?(response)
    {:ok, record, %{group | reviewed?: true, approval_required?: approval?}}
  end

  defp entry_record({:approval, decision, by}, id, group, state)
       when decision in @decisions and is_binary(by) and by != "" do
    fields = %{"decision" => Atom.to_string(decision), "by" => by}
    group = %{group | approved?: group.approved? or decision == :approved}
    {:ok, record(state, "approval", id, fields), finish_if(group, decision == :declined)}
  end

  defp entry_record({:placing}, id, group, state) do
    with :ok <- placing_allowed(id, group, state),
         {:ok, notional} <- placing_notional(group.intent, group.context) do
      record = record(state, "placing", id, %{"notional" => notional})
      {:ok, record, %{group | placing: record}}
    end
  end

  defp entry_record({:order, status, response}, id, group, state)
       when status in @order_statuses and is_map(response) do
    if group.placing do
      fields = %{"status" => Atom.to_string(status), "response" => Codec.term(response)}
      {:ok, record(state, "order", id, fields), finish_if(group, true)}
    else
      {:error, {:not_placing, id}}
    end
  end

  defp entry_record({:close, reason}, id, group, state)
       when is_atom(reason) and not is_nil(reason) do
    outcome = if group.placing, do: "unknown", else: "deny"
    fields = %{"reason" => Atom.to_string(reason), "outcome" => outcome}
    {:ok, record(state, "close", id, fields), finish_if(group, true)}
  end

  defp entry_record(entry, _id, _group, _state), do: {:error, {:invalid_entry, entry}}

  defp finish_if(group, finished?), do: %{group | finished?: finished?}

  defp placing_allowed(id, %{reviewed?: true} = group, state)
       when group.post_action == "allow" or group.approved? do
    case :ets.lookup(state.table, {:intent_placing, group.intent.id}) do
      [{_key, other}] when other != id -> {:error, {:duplicate_intent, other}}
      _ -> :ok
    end
  end

  defp placing_allowed(id, _group, _state), do: {:error, {:not_reviewed, id}}

  # The notional recorded on `placing`: a decimal string, or nil for a cancel
  # or a decline, which never count. Anything else that cannot be priced is
  # not sent.
  defp placing_notional(%Intent{kind: kind}, _context) when kind in [:cancel, :decline],
    do: {:ok, nil}

  defp placing_notional(intent, context) do
    case Policy.notional(intent, context) do
      {:ok, notional} -> {:ok, Decimal.to_string(notional)}
      {:error, reason} -> {:error, {:unpriced_order, reason}}
    end
  end

  # After a successful write: keep the group open or drop it, count a
  # `placing` record and uncount a failed order. The same `index_placing/3`
  # builds the index on start, so both read the recorded notional.
  defp settle(state, id, group, records) do
    open =
      if group.finished?,
        do: Map.delete(state.open, id),
        else: Map.put(state.open, id, group)

    state = %{state | open: open}

    if group.finished?,
      do: remember(state.table, id, Codec.encode_intent(group.intent), List.last(records))

    Enum.reduce(records, state, fn
      %{"type" => "placing"} = placing, state ->
        :ets.insert(state.table, {{:intent_placing, group.intent.id}, id})

        case index_placing(state.table, id, placing) do
          :ok -> state
          {:error, reason} -> set_status(state, {:error, reason})
        end

      %{"type" => "order", "status" => "failed"}, state ->
        :ets.delete_object(state.table, {{:intent_placing, group.intent.id}, id})
        uncount(state, id, group.placing)

      %{"type" => "order", "status" => status} = order, state
      when status in ["unknown", "pending_approval"] ->
        unresolved(state.table, id, group, status, order["response"])
        state

      %{"type" => "close", "outcome" => "unknown"}, state ->
        unresolved(state.table, id, group, "unknown", nil)
        state

      _record, state ->
        state
    end)
  end

  defp uncount(state, id, %{"at" => at}) do
    case parse_us(at) do
      {:ok, us} ->
        :ets.delete(state.table, {:order, us, id})
        state

      :error ->
        set_status(state, {:error, {:unindexable_group, id, :at}})
    end
  end

  # An order whose outcome is not known (or a proposal the owner has yet to
  # answer) until reconciliation resolves it; see `unresolved/1`. Cancels
  # and declines record no notional and are not tracked.
  defp unresolved(table, id, group, status, response) do
    unresolved(
      table,
      id,
      group.intent.id,
      group.placing,
      status,
      response,
      group.approval_required?
    )
  end

  defp unresolved(_table, _id, _intent_id, %{"notional" => nil}, _status, _response, _approval?),
    do: true

  defp unresolved(table, id, intent_id, placing, status, response, approval?) do
    entry = %{
      "group_id" => id,
      "intent_id" => intent_id,
      "status" => status,
      "at" => placing["at"],
      "approval_id" => approval_id(response),
      "approval_required" => approval?
    }

    :ets.insert(table, {{:unresolved, id}, entry})
  end

  defp approval_id(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{"approval_id" => id}} when is_binary(id) -> id
          {:ok, %{"data" => %{"approval_id" => id}}} when is_binary(id) -> id
          _ -> nil
        end

      _block ->
        nil
    end)
  end

  defp approval_id(_response), do: nil

  defp fetch_open(state, id) do
    case Map.fetch(state.open, id) do
      {:ok, group} -> {:ok, group}
      :error -> {:error, {:unknown_or_finished_group, id}}
    end
  end

  defp encode_fill(%{order_id: order_id, symbol: symbol, side: side} = fill)
       when is_binary(order_id) and order_id != "" and side in [:buy, :sell] do
    decimals = [:qty, :price, :realized_pnl]

    if Intent.symbol?(symbol) and Enum.all?(decimals, &finite?(Map.get(fill, &1))) do
      {:ok,
       %{
         "order_id" => order_id,
         "symbol" => symbol,
         "side" => Atom.to_string(side),
         "qty" => Decimal.to_string(fill.qty),
         "price" => Decimal.to_string(fill.price),
         "realized_pnl" => Decimal.to_string(fill.realized_pnl)
       }}
    else
      {:error, {:invalid_fill, fill}}
    end
  end

  defp encode_fill(fill), do: {:error, {:invalid_fill, fill}}

  defp finite?(%Decimal{coef: coef}), do: is_integer(coef)
  defp finite?(_value), do: false

  # -- Recovery and index -------------------------------------------------------

  # One scan of the journal: a damaged one is only scanned again to name the
  # offset. Closing a crashed group changes no count (an in-flight group
  # counts before and after its `unknown` close, an open one neither), so the
  # index is built from the records as read. Returns the `init/1` result.
  defp recover(state) do
    case FileStore.read(state.handle) do
      {:ok, records} -> recover_records(state, records)
      {:error, reason} -> {:ok, set_status(state, damage_or(state, reason))}
    end
  end

  defp recover_records(state, records) do
    {groups, fills} = Groups.fold(records)

    with :ok <- index_day_baselines(state.table, records),
         {:ok, _offsets} <- write(state, crash_closes(state, groups)),
         :ok <- index_groups(state.table, Enum.filter(groups, &Groups.counts?/1)),
         :ok <- index_intents(state.table, groups),
         :ok <- index_fills(state.table, fills) do
      Enum.each(groups, fn group ->
        case {group.placing, unresolved_status(group)} do
          {%{} = placing, status} when is_binary(status) ->
            response = group.order && group.order["response"]
            approval? = approval_required?(group)

            unresolved(
              state.table,
              group.id,
              group.intent["id"],
              placing,
              status,
              response,
              approval?
            )

          _settled_or_never_placed ->
            true
        end
      end)

      # Resolve events follow, so they settle the entries just made.
      Enum.each(records, &index_event(state.table, &1))

      for group <- Enum.take(groups, -@recent),
          Groups.outcome(group) not in [:open, :in_flight],
          do: remember(state.table, group.id, group.intent, List.last(group.records))

      {:ok, set_status(state, :ok)}
    else
      {:error, {:writer_stalled, _ms} = reason} -> {:stop, reason}
      {:error, reason} -> {:ok, set_status(state, damage_or(state, reason))}
    end
  end

  # A group still `in_flight` here is closed as `crash_outcome_unknown` by
  # this recovery.
  defp unresolved_status(group) do
    case Groups.outcome(group) do
      :pending_approval -> "pending_approval"
      outcome when outcome in [:unknown, :in_flight] -> "unknown"
      _settled -> nil
    end
  end

  defp approval_required?(group) do
    Enum.any?(group.records, fn
      %{"type" => "review", "response" => response} when is_map(response) ->
        Review.customer_approval_required?(response)

      _record ->
        false
    end)
  end

  # The last @recent finished groups, for `recent/2`, keyed by a monotonic
  # sequence number. The terminal record says how each ended.
  defp remember(table, id, intent, last) do
    decision = %{
      "group_id" => id,
      "at" => last["at"],
      "intent" => intent_text(intent),
      "outcome" => outcome_text(last)
    }

    :ets.insert(table, {{:decision, seq()}, decision})

    table
    |> :ets.match({{:decision, :"$1"}, :_})
    |> Enum.map(&hd/1)
    |> Enum.sort(:desc)
    |> Enum.drop(@recent)
    |> Enum.each(&:ets.delete(table, {:decision, &1}))
  end

  defp intent_text(%{} = intent) do
    [
      intent["kind"],
      intent["side"],
      intent["symbol"],
      intent["qty"],
      intent["limit"],
      intent["notional"]
    ]
    |> Enum.reject(&is_nil/1)
    |> Enum.join(" ")
  end

  defp intent_text(_intent), do: "?"

  defp outcome_text(%{"type" => "order", "status" => status}), do: status

  defp outcome_text(%{"type" => "close", "outcome" => outcome, "reason" => reason}),
    do: "#{outcome} #{reason}"

  defp outcome_text(%{"type" => "approval", "by" => by}), do: "declined by #{by}"
  defp outcome_text(%{"type" => "verdict", "result" => %{"rule" => rule}}), do: "deny #{rule}"
  defp outcome_text(_record), do: "finished"

  # Events are indexed in journal order, so a later record wins. Each entry
  # carries a monotonic sequence number for ordered listings.
  defp index_event(table, %{"kind" => "broker", "type" => "emit"} = record) do
    case record do
      %{"intent" => %{"id" => id} = intent, "strategy_id" => strategy} when is_binary(id) ->
        :ets.insert(table, {{:emit, id}, seq(), strategy, intent, record["at"]})

      _malformed ->
        true
    end
  end

  defp index_event(table, %{"kind" => "broker", "type" => "dispatch", "intent_id" => id}),
    do: :ets.delete(table, {:emit, id})

  defp index_event(
         table,
         %{"kind" => "broker", "type" => "strategy", "strategy_id" => id} = record
       ) do
    case record do
      %{"action" => "add", "spec" => spec} -> :ets.insert(table, {{:strategy, id}, seq(), spec})
      %{"action" => "stop"} -> :ets.delete(table, {:strategy, id})
      _malformed -> true
    end
  end

  # An armed record ends the drawdown pause: only a fresh arm resumes.
  defp index_event(table, %{"kind" => "broker", "type" => "mode"} = record) do
    if record["mode"] == "armed", do: :ets.delete(table, {:pause, :drawdown_halt})
    :ets.insert(table, [{:mode, record}, {:arm_generation, make_ref()}])
  end

  defp index_event(table, %{"kind" => "broker", "type" => "halt", "reason" => reason}) do
    case {Map.fetch(@pauses, reason), Map.fetch(@resumes, reason)} do
      {{:ok, pause}, _resume} -> :ets.insert(table, {{:pause, pause}, reason})
      {:error, {:ok, pause}} -> :ets.delete(table, {:pause, pause})
      {:error, :error} -> true
    end
  end

  # A resolution that says no order exists stops the group counting and
  # frees its intent, as a `:failed` order response would.
  defp index_event(table, %{"kind" => "broker", "type" => "resolve"} = record) do
    with %{"group_id" => id, "resolution" => resolution} <- record,
         [{_key, entry}] <- :ets.lookup(table, {:unresolved, id}) do
      :ets.delete(table, {:unresolved, id})

      if resolution in @releasing do
        with {:ok, us} <- parse_us(entry["at"]), do: :ets.delete(table, {:order, us, id})
        :ets.delete_object(table, {{:intent_placing, entry["intent_id"]}, id})
      end
    end

    true
  end

  defp index_event(_table, _record), do: true

  defp seq, do: System.unique_integer([:monotonic])

  defp crash_closes(state, groups) do
    for group <- groups, Groups.outcome(group) in [:open, :in_flight] do
      {reason, outcome} = Groups.crash_close(group)
      record(state, "close", group.id, %{"reason" => reason, "outcome" => outcome})
    end
  end

  defp index_groups(table, groups) do
    Enum.reduce_while(groups, :ok, fn group, :ok ->
      case index_placing(table, group.id, group.placing) do
        :ok -> {:cont, :ok}
        error -> {:halt, error}
      end
    end)
  end

  defp index_intents(table, groups) do
    Enum.reduce_while(groups, :ok, fn
      %Groups{placing: nil}, :ok ->
        {:cont, :ok}

      %Groups{order: %{"status" => "failed"}}, :ok ->
        {:cont, :ok}

      %Groups{intent: %{"id" => intent_id}, id: id}, :ok when is_binary(intent_id) ->
        :ets.insert(table, {{:intent_placing, intent_id}, id})
        {:cont, :ok}

      %Groups{id: id}, :ok ->
        {:halt, {:error, {:unindexable_group, id, :intent}}}
    end)
  end

  # Count an order at its `placing` record's time and recorded notional; a
  # cancel records none and never counts.
  defp index_placing(_table, _id, %{"notional" => nil}), do: :ok

  defp index_placing(table, id, %{"notional" => notional, "at" => at}) do
    with {:ok, notional} <- parse_decimal(notional, {:unindexable_group, id, :notional}),
         {:ok, us} <- parse_us(at, {:unindexable_group, id, :at}) do
      :ets.insert(table, {{:order, us, id}, notional})
      :ok
    end
  end

  defp index_placing(_table, id, _placing), do: {:error, {:unindexable_group, id, :placing}}

  defp index_fills(table, fills) do
    Enum.reduce_while(fills, :ok, fn record, :ok ->
      unindexable = {:unindexable_fill, record["id"]}

      with %{"id" => offset, "at" => at, "fill" => %{"realized_pnl" => pnl}} <- record,
           {:ok, pnl} <- parse_decimal(pnl, unindexable),
           {:ok, us} <- parse_us(at, unindexable) do
        :ets.insert(table, {{:fill, us, offset}, pnl})
        {:cont, :ok}
      else
        {:error, _} = error -> {:halt, error}
        _malformed -> {:halt, {:error, unindexable}}
      end
    end)
  end

  defp index_day_baselines(table, records) do
    Enum.reduce_while(records, :ok, fn
      %{"type" => "day_baseline"} = record, :ok ->
        with {:ok, fields} <- Codec.decode_day_baseline(record),
             key = {:day_baseline, fields.account, to_us(fields.day_start)},
             true <- :ets.insert_new(table, {key, fields.value}) do
          {:cont, :ok}
        else
          _invalid -> {:halt, {:error, :invalid_or_duplicate_day_baseline}}
        end

      _record, :ok ->
        {:cont, :ok}
    end)
  end

  # -- Helpers ------------------------------------------------------------------

  defp record(state, type, id, fields) do
    Map.merge(fields, %{
      "kind" => "broker",
      "type" => type,
      "group_id" => id,
      "at" => iso(state.clock.())
    })
  end

  # Each Writer call is bounded by the write deadline (see "Write timeouts").
  # A call that misses it may still land, so it is never reported as a
  # failed write: the Writer is killed, and dead before this returns, so
  # nothing lands after the journal stops.
  defp write(_state, []), do: {:ok, []}

  defp write(state, records) do
    case FileStore.append_many(state.handle, records, state.write_deadline) do
      {:error, {:writer_down, :timeout}} -> stall(state)
      result -> result
    end
  end

  defp stall(%{handle: %{writer: writer}, write_deadline: deadline}) do
    ref = Process.monitor(writer)
    Process.exit(writer, :kill)
    receive do: ({:DOWN, ^ref, :process, ^writer, _reason} -> :ok)
    {:error, {:writer_stalled, deadline}}
  end

  # A stalled Writer stops the journal with no reply: every caller exits.
  defp refuse(state, {:writer_stalled, _ms} = reason), do: {:stop, reason, state}
  defp refuse(state, reason), do: {:reply, {:error, reason}, state_after(state, reason)}

  # A write the Writer refused as damaged means the chain broke under us.
  defp state_after(state, :damaged), do: set_status(state, damage_or(state, :damaged))
  defp state_after(state, _reason), do: state

  defp damage_or(state, reason) do
    case FileStore.status(state.handle) do
      {:damaged, offset} -> {:damaged, offset}
      :ok -> {:error, reason}
    end
  end

  defp set_status(state, status) do
    :ets.insert(state.table, {:status, status})
    %{state | status: status}
  end

  defp refusal({:damaged, offset}), do: {:journal_damaged, offset}
  defp refusal({:error, reason}), do: {:journal_unavailable, reason}

  defp healthy(server) do
    case status(server) do
      :ok -> :ok
      other -> {:error, refusal_or(other)}
    end
  end

  defp refusal_or({:error, reason}) when reason in [:journal_not_running, :journal_not_ready],
    do: reason

  defp refusal_or(status), do: refusal(status)

  # The table goes with the process: a journal that stops between `healthy/1`
  # and the read is not running.
  defp select(read) do
    read.()
  rescue
    ArgumentError -> {:error, :journal_not_running}
  end

  defp sum(table, tag, from) do
    table
    |> :ets.select([{{{tag, :"$1", :_}, :"$2"}, [{:>=, :"$1", from}], [:"$2"]}])
    |> Enum.reduce(Decimal.new(0), &Decimal.add/2)
  end

  defp iso(%DateTime{} = at), do: at |> DateTime.shift_zone!("Etc/UTC") |> DateTime.to_iso8601()

  defp to_us(%DateTime{} = at), do: DateTime.to_unix(at, :microsecond)

  defp parse_us(at, error) do
    case parse_us(at) do
      {:ok, us} -> {:ok, us}
      :error -> {:error, error}
    end
  end

  defp parse_us(at) when is_binary(at) do
    case DateTime.from_iso8601(at) do
      {:ok, datetime, _offset} -> {:ok, to_us(datetime)}
      {:error, _} -> :error
    end
  end

  defp parse_us(_at), do: :error

  defp parse_decimal(value, error) when is_binary(value) do
    case Decimal.parse(value) do
      {%Decimal{} = decimal, ""} -> {:ok, decimal}
      _ -> {:error, error}
    end
  end

  defp parse_decimal(_value, error), do: {:error, error}
end
