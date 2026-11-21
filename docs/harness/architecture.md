# Harness Architecture

The harness is the headless agent-session engine. Agent sessions started by `raxol acp --agent`
and by the `agent_*` MCP tools run on it. The core owns all durable state and emits typed events.
Surfaces only subscribe: a surface's view is `Raxol.Harness.Projection.project/2` over the
session's events, so restarting a surface loses nothing.

## The event contract

Events flow from the core to surfaces. The contract defines no commands. The envelope, its
families and tiers, and the rule that the contract only grows are specified in the
[`raxol_journal` README](https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_journal/README.md#the-event-contract).
Only `:loop` events become transcript blocks. `item_delta`, the one ephemeral event, feeds the
live tail. Readers skip what they do not recognize: `Block` renders an unknown `kind` as
`:opaque`.

A surface's own commands (`Raxol.UI.Harness.Keymap`, plain `%{type, payload}` maps) are outside
the contract. `:interrupt` and `:steer` leave through `Raxol.Harness.Surface`'s `:command_sink`,
and nothing consumes them yet.

## Journal and projection

The journal is the source of truth. `Raxol.Agent.Journal` and `Raxol.Agent.Journal.FileStore`
live in `raxol_journal`, whose
[README](https://github.com/DROOdotFOO/raxol/blob/master/packages/raxol_journal/README.md#the-journal)
covers the layout, the writer lock and damage handling. A session's journal is
`~/.raxol/sessions/<id>/`. An agent started over MCP or ACP lives one level down, under
`<first 8 hex of sha256(project root)>/<id>/`.

A session started with `journal_required: true` writes `agent_started` (payload `prior_offset`)
each time it opens its journal, followed by a `turn_canceled` (reason `agent_restarted`) for each
turn the previous run left open. `Raxol.Agent.Session` brackets each prompt turn under its own
turn id (`acp-...`): `turn_started`, then `turn_completed`, `turn_canceled` (`cancelled` or
`caller_down`) or `error` (`turn_failed` or `agent_down`).

`Projection.project/2` is a pure fold. `filter_ids/1` drops duplicate and out-of-order records
and marks a forward gap `damaged?` while keeping the records that survive. `partition_families`
keeps `:loop` events, `bucket_by_turn` groups them by `turn_id`, and `BlockBuilder` folds each turn
into blocks.

### Golden corpora

`raxol_journal` keeps one frozen journal per `schema_version` in the runtime repository. Freeze
the current version from here:

```bash
cd packages/raxol_agent && MIX_ENV=test mix run scripts/freeze_golden_journal.exs [DIR]
```

`DIR` defaults to `raxol_journal`'s `priv/golden` when `RAXOL_PATH` names a runtime checkout. The
manifest is re-pinned and checked in the runtime repository
(`elixir scripts/check_journal_goldens.exs [--bless]`).
`Raxol.Agent.Invariants.ContractInvariantsTest` replays the current corpus through the live
reader.

## Process topology

`Raxol.Agent.Session.Supervisor` is one `:rest_for_one` subtree per session, with children in
dependency order:

1. `Raxol.Agent.EmitBridge`, which owns the journal handle and the EmitBus subscription;
2. `Raxol.Core.Runtime.Lifecycle`, the per-session TEA runtime;
3. `Raxol.Agent.Session`, a thin forwarder.

A session crash restarts only the session, which finds the running Lifecycle again through
`Raxol.Agent.Registry`, so the model survives. A bridge crash restarts the whole subtree, so no
durable event is ever emitted while the sink is dead.

## The safety substrate

Spend is gated outside the model. The gate is built and tested, but it is not in the path of a
session started by `raxol acp` or `raxol mcp`.

- `Raxol.Agent.SpendGate` journals `reserve -> call -> settle` for each spend-bearing call,
  correlated by an opaque `cost_ref`, and fails closed (no reserve, no call). It mirrors the
  atomic `try_spend` shape of `Raxol.Payments.Ledger` without depending on it. Records leave
  through an injected `context.emit`, and if that sink raises, the error propagates as
  `SpendGate.JournalWriteError` instead of dropping the record. The gate runs only where a host
  puts `Raxol.Agent.McpSpendHook` in `:tool_call_hooks` beside a `:spend_gate`.
- `Raxol.Agent.Authorization.Engine` is the pure ALLOW/ASK/DENY reducer. Enforce typed intent, not
  string denylists.

## Surfaces

`Raxol.Harness.Surface` assembles `Projection`, `Composer`, `Keymap`, `StatusStrip` and the
overlay pickers. It replays fixture sessions. `append_events/2` and `:command_sink` are where a
live session would connect. Multi-surface parity (terminal, LiveView, SSH and MCP rendering the
same session identically) is checked in the runtime repository by `Raxol.Harness.Surface.Parity`.

ACP wiring is described in [Editor ACP](../features/EDITOR_ACP.md).
