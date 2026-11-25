# Raxol Broker

Fail-closed brokerage for Raxol agents: a policy file, a pure order policy, one reviewed order
path, a hash-chained decision journal, and a Robinhood MCP session. Pre-alpha. Orders run in dry
run only: `mode: :armed` returns `{:error, :not_armed}`.

## Policy

```sh
mix raxol.broker.init --max-notional 1000 --daily-cap 5000
```

This writes `broker.policy.exs` (mode 0600) in the current directory. It prompts for a missing
flag only on a real terminal, and never replaces an existing file.
`Raxol.Broker.PolicyFile.new/2` builds the same policy from the two caps:

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
  ask_timeout: 300_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order`, `daily_notional_cap` | A `Decimal` > 0. Required, never `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` in (0, 1]. |
| `order_types` | A nonempty, duplicate-free subset of `:market`, `:limit`, `:stop_limit`, `:stop_market`. |
| `options`, `advanced_orders`, `after_hours_market` | A boolean. |
| `symbols_allow` | `:unset`, or a nonempty, duplicate-free list of uppercase symbols. |
| `symbols_deny` | A duplicate-free list of uppercase symbols, possibly empty. |
| `max_orders_per_minute` | `:unset`, or an integer in 1..10_000. |
| `drawdown_halt` | `:unset`, or a `Decimal` in (0, 1]: the share of start-of-day value today's loss may reach. |
| `llm_ask_above` | `:unset` (every model-originated order asks), or a `Decimal` > 0. |
| `ask_timeout` | Milliseconds in 1..4_294_967_295. The generated default is `300_000` (five minutes). |

Every key is required. The file is parsed as data and never evaluated. Only these literals and
`Decimal.new("...")` are accepted. Anything else, an oversized file or invalid UTF-8 fails
closed. `PolicyFile.load/1` refuses symlinks and any file that
`Raxol.Agent.OperatorFile.trusted?/1` rejects (it must be owned by this account, with no group or
other write bit, in a safe parent directory).

## Evaluating an order

```elixir
{:ok, intent} = Raxol.Broker.Intent.buy_usd("AAPL", Decimal.new("250"), provenance: :llm)

Raxol.Broker.Policy.evaluate(intent, %Raxol.Broker.Policy.Context{policy: policy, ...})
# => {:allow, intent} | {:ask, [{rule_id, prompt}]} | {:deny, {rule_id, detail}}
```

`evaluate/2` is pure and runs its rules through `Raxol.Agent.Authorization.Engine`: any deny wins,
then any ask. Caps are inclusive. A missing context field denies, untrusted provenance always
asks, and cancels are always allowed. `Policy.rule_ids/0` lists the rules in order.

Caller data crosses one boundary, `Raxol.Broker.Plain`, which checks terms by pattern matching
only, so no caller protocol implementation ever runs. `Intent.normalize/1` and
`Policy.Context.normalize/1` rebuild the structs from plain fields.

## Executor

`Raxol.Broker.Executor` is the only path an order can take: policy, the order's `review_*` tool,
policy again with the review's warnings, then `placing` and the order tool. Each step is
journaled before the next one runs.

```elixir
{:ok, policy} = Raxol.Broker.PolicyFile.load("broker.policy.exs")

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: mcp_client_spec, account_number: "...", policy: policy]}
]

case Raxol.Broker.Executor.run(Raxol.Broker.Executor, intent, context) do
  {:ok, %{status: status, journaled: true}} -> {:sent, status}
  {:ok, %{journaled: false, journal_error: reason}} -> {:sent_unrecorded, reason}
  {:ok, :duplicate} -> :already_placed
  {:ask, token, prompts} -> {:needs_human, token, prompts}
  {:deny, _group_id, {rule_id, _detail}} -> {:denied, rule_id}
  {:error, reason} -> {:nothing_sent, reason}
end
```

Answer an ask with `approve/3`, `decline/3` or `close/3`. Approval re-reads the counters and
re-runs the policy.

- The executor's `:policy` replaces the caller's. Today's notional, the order rate and the review
  warnings come from the journal, so decisions are serialized. Every other context field
  (`quotes`, `positions`, `portfolio_value`, `start_of_day_value`, `day_pnl`, `market_session`)
  is trusted from the caller until #1185 sources it, so the drawdown, position-weight and
  after-hours rules rest on caller data.
- Review is mandatory. `Executor.Place` is the only module that names an order tool, and it
  requires an HMAC review receipt under a key held only in the executor process. This covers
  public API paths only: code in the same VM that deliberately writes the executor's private
  state (`Process.put`, `:sys.replace_state`) can bypass it.
- Any review warning, or a review it cannot read, turns allow into ask.
- Orders are idempotent per intent id, and each place call carries a `ref_id` derived from it. Give
  intents a stable `:id`.
- The executor fails closed: a journal error before `placing`, a review error or an unsupported
  order kind means no order. A place call that times out is journaled `:unknown` and keeps
  counting toward the caps.
- While the MCP session is down, the executor stays up, refuses with
  `{:error, :port_not_ready}` and reconnects with backoff.
- One executor per journal. A restart closes any group left open.
- Only equity orders and cancels are mapped. Other order kinds return
  `{:error, {:no_adapter, kind}}`.
- The session must be marked `sandbox: true` and must not point at `robinhood.com`.

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
executor answers (`dispatch` record). A runner that restarts re-sends each
intent it emitted and never saw answered, with the same intent id, so the
executor's idempotency check and the `ref_id` derived from that id keep it
to one order.

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

`Raxol.Broker.Journal` is a hash-chained journal at `~/.raxol/broker/journal` (or
`$RAXOL_BROKER_JOURNAL`), with directories 0700 and files 0600. Each decision is a group: the
intent, a snapshot of the context, the verdicts, the review, any approval, `placing`, and one
terminal record. `placing` is the write-ahead point: the journal prices the order and refuses one
it cannot price. Every record is synced before the call returns.

On start the journal verifies its chain. A damaged journal answers every call with
`{:error, {:journal_damaged, offset}}`. A group left open by a crash closes as
`crash_before_verdict` (no `placing`) or `crash_outcome_unknown` (it keeps counting).

An order counts toward `today_notional/2` and `orders_last_minute/2` from its `placing` record
until a `:failed` response.

The chain has no key. It detects corruption and naive edits, but not someone who can rewrite the
whole directory. A damaged journal cannot be repaired. To
recover:

1. Stop the broker and move the directory aside as evidence
   (`mv ~/.raxol/broker/journal ~/.raxol/broker/journal.damaged-<date>`).
2. Run `mix raxol.broker.replay --date <today> --journal <archived path>` to find the first broken
   offset.
3. Don't trade for 24 hours. A new journal starts with empty counters, and the daily cap is a
   rolling 24-hour window.

```sh
mix raxol.broker.replay --date 2026-10-02 [--journal PATH]
```

Replay prints each group opened that UTC day, with control characters escaped. It needs no writer
lock and refuses a chain that does not verify.

## Fake server

`Raxol.Broker.MCP.Fake` is Robinhood's MCP server running in process, for tests, dry runs and
backtests. It needs no account and opens no socket.

```elixir
fake =
  Raxol.Broker.MCP.Fake.start(
    quotes: %{"AAPL" => "125.00"},
    reject: ["GME"],
    order_states: ["queued", "confirmed", "filled"],
    faults: [{"place_equity_order", {:http, 429}}]
  )

children = [
  {Raxol.Broker.Supervisor,
   executor: [session: Raxol.Broker.MCP.Fake.session(fake), account_number: "FAKE-0001", policy: policy]}
]
```

`Fake.client_opts/2` gives a read-only session a synthetic credential that can never refresh, so a
dry run never reads your stored credential.

## Tool catalog

`Raxol.Broker.Tools.Catalog` classifies each tool in `priv/robinhood/tools_list.json` as `:read`,
`:review`, `:write` (an explicit allowlist) or `:unknown`. A tool missing from the capture, or a
review or write tool whose schema changed on the live server, is `:unknown` and refused. Read tools
are generated as typed functions (`Raxol.Broker.Tools.MarketData.get_equity_quotes/2`, and others).

To refresh the capture:

1. `mix raxol.broker.capture_tools`, then review every new or changed review or write tool against
   `Executor.Review` and `Executor.Place`.
2. `mix raxol.broker.gen.tools` (`--check` fails when the generated modules are stale).
3. Update the pinned `:write` and `:review` lists in `test/raxol/broker/tools/catalog_test.exs`,
   and the CHANGELOG.

## Robinhood sign-in

```elixir
:ok = Raxol.Broker.Login.run()
{:ok, session} = Raxol.Broker.MCP.Client.start_link([])
{:ok, result} = Raxol.Broker.MCP.Client.call(session, "get_accounts", %{})
```

`Login.run/1` uses pinned endpoints, dynamic client registration, PKCE, and `state` and `iss`
checks on a `127.0.0.1` callback. `Raxol.Broker.CredentialStore` writes the credential as an
AES-256-GCM envelope to `~/.raxol/broker/robinhood.credential`. The key is kept in 1Password when
`op` is installed, otherwise in the macOS keychain. On any other system the store refuses to write.
Any process running as the same user can read the keychain item without a prompt: the keychain
protects copies of `~/.raxol` that leave the machine, not the running account.

`Raxol.Broker.MCP.Client` is the only path to the server. It refreshes the token before it expires,
and on a 401 refreshes once and retries once. It calls only tools that Robinhood marks read-only.
