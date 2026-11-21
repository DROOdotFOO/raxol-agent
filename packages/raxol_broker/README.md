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
  ask_timeout: 30_000
]
```

| Key | Accepted value |
| --- | --- |
| `max_notional_per_order`, `daily_notional_cap` | A `Decimal` > 0. Required, never `:unset`. |
| `max_position_weight` | `:unset`, or a `Decimal` in (0, 1]. |
| `order_types` | A nonempty, duplicate-free subset of `:market`, `:limit`, `:stop_limit`, `:stop_market`. |
| `options`, `advanced_orders`, `after_hours_market` | A boolean. |
| `symbols_allow` | `:unset`, or a nonempty list of uppercase symbols. |
| `symbols_deny` | A list of uppercase symbols, possibly empty. |
| `max_orders_per_minute` | `:unset`, or an integer in 1..10_000. |
| `drawdown_halt` | `:unset`, or a `Decimal` in (0, 1]: the share of start-of-day value today's loss may reach. |
| `llm_ask_above` | `:unset` (every model-originated order asks), or a `Decimal` > 0. |
| `ask_timeout` | Milliseconds in 1..4_294_967_295. |

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
  warnings come from the journal, so decisions are serialized.
- Review is mandatory. `Executor.Place` is the only module that names an order tool, and it
  requires an HMAC review receipt under a key held only in the executor process.
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

## Decision journal

`Raxol.Broker.Journal` is a hash-chained journal at `~/.raxol/broker/journal` (or
`$RAXOL_BROKER_JOURNAL`), with directories 0700 and files 0600. Each decision is a group: the
intent, a snapshot of the context, the verdicts, the review, any approval, `placing`, and one
terminal record. `placing` is the write-ahead point: the journal prices the order and refuses one
it cannot price. Every record is synced before the call returns.

On start the journal verifies its chain. A damaged journal answers every call with
`{:error, {:journal_damaged, offset}}`. A group left open by a crash closes as
`crash_before_verdict` (no `placing`) or `crash_outcome_unknown` (it keeps counting).

An order counts toward `today_notional/1` and `orders_last_minute/1` from its `placing` record
until a `:failed` response.

A damaged journal cannot be repaired, because the chain exists so history cannot be edited. To
recover: stop the broker, move the directory aside as evidence, run the replay below to find the
first broken offset, and don't trade until the next exchange day (a new journal starts with empty
counters).

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

`Raxol.Broker.MCP.Client` is the only path to the server. It refreshes the token before it expires,
and on a 401 refreshes once and retries once. It calls only tools that Robinhood marks read-only.
