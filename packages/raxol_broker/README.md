# Raxol Broker

A guarded order path from Raxol to Robinhood's agent MCP server: written
limits checked in code before and after Robinhood's own review, explicit
arming, a hash-chained journal of every decision, strategy runners, ASK
approvals in the terminal, LiveView and SSH, and kill and dead-man
switches. Equity orders only. The package is pre-alpha and has not yet
traded real money; a read-only session and the policy tooling work on
their own.

## Live preflight — 2026-11-16

Read-only checks against server `1.19.1` established the live envelopes now
used by the consumers: `data.results[].quote`,
`data.setting.human_must_approve_trades` (observed `true`) and
`data.buying_power.buying_power`. The reviewed tool capture and generated
read wrappers include the current contracts. Equity limit/stop orders
require whole shares; fractional and dollar market orders retain GFD and
regular-hours defaults. Unsupported option/advanced/crypto execution stays
refused rather than inferring instrument eligibility or changing prices.
Stable 36-byte UUID idempotency keys remain unchanged and satisfy the refreshed
server contract (a nonempty string of at most 256 bytes).

**This is not a live-soak GO.** The MCP server provides current USD
`total_value`, but no historical account NAV or complete daily P&L source.
The owner chose a durable New York day-boundary observation instead:
`DailyBaseline` captures during the first 60 seconds after local midnight.
Both request start and completion, and the journal's record timestamp, must
fit that window. A missed window leaves baseline-dependent orders denied all day.
The first drawdown-policy evaluation without it also disarms and pauses
strategies; a later capture does not resume or re-arm them automatically.
Collector timers round up and reschedule early wakes, including after wall-clock
changes. Configured clocks run in bounded tasks and are rebuilt as valid UTC ISO
timestamps; a refused clock leaves the collector alive and schedules another check.
No arbitrary intraday value, previous-close alias or caller context can
substitute for the capture; same-day restarts reuse it without replacement.

All five kill-state queries succeeded with empty orders. Positions and
pending approvals were empty too: their row fields, `ref_id` and actual
response cursors remain unverified. Field/type observations and remaining
gaps are recorded in
[`live_readiness_2026_11_16.json`](test/fixtures/robinhood/live_readiness_2026_11_16.json).
No arming, order action, credential refresh or policy access occurred.

## Quick start

Limits come first: nothing stores a credential before the policy file
loads. Run these from your project, in this order.

1. Write the policy.

   ```sh
   mix raxol.broker.init --max-notional 25 --daily-cap 100
   ```

   Expect `Wrote broker.policy.exs` and the recommendation to turn on trade
   approvals in the Robinhood app.

2. Sign in and check the session.

   ```sh
   mix raxol.broker.connect
   ```

   The browser opens Robinhood's sign-in. Expect `signed in; credential
   stored`, `connected: 87 tools served`, `agentic account: <number>` and
   `no drift from the capture`.

3. Look before trading.

   ```sh
   mix raxol.broker.inspect --sample "buy F 1 @ 12.25"
   ```

   Expect the accounts, buying power, positions, `mode: disarmed`,
   `journal: ok` and the sample's verdict with `(no order placed)`.

4. Add a strategy.

   ```sh
   mix raxol.broker.strategy add dip_buy --symbol F --usd 25
   ```

   Expect `added dip_buy-F (dip_buy symbol=F usd=25)`.

5. Start the broker in `iex -S mix` (see "Quote feed" for the
   `Raxol.Broker.Supervisor` children) and open the dashboard with
   `Raxol.run(Raxol.Broker.Dashboard)`. Expect `mode: DISARMED` and the
   strategy `running`; its intents are journaled as dry run and nothing is
   sent.

   Keep the read-only client and supervisor running across New York
   midnight when `drawdown_halt` is configured. The executor's account
   automatically starts `DailyBaseline`, using the configured read client's
   name (or the separately started `Raxol.Broker.MCP.Client`). It does not
   create another credential/session. Before arming, check that
   `Raxol.Broker.Journal.day_baseline(account, day)` returns
   `{:ok, %Decimal{}}`, where
   `day = Raxol.Broker.MarketCalendar.day_start(DateTime.utc_now())`.
   Starting after the capture window cannot backfill today's baseline.

6. Arm, from the same `iex` session.

   ```elixir
   Mix.Task.rerun("raxol.broker.arm")
   ```

   Expect the checks, including `account <number> is the agentic account`
   and `trade approvals in the Robinhood app: on`, then type `ARM`; expect
   `armed`. `Mix.Task.rerun("raxol.broker.disarm")` or `K` then `y` on the
   dashboard stops it.
   If trade approvals are off, arming refuses with `{:approvals_off, account}`
   before confirmation and writes nothing; turn them on in the Robinhood app.

   Use `Mix.Task.rerun/2`, not `Mix.Task.run/2`, for every broker task in
   `iex`: `Mix.Task.run/2` runs a task once per VM and answers `:noop`
   after that, so a second arm, kill or beat would silently do nothing.

## Policy

Initialize a policy with explicit monetary caps:

```sh
mix raxol.broker.init --max-notional 1000 --daily-cap 5000
```

The command writes `broker.policy.exs` in the current directory. If either flag
is omitted, it prompts only when connected to a real terminal; noninteractive
use must supply both flags. A prompt accepts the entered line with surrounding
whitespace trimmed; end of input (EOF) fails with a `Mix.Error` and writes
nothing.

The generated policy has all fourteen required keys. `Raxol.Broker.PolicyFile.new/2`
is the single constructor for it: given the two required caps it returns
`{:ok, policy}` with every default filled in, or `{:error, reason}`:

```elixir
{:ok, policy} =
  Raxol.Broker.PolicyFile.new(Decimal.new("1000"), Decimal.new("5000"))
```

The rendered file is:

```elixir
[
  max_notional_per_order: Decimal.new("1000"),
  daily_notional_cap: Decimal.new("5000"),
  max_position_weight: :unset,
  order_types: [:limit],
  options: false,
  advanced_orders: false,
  after_hours_market: false,
  symbols_allow: :unset,
  symbols_deny: [],
  max_orders_per_minute: :unset,
  drawdown_halt: :unset,
  llm_ask_above: :unset,
  ask_timeout: 300_000,
  dead_man_timeout: 86_400_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `daily_notional_cap` | A `Decimal` strictly greater than zero. This cap is required and cannot be `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` greater than zero and less than or equal to one. |
| `order_types` | A nonempty, duplicate-free list containing only the approved atoms `:market`, `:limit`, `:stop_limit` and `:stop_market`. |
| `options` | A boolean. |
| `advanced_orders` | A boolean. |
| `after_hours_market` | A boolean. |
| `symbols_allow` | `:unset`, or a nonempty, duplicate-free list of uppercase symbol strings such as `"AAPL"` or `"BRK.B"`. |
| `symbols_deny` | A duplicate-free list of uppercase symbol strings; may be empty. |
| `max_orders_per_minute` | `:unset`, or an integer from `1` to `10_000`. |
| `drawdown_halt` | `:unset`, or a `Decimal` greater than zero and less than or equal to one: the share of the start-of-day value today's loss may reach. |
| `llm_ask_above` | `:unset`, or a `Decimal` strictly greater than zero. |
| `ask_timeout` | An integer number of milliseconds from `1` to `4_294_967_295`; the generated default is `300_000` (five minutes). |
| `dead_man_timeout` | `:off`, or an integer number of milliseconds from `1` to `4_294_967_295`: the longest silence from every heartbeat before strategies pause; the generated default is `86_400_000` (24 hours). |

`:unset` means that the corresponding optional threshold is not configured and
its rule abstains, except `llm_ask_above`, where `:unset` asks for every
model-originated order. It is valid only for the optional keys; it never
satisfies either required notional cap.

A policy file written before `dead_man_timeout` existed fails to load with
`{:missing_key, :dead_man_timeout}`; add the key.

Policy files are data, not executable Elixir. The loader size-bounds the file,
parses it with existing atoms only, and accepts only the keyword-list literals
shown by this schema. Decimal values must use the exact
`Decimal.new("...")` form. Other calls, variables, operators, any other alias,
`throw`, `exit`, and side effects are rejected without being executed. Invalid,
malformed, or oversized policies fail closed, and a file that is not valid
UTF-8 returns `{:error, {:parse_error, path, :invalid_utf8}}`.

Before parsing, the loader rejects symlinks and applies the trust rules of
`Raxol.Agent.OperatorFile.trusted?/1`: the file must be a regular file owned by
the account the VM runs as, with no group- or other-write bit, in a parent
directory that meets the same owner and mode rule or is sticky. Otherwise
loading returns `{:error, {:untrusted_file, path, reason}}`. A missing file or
a directory returns the missing-file or non-regular-file error instead.

Initialization renders and validates the complete policy before touching the
destination. It creates a same-directory staging file with mode 0600 before
writing to it, writes and syncs it, then applies the same file and directory
trust checks before publishing the final name atomically without replacement.
An unsafe destination directory is refused without leaving a policy or staging
file. An existing file or symlink is left unchanged, and the staging file is
removed after successful publication or an ordinary error.

## Evaluating an order

```elixir
{:ok, intent} = Raxol.Broker.Intent.buy_usd("AAPL", Decimal.new("250"), provenance: :llm)

Raxol.Broker.Policy.evaluate(intent, %Raxol.Broker.Policy.Context{policy: policy, ...})
# => {:allow, intent} | {:ask, [{rule_id, prompt}]} | {:deny, {rule_id, detail}}
```

`Raxol.Broker.Intent` constructors validate model-supplied input and return
`{:error, reason}` instead of raising; `:provenance` (`:strategy`, `:llm`,
`:human` or `{:untrusted, source}`) is required. `Raxol.Broker.Policy.evaluate/2`
reads only the intent and its `Raxol.Broker.Policy.Context` (portfolio value,
positions, quotes, today's notional, orders in the last minute, market session,
review warnings) and does no I/O. Its rules run through
`Raxol.Agent.Authorization.Engine`: any DENY wins, otherwise any ASK, otherwise
ALLOW. `Policy.rule_ids/0` lists the stable rule ids in evaluation order; the
`Raxol.Broker.Policy` moduledoc describes each rule.

Caps are inclusive. A rule that needs a context field left `nil` denies; an
invalid policy or a context field of the wrong type denies before any rule
runs. Untrusted provenance always asks. Cancels are always allowed.

Caller data crosses one boundary, `Raxol.Broker.Plain`: binaries, atoms,
integers, proper lists and tuples, non-struct maps, decimals (a
coefficient of at most 40 digits and an exponent in -40..40) and
`DateTime`s, checked by pattern matching only, so no caller protocol
implementation (Enumerable, Inspect, String.Chars) ever runs on it.
`Intent.normalize/1` and `Policy.Context.normalize/1` rebuild each struct
from plain fields, and the executor, the journal and `Policy.evaluate/2`
each normalize caller data before using it. `evaluate/2` denies non-plain
data with `{:intent, reason}` or `{:context, reason}`.

## Executor

`Raxol.Broker.Executor` is the one path every order takes: policy, the
order's `review_*` tool, policy again with the review's warnings, then
`placing` and the order tool, each step journaled before the next.

```elixir
{:ok, policy} = Raxol.Broker.PolicyFile.load("broker.policy.exs")

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: mcp_client_spec, account_number: "...", policy: policy]}
]

executor = Raxol.Broker.Executor

{:ok, intent} =
  Raxol.Broker.Intent.limit(:buy, "AAPL", qty, price,
    provenance: :strategy,
    id: "dip-2026-10-02"
  )

case Raxol.Broker.Executor.run(executor, intent, context) do
  {:ok, %{status: status, journaled: true}} -> {:sent, status}
  {:ok, %{journaled: false, journal_error: reason}} -> {:sent_unrecorded, reason}
  {:ok, :duplicate} -> :already_placed
  {:ask, token, prompts} -> {:needs_human, token, prompts}
  {:deny, _group_id, {rule_id, _detail}} -> {:denied, rule_id}
  {:error, reason} -> {:nothing_sent, reason}
end
```

Under `Raxol.Broker.Supervisor` the executor starts after the journal and
restarts with it (`:rest_for_one`); the new executor closes any group the
old one left open, including parked ASKs. The supervisor always binds the
executor to its own journal: an `:executor` `:journal` naming another one
makes `start_link/1` return `{:error, {:journal_mismatch, given}}`.

The executor's `init` touches only the journal: it validates its options,
prepares the MCP session without connecting (a live session still fails
start), resolves and monitors the journal, claims it, and closes the groups
left open. The session connects after `init`, without blocking the
executor. Until it is ready, `run/3` and `approve/3` return
`{:error, :port_not_ready}` and open nothing;
`Raxol.Broker.Executor.await_port(executor, timeout \\ 30_000)` returns
`:ok` once it is; a timeout above 4_294_000_000 ms is
`{:error, {:invalid_timeout, :await_port, timeout}}`. When the connection
fails, the session client dies while connecting, or the session dies, the
executor stays up, logs it and reconnects after a backoff (`:reconnect_ms`,
default 1 s, doubling to 60 s, reset once ready). A down endpoint therefore
never restarts the executor and cannot exhaust the supervisor's restart
budget, and nothing needs restarting by hand. A port that drops after the
review but before the place closes the group as `port_not_ready` without
writing `placing`, and a re-run of the same intent places once the port is
back.

`Raxol.Broker.Executor.child_spec/1` sets `shutdown` to the place timeout
plus 5 s (35 s with the defaults), or to the `:shutdown` start option, a
positive integer. A stop during a place waits up to that bound for the
order call; a review in flight is not waited for. Journal writes have their own bound, `:write_deadline`, so a
journal stall that outlasts the shutdown bound ends with the executor
killed; on restart the group closes as `crash_outcome_unknown`, which keeps
counting and is never placed again. The executor
dispatches at most one queued run or approval per callback, so no callback
runs two place calls and the bound covers the place in progress.

A person answers an ASK later with `approve(executor, token, "name")`,
`decline(executor, token, "name")` or `close(executor, token, reason)`.

* **The context is the executor's.** The `:policy` start option (validated
  by `PolicyFile.validate/1`) replaces the context's `policy`;
  `today_notional` and `orders_last_minute` come from the journal, with
  the day starting at midnight America/New_York on both sides of a
  daylight-saving change (`Raxol.Broker.MarketCalendar`, over the `tz`
  database); current quotes, positions and USD portfolio `total_value`
  come through the executor's own session (`Raxol.Broker.Policy.ContextBuilder`,
  `get_equity_quotes`, `get_equity_positions`, `get_portfolio`).
  Start-of-day value comes only from the journal's account/day baseline;
  day P&L is current NAV minus that observation. This is not a cash-flow
  adjusted return: do not deposit or withdraw during the soak. Failed reads
  or a missing baseline leave the fields empty and the dependent rules deny.
  A context fetch crossing New York midnight or a backwards clock change
  is discarded before review; the market session is refreshed at completion.
  Immediately before placing, another asynchronous clock check refuses a
  snapshot whose day or market session changed, or whose clock moved backwards,
  including during review or approval. The executor sends nothing and does not
  retry inline. A retry, including the runner's existing retry path, fetches fresh
  context and reviews again. Cancels and declines remain exempt.
  Positions are read page by page; a listing that fails, cannot be read or
  is longer than
  its page limit leaves them empty too. Full-day NYSE holidays for 2026
  and 2027 and weekends are closed for the entire New York calendar day
  ([NYSE calendar](https://www.nyse.com/trade/hours-calendars)).
  New equity orders are denied on those days regardless of
  `after_hours_market`, preventing holiday-held proposals from using a new
  day's cap. Weekday overnight limit behavior is unchanged; human cancels
  and declines remain available. Half days and later years' holidays
  are not modelled.
* **Drawdown breaker.** A pre-review or approval-time DENY by `:drawdown_breaker` disarms
  the broker, journals a `halt` record and pauses every strategy runner
  (`Raxol.Broker.Halt.pause/2`). The pause is the journal's
  (`Raxol.Broker.Journal.pauses/1`): a runner restarted, or a strategy
  added, while it holds starts paused, and a paused runner sends no
  pending intent. Only a fresh `mix raxol.broker.arm` ends it.
* **Review is mandatory.** `Raxol.Broker.Executor.Place` is the only module
  that names an order tool, and it refuses without a `ReviewReceipt` for
  the same intent and group (an HMAC over the whole intent), verified under
  a key the executor generates at start and keeps in its own process
  dictionary; in any other process there is no key and every receipt is
  refused. The journal also refuses `placing` for a group without a review
  followed by an ALLOW or an approval. A test checks the compiled code for
  order tool calls outside `Place`.
* **Threat model.** The BEAM cannot stop code that deliberately writes
  into another module's private state, e.g. `Process.put` into its slots
  or `:sys.replace_state`. The guarantee is that no path through public
  APIs can send an order tool without the executor's review pipeline.
  Every remaining bypass requires impersonating the executor's private
  process-dictionary slots on purpose.
* **No caller code runs in the executor.** `run/3` rebuilds the intent
  and context from plain data (`Intent.normalize/1`,
  `Policy.Context.normalize/1`) in the caller and again inside the
  executor before anything else; a failure is
  `{:error, {:invalid_intent, reason}}` or
  `{:error, {:invalid_context, reason}}`, with nothing journaled or sent.
  An unrecognised call is `{:error, :unknown_request}`. `:journal` must be a
  registered name (an atom) or a pid; anything else, such as
  `{:via, mod, name}` or `{:global, name}`, is `{:invalid_journal, value}`,
  checked first. The `:clock` fun runs in a short-lived Task with a 5 s
  budget, outside the executor's process; a clock that is not a zero-arity
  fun is `{:invalid_clock, value}` at start, and one that crashes or
  returns anything but a UTC `DateTime` fails the call with
  `{:error, {:context, reason}}` and sends nothing. The clock's result
  passes `Plain.normalize/1` and must be an ISO-calendar `Etc/UTC`
  `DateTime`, otherwise the call is
  `{:error, {:context, {:invalid_clock, _}}}` with no group and no order.
  Terms from other processes (messages, exit reasons, call arguments) are
  only ever inspected with `structs: false`, which a structure test
  enforces for the executor and journal modules. The receipt key enters
  the executor's process dictionary only after its claim succeeds.
* **Bounded timeouts.** `:review_timeout`, `:place_timeout` and
  `:reconnect_ms` must be integers in 1..4_294_000_000 ms, which leaves
  headroom under the VM's timer limit; anything else refuses start with
  `{:invalid_timeout, key, value}`.
* **Any review warning asks.** A warning turns ALLOW into ASK
  (`:review_warning`); a review response that cannot be read counts as one.
  `approve/3` re-fetches quotes, positions, portfolio, calendar and journal
  counters, records the refreshed context, journals approval and re-runs
  policy. A cap reached or position weight changed while waiting denies.
  A fresh drawdown DENY also disarms and pauses all runners. `decline/3`
  and `close/3` end the group. A bad approver name raises in the caller
  and leaves the group parked.
* **Counters come from the journal.** Decisions are serialized, so two
  callers cannot both pass the daily cap, which resets at New York midnight.
  Queued callers are monitored, and a queued run whose caller has died is
  dropped, never dispatched. Ordinary requests keep arrival order.
  Halt interrupts in-flight context, review and reconciliation reads before
  queued work; discarded task results cannot resume the order pipeline,
  even after rearming. Order writes stay bounded and journal-before-send.
* **One executor per journal.** The executor claims the journal at start;
  only a process started as an executor can claim, a second one fails with
  `{:journal_claimed, pid}`, and the journal takes any group record
  (`open_group`, `append_to_group`, `append_group`, every entry type) only
  from the claimant: another process gets `{:error, {:not_claimant, id}}`,
  and with no claim held every group write is `{:error, :unclaimed}`.
  Nothing is written either way. The claimant check comes before the
  journal reads anything the write carries; only then does it rebuild the
  intent and context from plain data (`{:invalid_intent, reason}` or
  `{:invalid_context, reason}` otherwise) and encode them. Fills are not
  group records. The claim lives in the journal's memory, so the executor
  monitors the journal and stops with `{:journal_down, reason}` when it
  goes down; its supervisor restarts it, and the new one claims again.
  Callers waiting on it get an exit. A group left open or parked before an
  executor restart is closed with `executor_restarted`.
* **Idempotent.** An intent id with a `placing` whose outcome is not
  `:failed` returns `{:ok, :duplicate}` and sends nothing, across
  restarts. Each place carries a `ref_id` derived from the intent id,
  which Robinhood deduplicates on. Give intents a stable `:id` for this to
  work.
* **Trade approvals.** When the review response says
  `customer_approval_required`, a successful place is
  `status: :pending_approval`, not `:placed`: Robinhood holds a proposal the
  account owner approves or declines in its app, and no order exists yet.
  The group keeps counting toward the caps and its intent is a duplicate
  until reconciliation reads the proposal back (see "Reconciliation"); the
  order placed after an approval carries the approval id, not the `ref_id`
  sent.
  A recorded response (`test/fixtures/robinhood/review_equity_order.json`)
  confirms the flag sits under `data`. `Raxol.Broker.MCP.Fake` models
  approvals with `trade_approvals: true`.
* **Review alerts.** Robinhood lists its pre-trade alerts in
  `data.order_checks`, `{}` when there are none. `Review` turns every entry
  into a warning, and so an ASK: `"<name>: <message>"` for a string or a
  `"message"`, `"order check <name>"` for a shape it does not know.
  `test/fixtures/robinhood/review_equity_order_checks.json` records a
  non-empty `EQUITY_NOT_ENOUGH_BP` alert from a review-only limit-buy
  simulation above available buying power; no order or approval resulted.
* **Account pin.** The executor's session is ready only when `get_accounts`
  marks its `:account_number` as the one `agentic_allowed` account; it is
  checked on every connect, and again when arming.
* **Two-stage approval requirement.** Start the executor with
  `require_customer_approval: true` to require a literal
  `customer_approval_required: true` from the recorded review before any new
  order is sent. A missing/false flag returns
  `{:error, :customer_approval_unconfirmed}` and closes the group without
  `placing`, including after an operator approves ASK. The default is `false`;
  enable this explicitly for the controlled canary. Cancels and approval
  declines remain available. This does not approve a proposal in Robinhood,
  re-read the upstream setting at placement, or guarantee that an order cannot fill.
* **Explicit order envelope.** Equity review and placement both send
  `time_in_force: "gfd"` and `market_hours: "regular_hours"`, pinning the
  documented defaults rather than relying on omitted arguments. Cancel and
  decline arguments are unchanged; no additional order type or session is enabled.
* **Fail closed.** Any journal error before `placing`, review error or
  unsupported order kind means no order. Once the order call is made the
  result is `{:ok, _}`: a place call that times out is journaled
  `:unknown` and keeps counting, and an order response the journal could
  not record comes back with `journaled: false`. While the port is not
  connected the executor stays up and refuses with
  `{:error, :port_not_ready}` until it reconnects.
* **Armed or disarmed.** No ordinary order tool is sent unless the latest
  mode record is `armed` (see "Arming"). Disarmed intents fetch no context:
  a minimal `mode: dry_run` group closes `not_armed`, and `run/3` returns
  `{:error, :not_armed}`. Mode is read again before `placing`, so disarming
  also stops a parked or in-review group. Only the kill's human cancels
  and declines bypass arming.
* **Sessions.** `mode: :dry_run` (the default) refuses a session that is not
  marked `sandbox: true` or whose URL is on `robinhood.com`. `mode: :live`
  admits Robinhood; with `credential: [store: ..., auth: ...]` the session
  carries the stored credential's bearer, is refreshed five minutes before
  the token expires and on a 401 at connect, and reconnects with the new
  token after any review in flight. A refresh Robinhood refuses disarms the
  broker (`reauth_required`): sign in again with `mix raxol.broker.connect`
  and the executor takes the new credential over, but orders wait for a
  fresh `mix raxol.broker.arm`. Refused refreshes continue retrying, but
  write no repeated `reauth_required` disarm while it is already the latest
  mode record.

Only equity orders (`review_equity_order`, `place_equity_order`) and equity
cancels are mapped until the generated tool adapters land; options and
advanced orders are refused with `{:error, {:no_adapter, kind}}`.

The package requires Plug 1.20.4 or a later 1.20 patch, fixing multipart-parser
advisory EEF-CVE-2026-120287. Gate the actual runtime checkout used by the browser;
an older running process is not upgraded by changing the dependency lock.

Pagination regressions against the real Fake cover multi-page aggregation,
envelope cursors, later-page failures and the twenty-page bound. Those tests
prove local complete-listing behavior, not an actual upstream cursor round trip.
They do not satisfy or waive the live-pagination evidence gate.

## Arming

```sh
mix raxol.broker.connect --account NUMBER   # policy file first, then sign-in, pin and drift report
mix raxol.broker.inspect --sample "buy F 1 @ 12.25"
mix raxol.broker.arm --account NUMBER       # checks, then type ARM
mix raxol.broker.disarm
```

`connect` refuses to run unless `broker.policy.exs` loads, so limits exist
before a credential is stored. It signs in, stores the credential
encrypted, checks that `--account` is the account Robinhood marks
`agentic_allowed` (without `--account` it names that account), and reports
which served tools were added, changed or are missing against the frozen
capture.

`inspect` prints the accounts, the agentic account's buying power (from
`get_portfolio`; `get_accounts` does not carry a reliable figure), its
positions, the mode, the journal's status and the pre-review policy
verdict for a sample intent, through the read-only session only: no review
and no order.

`arm` writes an `armed` mode record (`Raxol.Broker.Mode.arm/1`) only when
the policy file loads, the journal's hash chain verifies on disk (a
one-byte edit blocks arming), the read-only session is connected, the
account (`--account`, else the running executor's) is the agentic one, the
account's trade approvals are on (`human_must_approve_trades: true`), every added strategy's
symbols quote at or below `max_notional_per_order` (limit orders are whole
shares), and you type `ARM` after reading what was checked. The
confirmation shows whether Robinhood's own trade approvals are on
(`human_must_approve_trades`), and the `armed` record keeps it. Only the
owner can change that setting, in the app. `disarm` writes a `disarmed`
record unconditionally.
The journal commits arming only if its mode generation has not changed
since the checks began and no halt marker exists. A kill or other mode
change while the confirmation prompt waits requires starting arm again.
An off setting refuses with `{:approvals_off, account}` before confirmation
and writes nothing; an unreadable setting also refuses.

Both connections, the executor's and the read-only one, refresh through
`Raxol.Broker.Session.refresh/3`, which re-reads the store under a VM-wide
lock first: Robinhood rotates the refresh token, so one connection takes
over a credential the other already rotated rather than spending a token
that is no longer valid.

## Approvals and dashboard

An ASK parks its group in the executor. The executor also owns the
timeout: when the policy's `ask_timeout` (five minutes by default) passes
with the group still parked, it records a post-review DENY with rule id
`ask_timeout`, whether or not anything is showing the ASK.

`Raxol.Broker.Dashboard` is one TEA app for every surface. It shows the
mode, the agentic account with its buying power and positions, the
strategies, each parked ASK with its rules, prompts and the minutes left
before it is denied, and the last journal decisions. `j`/`k` pick an ASK,
`a` approves it, `d` declines it, `K` and then `y` pull the kill switch,
`r` re-reads the account, `q` quits. The focus is the ASK itself: if it is
answered elsewhere or times out, nothing is answered until `j`/`k` picks
again.

Refreshes, account reads, heartbeats, approvals, declines and kills run
independently off the TEA process, with one outstanding task per operation.
Slow approvals and kills remain visibly pending until their actual outcome
returns; frozen dependencies do not block input or independent heartbeats.
Initial account and snapshot loading starts on the first one-second tick.
Kill completion reports incomplete listings and each failed or unknown
cancel/decline explicitly, including the affected id. A successful response
count is not a claim that every order is cancelled; verify the Robinhood app.
If no optional heartbeat process is running, the view explicitly shows
`dead-man switch: not configured`, rather than an uncertain action outcome.

Only an operator may answer or kill, and the operator is what the
approval's `by` and the kill's trigger record. The terminal's operator is
`terminal:<OS user>`. An SSH session's comes from the server's
`:tenant_opts` for the authenticated user. LiveView uses
`liveview:<user>` only when TEALive forwards an authenticated session
identity with `authenticated_user_key: "user_id"` (requires the runtime
identity-forwarding change). Protect the route with your application's
authentication; never set that session key from untrusted input. Missing or
malformed identities and headless sessions remain read-only.

```elixir
Raxol.run(Raxol.Broker.Dashboard)                                    # terminal, in the broker's VM
Raxol.LiveView.TEALive.mount(params, session, socket,
  app_module: Raxol.Broker.Dashboard, authenticated_user_key: "user_id")
Raxol.SSH.serve(Raxol.Broker.Dashboard,
  port: 2222,
  authorized_keys_dir: dir,
  tenant_opts: fn user -> {:ok, [dashboard: [operator: "ssh:" <> user]]} end
)
```

The dashboard reads the processes registered under their default names;
`config :raxol_broker, Raxol.Broker.Dashboard, executor: ..., journal: ...`
names others.

## Reconciliation

When the executor first connects, and every five minutes after
(`:reconcile_ms`), it checks every counted group whose outcome is open
(`Raxol.Broker.Journal.unresolved/1`) against Robinhood and journals a
`resolve` record for each it settles:

| Open outcome | Read | Resolution |
| --- | --- | --- |
| `:unknown` or `crash_outcome_unknown` | every page of `get_equity_orders` (agent-initiated, since its day), matched on the `ref_id` sent | `placed` keeps counting; `absent` stops counting and frees the intent, only when every page was read, the `placing` is at least two minutes old (`:reconcile_min_age_ms`), and the review did not ask for the owner's approval |
| `:pending_approval` | `get_trade_approvals` with the `approval_ids` from the place response, 100 per call | `approved` keeps counting; `declined` or `expired` releases the cap and frees the intent; still pending stays open |

An order made from an approved proposal carries the approval id, not the
`ref_id` sent, so an unknown order whose review asked for approval is never
taken for absent: it keeps counting toward the daily cap. Only the journal's
claimant, the executor, may write a `resolve` record.
`Raxol.Broker.Executor.reconcile/2` runs it on demand.

## Kill switch and dead-man switch

```elixir
# In the broker's iex session (rerun: Mix.Task.run runs a task once per VM)
Mix.Task.rerun("raxol.broker.kill")
Mix.Task.rerun("raxol.broker.beat")
```

`Raxol.Broker.Halt.kill/1` (the task, or `K` then `y` on an operator's
dashboard) disarms, stops every strategy runner, lists the account's open
agent-initiated equity orders (`get_equity_orders`, `agent_initiated:
true`, one listing per open state in lifecycle order, every page) and its
pending trade approvals (`get_trade_approvals`, every page), then cancels
each order and declines each approval through the executor, all in
parallel, each call bounded (10 s by default), and journals a `halt`
record naming the trigger and how each one ended. A cancel past the bound
is journaled `unknown` with `:timeout` and reported; nothing is retried,
but every kill uses its own intent ids, so running it again sends that
cancel again. A listing that fails is reported as incomplete, and the
orders that were read are still cancelled. `decline_trade_approval` is on
the catalog's write allowlist and is reachable only through
`Raxol.Broker.Executor.Place`. The baseline kill-to-all-cancelled latency
against the Fake is in `bench/kill_latency.md`.

From another shell, `mix raxol.broker.kill --journal PATH` submits an empty,
owner-checked 0600 `halt.request` in the private journal directory when the
writer lock is held. Its presence blocks new orders and arming immediately.
The broker's supervised `HaltRequest` polls every 100 ms, disarms once, and runs
the same kill path, including cancels and declines. No node cookie or RPC
endpoint is exposed, and the file accepts no payload or trade operation.
Submission is **not cancellation confirmation**: inspect the halt journal
and the Robinhood app. If the executor is not ready, the marker stays and
an off-process worker waits for readiness with a bound and backoff, without
repeated disarm/halt journal writes. Unsafe markers block trading and are
reported with repair guidance, not repeatedly logged every poll.
Without a running broker, the task opens the journal and disarms only.
Cross-shell requests use the broker's default 10 s per-call bound;
`--bound` overrides calls only when the task runs in the broker's VM.

`Raxol.Broker.Heartbeat` is the dead-man switch: with no beat within the
policy's `dead_man_timeout` (24 hours by default, `:off` to disable) it
journals `dead_man_pause` and pauses every strategy, cancelling nothing;
the next beat journals `dead_man_resume` and resumes them. The pause is
the journal's, so it holds across a runner or heartbeat restart, and only
the heartbeat may write the resume. An operator's open dashboard beats
every second (a read-only one does not); `mix raxol.broker.inspect` and
`mix raxol.broker.beat` beat once. Start it with the `:heartbeat` option of
`Raxol.Broker.Supervisor`.

## Strategies

A strategy (`Raxol.Broker.Strategy`) is a pure state machine: `init/1`
takes its parameters, `update/2` takes a feed message and returns the
intents to send, and `symbols/1` names the symbols it wants quotes for. It
never calls a tool. `Raxol.Broker.Strategy.DipBuy` is the reference: when
a symbol's last price falls `dip` (default 2%) below the highest price seen
since its last buy, it emits one limit buy in whole shares, priced at that
last price, for at most `usd` dollars.

```sh
mix raxol.broker.strategy add dip_buy --symbol F --usd 25 --dip 0.02
mix raxol.broker.strategy list
mix raxol.broker.strategy stop dip_buy-F
```

Each added strategy runs in a `Raxol.Broker.Strategy.Runner` under
`Raxol.Broker.Strategy.Supervisor`. The runner journals every intent
(`emit` record) before handing it to the executor and marks it once the
executor answers (`dispatch` record). On restart, only pending emissions
from the current New York day and no older than `:max_age_ms` (default
`300_000`) are replayed, with the same intent id. Older, future-dated or
unreadable emit timestamps are journaled dispatched as `"expired"` and
never reach the executor. Configure `:max_age_ms` and a zero-arity UTC
`:clock` through `Strategy.Supervisor`. Idempotency still prevents duplicates.

Adding and stopping are journaled, so the broker starts every added
strategy when it starts. The task acts on the broker running in its own VM
(`iex -S mix`) when there is one, and otherwise opens the journal itself;
the journal's writer lock refuses it while the broker runs in another
process.

## Quote feed

`Raxol.Broker.Feed` polls `get_equity_quotes` through the read-only session
for its subscribers' symbols and sends each runner `{:quote, symbol,
%{last: _, bid: _, ask: _}}`. Every poll takes a grant from the shared
`Raxol.Broker.Feed.Bucket` (at most 10 in any 60 seconds by default); a
`429` or `5xx` backs off with jittered doubling from 1 s up to 5 minutes.

```elixir
children = [
  {Raxol.Broker.Supervisor,
   executor: [policy: policy, account_number: account, session: session],
   client: [],
   feed: [interval: 15_000, bucket: [limit: 10, window: 60_000]],
   strategies: []}
]
```

## Decision journal

`Raxol.Broker.Journal` records every order decision in one hash-chained
journal per install, `~/.raxol/broker/journal` (override with
`$RAXOL_BROKER_JOURNAL` or the `:path` option). Start it through
`Raxol.Broker.Supervisor` (`:rest_for_one`, journal first), passing journal
options under `:journal`. Group records are written only by the process
holding the journal's claim, the executor, so callers go through
`Raxol.Broker.Executor`; the sequence below is what it writes.

Each Writer call has a deadline, `:write_deadline` (default 60 s). A write
that misses it may still land, so the journal never reports it as an
error: it kills the Writer and stops with `{:writer_stalled, ms}`, and the
executor stops with it. The kill does not promise that nothing lands, since
a dirty IO NIF already running can finish the write after it. Both
restart, and recovery reads what reached disk: a `placing` that landed closes as `crash_outcome_unknown` and keeps
counting, and one that did not leaves its group closed as
`crash_before_verdict`. A fsync slower than the deadline costs a restart;
in exchange a dead disk cannot hang every order and cancel behind it.

```elixir
children = [{Raxol.Broker.Supervisor, journal: []}]

{:ok, group} = Raxol.Broker.Journal.open_group(intent, context)
:ok = Raxol.Broker.Journal.append_to_group(group, {:verdict, :pre_review, Policy.evaluate(intent, context)})
:ok = Raxol.Broker.Journal.append_to_group(group, {:review, review_response})
:ok = Raxol.Broker.Journal.append_to_group(group, {:verdict, :post_review, verdict})
:ok = Raxol.Broker.Journal.append_to_group(group, {:approval, :approved, "operator"})
:ok = Raxol.Broker.Journal.append_to_group(group, {:placing})
# only now call place_*
:ok = Raxol.Broker.Journal.append_to_group(group, {:order, :placed, order_response})
```

A group is the intent, a snapshot of the policy context, each verdict, any
human approval of an ASK, the review response, a `placing` record, and one
terminal record: the order response (`:placed`, `:pending_approval`, `:failed`
or `:unknown`), a DENY verdict, a declined approval, or `{:close, reason}`.
`open_group/2` makes
the intent durable before any review or order call; `append_group/1` writes a
whole group as one contiguous run. Every record is synced before the call
returns.

`{:placing}` is the write-ahead point for the order call. The journal prices
the order from the group's own intent and context (`Policy.notional/2`) and
refuses an order it cannot price, so nothing unpriced can be sent. An order
response is refused for a group with no `placing` record. Order and review
responses are recorded as given, with floats written as decimal strings.

Each record carries `prev_hash` and `hash` (SHA-256 of its canonical JSON),
so changing, removing or truncating any committed record is detected. The
journal directory is created mode 0700 and its files 0600, and a symlinked,
foreign-owned or group- or other-writable directory is refused. On start the
journal verifies the chain:

  * A damaged journal answers every append and query with
    `{:error, {:journal_damaged, offset}}`; `status/0` and `verify/0` name
    the offset. No order can be sized against it.
  * A group left open by a crash is closed before anything else is written.
    Without a `placing` record it becomes DENY `crash_before_verdict`. With
    one, the order call may have gone out, so it becomes
    `crash_outcome_unknown` and keeps counting toward the caps.

The chain has no key: it catches corruption and naive edits, not someone who
can rewrite the whole directory.

The policy context reads from an index built on start and kept current:

```elixir
{:ok, notional} = Raxol.Broker.Journal.today_notional(start_of_exchange_day_utc)
{:ok, count} = Raxol.Broker.Journal.orders_last_minute(DateTime.utc_now())
{:ok, pnl} = Raxol.Broker.Journal.realized_pnl_today(start_of_exchange_day_utc)
```

An order counts from the moment its `placing` record is written, at the
notional recorded there, and stops counting only when its order response says
`:failed`. Placed, in-flight and unknown-outcome orders all count; cancels,
denials and groups that never reached `placing` do not. The live index and the
one rebuilt at start agree. The caller chooses the day boundary.
`realized_pnl_today/1` sums the realized P&L recorded with `append_fill/1`.

### A damaged journal

A damaged journal stops trading until an operator acts. There is no repair:
the chain exists so history cannot be edited. To recover:

1. Stop the broker and keep the damaged directory as evidence
   (`mv ~/.raxol/broker/journal ~/.raxol/broker/journal.damaged-<date>`).
2. Run `mix raxol.broker.replay --date <today> --journal <archived path>` to
   see the offset of the first broken record.
3. Do not trade again until the next exchange day. A new journal starts with
   empty counters, so on the day of the move it knows nothing about orders
   already placed: today's notional and order rate would start from zero.

### Replay

```sh
mix raxol.broker.replay --date 2026-10-02 [--journal PATH] [--unredacted]
```

Prints every group opened that day (UTC) in journal order: intent, context,
each rule's verdict for each policy pass, review, approval, placing, order,
and outcome. Rules before a denying rule show `pass` (they allowed or asked)
and rules after it `not run`, because the policy stops at the first DENY.
Control characters in recorded text are printed escaped, never raw. The task
reads without taking the writer lock, so it works while the broker runs, and
refuses a journal whose chain does not verify. Account numbers, wherever
they appear in recorded responses, print as `[account]` so a replay can be
shared; `--unredacted` prints them.

## Fake server

`Raxol.Broker.MCP.Fake` stands in for Robinhood's MCP server in tests, dry
runs and backtests. It needs no account and opens no socket.

```elixir
fake =
  Raxol.Broker.MCP.Fake.start(
    quotes: %{"AAPL" => "125.00"},
    warnings: [],
    reject: ["GME"],
    order_states: ["queued", "confirmed", "filled"],
    faults: [{"place_equity_order", {:http, 429}}]
  )

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: Raxol.Broker.MCP.Fake.session(fake), account_number: "FAKE-0001", policy: policy]}
]

Raxol.Broker.MCP.Fake.calls(fake)     # tools/call that reached it, with arguments
Raxol.Broker.MCP.Fake.requests(fake)  # every exchange, :pending until it answers
Raxol.Broker.MCP.Fake.orders(fake)

{:ok, session} = Raxol.Broker.MCP.Client.start_link(Raxol.Broker.MCP.Fake.client_opts(fake))
```

`client_opts/2` gives the read-only session a synthetic credential that can
never refresh, so a dry run never reads your stored credential or reaches
Robinhood's token endpoint (`mcp_opts/1` alone does not isolate it). That
session retries a `429`, `502`, `503` or `504` with jittered doubling backoff
(`:backoff` option), within the caller's timeout and never far enough to open
its circuit breaker; the executor's order port never retries.

`:accept` (or `Fake.accept/2`) limits the bearer tokens the Fake answers;
any other gets the 401 Robinhood answers an invalid token. `forbid_calls/1`
answers every `tools/call` 403, and `server/discover` always gets
Robinhood's plain-text 400.

## Tool catalog

Every tool is classified from the frozen capture in
`priv/robinhood/tools_list.json` (`Raxol.Broker.Tools.Catalog`): `:read`,
`:review` (`review_*_order`, `preview_*_order`), `:write` (an explicit
allowlist: `place_*_order`, `cancel_*_order`, `replace_*_order`, alert
create/update) or `:unknown`. A tool the capture lacks, a write-shaped tool
outside the allowlist, or a review or write tool whose schema changed on the
live server is `:unknown`, and the executor and the read-only session refuse
it. Each connect diffs the live list against the capture and logs the drift.

The read tools are generated as typed functions that validate arguments
against the captured schema before sending:

```elixir
{:ok, result} = Raxol.Broker.Tools.MarketData.get_equity_quotes(session, %{"symbols" => ["AAPL"]})
```

Option-order reads accept `state_group: "open" | "closed"` and
`updated_at_gte` (inclusive UTC timestamp/date) alongside the existing filters.
Use the open group to include orders with pending cancellation; `pending_cancelled`
is a result state, not a supported single-state filter. These are read filters,
not permission to place, cancel or otherwise execute option orders.

The reviewed history guide documents a 5,000-bar cap for explicit intervals.
The option place/review capability descriptions are vendor metadata, not a
broker execution adapter: their workflow guidance cannot bypass local review,
approval or mode gates, and option execution remains unsupported.

To refresh the capture from a signed-in account:

1. Capture, then list what the new capture changes for the order tools:

   ```sh
   mix raxol.broker.capture_tools
   git show HEAD:packages/raxol_broker/priv/robinhood/tools_list.json > /tmp/previous_tools_list.json
   mix run --no-start -e '
     alias Raxol.Broker.Tools.Catalog
     previous = "/tmp/previous_tools_list.json" |> File.read!() |> Jason.decode!() |> Map.fetch!("tools")
     session = Catalog.reconcile(previous)
     IO.inspect(Enum.frequencies(Map.values(Catalog.static())), label: "classes")
     changed = for {name, class} <- Catalog.static(), class in [:review, :write], session[name] != class, do: name
     IO.inspect(Enum.sort(changed), label: "new or changed order tools")
   '
   ```

   A tool on the second line is new, or its `inputSchema` or `annotations`
   changed. Live sessions were refusing a changed one as drifted, and
   committing the capture is what accepts it again. Read its new text against
   `Raxol.Broker.Executor.Review` and `Raxol.Broker.Executor.Place` first, and
   name it in the CHANGELOG.
2. Regenerate the read modules, and check which module each new function
   landed in. One in `MarketData` that is not market data needs a term in the
   families of `Raxol.Broker.Tools.Generator`.

   ```sh
   mix raxol.broker.gen.tools          # --check fails if the checked-in modules are stale
   ```

3. Update the pinned `:write` and `:review` lists in
   `test/raxol/broker/tools/catalog_test.exs`. Editing them is the sign-off
   that a new order tool is meant to be one.
4. Update the counts below from the `classes` line, and the CHANGELOG.

The checked-in capture contains 87 tools; see its provenance for the exact
capture timestamp. There are 57 reads, four reviews, 11 writes and 15 unknowns.
The reviews are `review_equity_order`, `review_option_order`,
`review_advanced_order` and `preview_crypto_order`. Writes are allowlisted equity,
option, crypto and advanced `place_*`/`cancel_*` tool-name shapes, alert create/update,
and `decline_trade_approval`. Classification is not an execution adapter: the
order/cancel adapters are equity-only. Unknown tools remain refused.

## Robinhood sign-in

```elixir
:ok = Raxol.Broker.Login.run()
{:ok, session} = Raxol.Broker.MCP.Client.start_link([])
{:ok, tools} = Raxol.Broker.MCP.Client.list_tools(session)
{:ok, result} = Raxol.Broker.MCP.Client.call(session, "get_accounts", %{})
```

`Login.run/1` opens the browser on Robinhood's consent page and waits for the
redirect on `http://127.0.0.1:<port>/callback`. The endpoints are pinned in
`Raxol.Agent.Auth.Robinhood`; discovery metadata is fetched only to confirm
them, and any difference stops the sign-in. The client registers itself
(dynamic client registration, public client, PKCE S256), and the callback must
carry the `state` it sent and `iss` equal to
`https://agent.robinhood.com/mcp/trading`. The resulting credential is written
encrypted; nothing is stored if any step fails.

### Credential at rest

`Raxol.Broker.CredentialStore` keeps the credential in
`~/.raxol/broker/robinhood.credential` (override with
`$RAXOL_BROKER_CREDENTIAL`) as an AES-256-GCM envelope. The 256-bit key lives
in 1Password when the `op` CLI is installed, otherwise in the macOS login
keychain (service `raxol.broker.credential-key`, account `robinhood`). On any
other system without `op` there is no key store, and the store returns
`{:error, {:keychain_unavailable, :unsupported_os}}` instead of writing.

The keychain item is created by `security`, so any process running as the
same user can read it without a prompt. The keychain protects copies of
`~/.raxol` that leave the machine (backups, dotfile sync), not the running
account. The key is written over stdin and never appears in a process's
arguments.

### Session

`Raxol.Broker.MCP.Client` is the only path to the MCP server. It refreshes the
token shortly before it expires. On a 401 it refreshes once, however many
callers are waiting, stores the rotated refresh token before using the new
access token, and retries each request once. If the refreshed token is refused
too, every call returns `{:error, :unauthorized}` until you sign in again; the
session stops talking to the server but does not crash.

Only the tools Robinhood marks read-only (`get_*`, `preview_scan`, `run_scan`,
`search`) can be called. Orders, cancels, reviews, watchlist, alert and scan
changes, and unknown names return `{:error, {:tool_denied, name}}` without a
request, and `list_tools/1` lists only the allowed tools.
