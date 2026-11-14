# Raxol Agent Client Protocol

Elixir/OTP implementation of [ACP (Agent Client Protocol)](https://agentclientprotocol.com):
the JSON-RPC 2.0 protocol between code editors and AI coding agents (the protocol
Zed and a growing ecosystem of editors/agents speak).

## Installation

```elixir
def deps do
  [
    {:raxol_agent_client_protocol, "~> 0.1"}
  ]
end
```

> Not to be confused with the Virtuals **Agent Commerce Protocol**, an
> unrelated on-chain payments protocol that Raxol also speaks (`Raxol.Earn`).
> This package is the **Agent Client Protocol**: editor↔agent JSON-RPC.

## What this is

- Full ACP v1 surface, both roles (agent **and** client), bidirectional:
  `initialize`, `session/*`, `fs/*`, `terminal/*`, including the agent→client
  request direction (`session/request_permission`, `fs/*`, `terminal/*`).
- OTP-native runtime: one supervised process per connection, per-session
  processes under `DynamicSupervisor` + `Registry`, supervised per-request
  dispatch, fail-closed permission flow.
- Pluggable transports: `stdio` (newline-delimited JSON-RPC, the stock ACP
  wire) and an in-process paired transport (test backbone / BEAM-local).
- **Durable resumable sessions** (vendor extension, `_meta["raxol.io"]` +
  `_raxol/*` methods): offset-based reattach/replay with a
  register-before-high-watermark seam (no gap, no dup), plus offline-verifiable
  capability tokens and taint annotation.

## What ACP is

ACP standardizes the wire between a **client** (the editor/host process: Zed,
an IDE, a CLI) and an **agent** (the AI coding assistant process) as JSON-RPC
2.0 over a byte stream, almost always the agent's stdio. The client launches
the agent as a subprocess and speaks to it over its stdin/stdout, the same
shape as LSP, but for agentic coding sessions instead of language tooling.

The handshake is `initialize` (capability negotiation), then `session/new`
(or `session/load` to resume), then one or more `session/prompt` turns. During
a turn the agent role streams `session/update` notifications back to the
client (assistant text, tool calls, plan updates) and may, mid-turn, become
the *caller*, issuing `session/request_permission`, `fs/read_text_file`,
`fs/write_text_file`, or `terminal/*` requests **to** the client. This
agent→client request direction is why ACP is bidirectional and why this
package implements both roles behind the same `Connection` core rather than
a request/response client library plus a callback-only server.

## Module layers

The library is organized in orthogonal layers, each independently testable:

```
Raxol.AgentClientProtocol
├── Schema.*        # the ACP v1 data model (wire types, total decode)
├── Rpc.*           # JSON-RPC 2.0 envelope (id correlation, error codes)
├── Transport.*      # pluggable byte/message carriers
├── Connection        # one process per peer, either role, request correlation
├── Session            # per-session turn state machine (agent role)
├── Agent / Client       # ergonomic `use`-able behaviours, generated from MethodTable
├── MethodTable / Router  # single source of truth for the wire vocabulary + generated dispatch
└── Ext.*              # vendor extension: durable resumable sessions
```

- **`Schema.*`**: the ACP data model: content blocks, session types,
  `fs`/`terminal` types, capabilities. Ported from the MIT
  `f1729/agent_client_protocol` schema layer (see [Provenance](#provenance)).
  Total decode throughout: unknown/malformed wire input never crashes and
  never mints an atom (`String.to_atom/1` is never called on wire-derived
  data). Decode functions return `{:ok, struct} | {:error, reason}` or a
  best-effort struct with a captured raw fallback, per type.
- **`Rpc.*`**: the JSON-RPC 2.0 envelope: request/response/notification
  framing, `id` correlation (`null | integer | string`, type-preserving:
  the wire type of an id is echoed back exactly, never coerced), and the
  standard JSON-RPC error codes.
- **`Transport.*`**: pluggable message carriers behind one behaviour:
  `Transport.Stdio` (newline-delimited JSON over a real or spawned stdio
  pipe, single-writer serialized) and `Transport.Paired` (an in-process
  pair of linked mailboxes, the test backbone, also usable for BEAM-local
  agent↔client wiring with no subprocess). `Transport.Framer` does the
  byte-splitting (partial-buffer handling, CRLF tolerance, oversized-line
  bounds) shared by stdio-shaped transports.
- **`Connection`**: the correlation + dispatch brain. One GenServer per
  peer link, either role (`:agent` or `:client`; the same module, `role`
  only selects which `MethodTable` direction is inbound). Never blocks on a
  peer; every inbound request/notification dispatches to a
  `Task.Supervisor.async_nolink` task, never runs handler code in its own
  process, and never creates an atom from wire input (method→callback
  mapping is compile-time `Router`/`MethodTable` clauses only).
- **`Session`**: the agent-role per-session turn state machine: prompt
  lifecycle, cancellation, the permission-request round-trip. One process
  per active session under a `DynamicSupervisor`.
- **`Agent` / `Client`**: thin ergonomic `use`-able behaviours over
  `Connection`. Their `@callback`s and default clauses are *generated* from
  `MethodTable.rows_for_side/1` at compile time, so the callback surface can
  never drift from the wire vocabulary the table defines. Override only the
  callbacks your role implements; every other method defaults to
  `{:error, Error.method_not_found()}` (requests) or a silent `:ok`
  (notifications).
- **`MethodTable` / `Router`**: the single source of truth for every ACP
  wire method (direction, JSON-RPC kind, callback atom, param/result schema
  modules, capability gate, layer) plus a compile-time-generated dispatcher.
  Adding or changing a method is a `MethodTable` row edit; the `Router`,
  `Agent`/`Client` callback surfaces, and capability gating all derive from
  it, so they cannot fall out of sync with each other.
- **`Ext.*`**: the vendor extension namespace for durable resumable
  sessions. See [The durable-sessions moat](#the-durable-sessions-moat) below.

## Quickstart: a minimal agent + client over stdio

A toy agent that echoes the prompt back as a single `session/update`, wired
to a client over the ACP stdio transport. This is the same shape a Zed-style
editor host uses to launch and speak to a real coding agent subprocess.

```elixir
# my_agent.exs: runs as its own OS process, speaking on its own stdio.
# Boot it directly with `elixir --no-halt my_agent.exs` (without --no-halt
# the script's last expression returns, the VM halts, and the process this
# file speaks FOR dies before the client ever gets a byte): see
# `Raxol.AgentClientProtocol.Transport.Stdio`'s moduledoc "Modes" section
# for exactly which boot forms are safe for `start_self/1`.
defmodule MyAgent do
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.{ContentChunk, TextContent}
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    InitializeResponse,
    NewSessionResponse,
    PromptResponse
  }

  @impl true
  def initialize(req, _ctx) do
    # Echo back the client's requested protocol version negotiated by
    # `Version.coerce/1`; a real agent may cap this to its own max.
    {:ok, InitializeResponse.new(req.protocol_version)}
  end

  @impl true
  def new_session(_params, _ctx) do
    {:ok, NewSessionResponse.new("sess-1")}
  end

  @impl true
  def prompt(%{session_id: session_id, prompt: blocks}, ctx) do
    text = Enum.map_join(blocks, "", fn {:text, tc} -> tc.text; _ -> "" end)

    chunk = ContentChunk.new({:text, TextContent.new("echo: #{text}")})
    notification = SessionNotification.new(session_id, {:agent_message_chunk, chunk})
    Connection.notify(ctx.conn, "session/update", notification)

    {:ok, PromptResponse.new(:end_turn)}
  end
end

# Boot: adopt this BEAM's own stdin/stdout as the wire. `transport:` takes a
# `{module, handle}` pair (per `Raxol.AgentClientProtocol.Transport`), not
# the bare handle `start_self/1` returns. `Agent.start_link/2` is the
# "Standalone start" convenience: it returns the `ConnectionSupervisor`
# pid directly (not wrapped in a supervisor of your own), which is what
# `Agent.connection/1` needs if you ever want to reach this side's
# Connection pid too.
{:ok, handle} = Raxol.AgentClientProtocol.Transport.Stdio.start_self()

{:ok, _sup} =
  Raxol.AgentClientProtocol.Agent.start_link(MyAgent,
    transport: {Raxol.AgentClientProtocol.Transport.Stdio, handle}
  )
```

```elixir
# A client that spawns the agent above as a subprocess and drives one turn.
# `use Client` alone only wires the protocol plumbing (this quickstart keeps
# the GENERATED default `session_update/2`, which broadcasts to `subscribe/3`
# subscribers; see `Client.prompt/3`'s "Precondition" doc: override
# `session_update/2` yourself and `prompt/3` silently returns `[]` forever).
defmodule MyClient do
  use Raxol.AgentClientProtocol.Client
end

alias Raxol.AgentClientProtocol.Client
alias Raxol.AgentClientProtocol.Connection
alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeRequest, NewSessionRequest}
alias Raxol.AgentClientProtocol.Schema.AgentTypes.PromptRequest
alias Raxol.AgentClientProtocol.Schema.ContentBlock

{:ok, handle} =
  Raxol.AgentClientProtocol.Transport.Stdio.start_spawn("elixir", [
    "--no-halt",
    "my_agent.exs"
  ])

{:ok, sup} =
  Client.start_link(MyClient, transport: {Raxol.AgentClientProtocol.Transport.Stdio, handle})

# `sup` is the ConnectionSupervisor, not the Connection; every request
# needs the Connection pid, so resolve it via the public accessor first
# (the same one the package's own end-to-end test uses internally). This
# only works because we booted via `start_link/2` above: wrapping
# `child_spec/1` in a supervisor of your own (the "library-mode wiring"
# pattern, see that section below) makes `sup` YOUR supervisor instead,
# one level further out; resolve the `ConnectionSupervisor` child from
# `Supervisor.which_children(your_sup)` first in that case, then call
# `connection/1` on THAT pid.
{:ok, conn} = Client.connection(sup)

# The mandatory handshake: no other request is legal before `initialize`.
{:ok, _init_response} =
  Connection.request(conn, "initialize", InitializeRequest.new(1), 5_000)

{:ok, new_session_response} =
  Connection.request(conn, "session/new", NewSessionRequest.new(File.cwd!()), 5_000)

session_id = new_session_response.session_id

prompt = PromptRequest.new(session_id, [ContentBlock.from_string("hello, agent")])

{:ok, {updates, _prompt_response}} = Client.prompt(conn, prompt)

for update <- updates, do: IO.inspect(update, label: "agent said")
```

For BEAM-local wiring (no subprocess, e.g. tests or an in-process agent
runtime) swap `Transport.Stdio` for
`Raxol.AgentClientProtocol.Transport.Paired.create_pair/0`, which hands
back two linked transport handles.

## The durable-sessions moat

Stock ACP session state is process-local: kill the agent, lose the turn
history. `Ext.*` adds a vendor extension (`_meta["raxol.io"]` on the
standard `session/load`/`session/update` methods, plus new `_raxol/*`
methods) that makes a session **durable and reattachable across
connections and processes** without changing the client's steady-state
protocol experience:

- **Append-only journal, single publisher.** Every durable record for a
  session (turn boundaries, streamed updates, genesis) passes through
  exactly one `Ext.Journal.Writer` process per `session_id`. Append is
  strictly append-then-publish: a subscriber only ever sees a record after
  it is durably written, never before (no publish-ahead).
- **Offset-based reattach/replay, no gap, no dup.** A reattach
  (`session/load` with the `_meta["raxol.io"]` rider, or
  `_raxol/session.load`) authorizes, then **registers as a live
  subscriber first**, and only *after* that reads the store's high
  watermark `h`. History `(from..h]` is replayed as wire frames, then the
  response carries `h` back to the caller: replay-before-respond, so the
  response always serializes after the last history frame it promised.
  From then on the gate is permanent and monotone: `offset <= h` drops
  (already delivered in history), `offset > h` forwards live. Registering
  before reading `h` is the whole correctness argument. Reading `h` first
  would leave a window where a live record between the read and the
  registration is silently lost.
- **Ed25519 offline-verifiable capability tokens (`RXC1`).** An attach to a
  **writerless** session (a tarred journal directory, no live authority,
  no network, no issuer reachable) can be authorized from the token bytes
  and a shipped public key alone: `RXC1.<base64url claims>.<base64url sig>`,
  detached Ed25519 over the version-pinned prefix + claims, no `alg` field
  anywhere (the algorithm is the literal `RXC1` prefix, so a JWT-style
  `alg:none`/downgrade confusion is structurally unexpressible). Every
  attach, token or process-local (`AttachPolicy.LocalNode`), is decided
  by exactly one fail-closed funnel; any non-`{:ok, %Grant{}}` result
  denies, full stop.
- **Taint: annotate, never filter.** Every delivered record carries its
  taint (`_meta["raxol.io"]` on `session/update` frames, a named top-level
  field on `_raxol/session.record`). No code path in this package drops,
  withholds, or reroutes a record by taint. The only filtering axis is
  *kind* (applied identically to history and live replay), which keeps
  `history ++ live == the durable stream` as an invariant a caller can
  actually rely on. Taint is a caller-side redaction signal, not an
  in-package access control.

Today's journal store (`Ext.Journal.Mem`) is in-memory, durable across
*connections* within one node's lifetime, not across node restarts. No
disk-backed store ships; see [Invariants a change must keep](#invariants-a-change-must-keep)
for what one would have to satisfy.

**The moat ships opt-in, not turnkey.** `Ext.*` (journal, `Reattach`,
`AttachPolicy`) is a set of primitives your agent handler wires together,
`use Agent` alone gives you `method_not_found` on `session/load`'s
`_meta["raxol.io"]` rider and on `_raxol/session.load`, because no default
`Agent`/`Client` callback body can know your session-to-journal mapping or
which `AttachPolicy` you want. Turning it on is the ~30 lines below in your
own `new_session`/`raxol_load_session` callbacks, plus the three shared
processes in `RaxolAgentClientProtocol.Application.children/0`
started somewhere in your supervision tree.

### Enabling durable resumable sessions

Two things have to be true before an attach can succeed: (1) the shared
`Ext.Journal.WriterRegistry`/`WriterSupervisor` and `Ext.AttachPolicy.TaskSupervisor`
processes are running (splice `RaxolAgentClientProtocol.Application.children/0`
into your own supervisor, or let the package's own `Application` auto-start
them, see its moduledoc), and (2) your agent handler implements `new_session/2`
to open a journal + start the durable `Session`, and `raxol_load_session/2` to
route `_raxol/session.load` through `Reattach.attach/1`. Adapted from the
end-to-end test's `RefAgent`
([`test/integration/end_to_end_test.exs`](https://github.com/DROOdotFOO/raxol-agent/blob/main/packages/raxol_agent_client_protocol/test/integration/end_to_end_test.exs)),
the real public-API sequence:

```elixir
defmodule MyDurableAgent do
  use Raxol.AgentClientProtocol.Agent
  alias Raxol.AgentClientProtocol.Ext.{Journal, Reattach}
  alias Raxol.AgentClientProtocol.Ext.AttachPolicy.LocalNode
  alias Raxol.AgentClientProtocol.Session
  alias Raxol.AgentClientProtocol.Session.Emitter.Journal, as: JournalEmitter
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.NewSessionResponse

  # handler_arg = %{session_id: sid, journal: {Mem, ref}}: open the journal
  # (`Ext.Journal.Mem.open/1`) before starting the connection, pass it in via
  # `handler_arg:`; `init/1` just threads it into `ctx.handler_state`.
  @impl true
  def init(arg), do: {:ok, arg}

  @impl true
  def new_session(_req, ctx) do
    %{session_id: sid, journal: journal} = ctx.handler_state
    {:ok, _writer} = Journal.ensure_writer(sid, journal)

    {:ok, _session} =
      Session.Supervisor.start_session(ctx.session_sup,
        session_id: sid,
        conn: ctx.conn,
        task_sup: ctx.task_sup,
        turn_runner: &my_turn_runner/2,
        emitter: JournalEmitter,
        journal: journal
      )

    {:ok, NewSessionResponse.new(sid)}
  end

  # `_raxol/session.load`: the one attach seam every reattach converges on.
  @impl true
  def raxol_load_session(%{session_id: sid, _meta: meta}, ctx) do
    %{journal: journal} = ctx.handler_state
    rider = Reattach.parse_rider(get_in(meta, ["raxol.io"]))

    Reattach.attach(%{
      conn: ctx.conn,
      session_id: sid,
      reply_ref: ctx.reply_ref,
      journal: journal,
      from_offset: rider.from_offset,
      history_policy: rider.history_policy,
      capability: rider.capability,
      offset_aware?: true,
      surface: :process,
      transport: %{kind: :process, peer: nil},
      # LocalNode grants any in-BEAM :process attach; swap in
      # `Ext.AttachPolicy.Token` for signed RXC1 capability tokens instead.
      policy: LocalNode
    })
  end
end
```

Splice the three shared processes into your supervision tree once, at the
app level, not per-connection, required for `Journal.ensure_writer/2` and
`Reattach.attach/1` to work at all:

```elixir
children = RaxolAgentClientProtocol.Application.children() ++ [my_other_children]
Supervisor.start_link(children, strategy: :one_for_one, name: MyApp.Supervisor)
```

Without a `start_subscriber:` override in the `attach/1` call above, the
Reattach `Subscriber` links to the ephemeral dispatch task and is torn down
when it exits, fine for a demo, but see `RefAgent`'s `start_subscriber:`
(starts the subscriber under `ctx.session_sup` instead) if you need its
lifetime tied to the connection rather than the single dispatch.

## Provenance

See [NOTICE.md](NOTICE.md) for the full attribution. Summary:

- **Schema/serialization layer + wire-byte test fixtures**: ported
  MIT→MIT from [`f1729/agent_client_protocol`](https://github.com/f1729/agent-client-protocol-elixir)
  (Copyright (c) 2025 f1729), defects fixed, restructured under
  `Raxol.AgentClientProtocol.*`. Ported modules note this in their
  moduledoc.
- **Conformance case corpus** (`test/conformance/cases/*.json`): ported
  MIT→MIT from [`openclaw/acpx`](https://github.com/openclaw/acpx)
  (Copyright (c) 2025 OpenClaw Team).
- **OTP runtime** (Connection, Session, Transport, supervision, the `Ext.*`
  extension) is a **clean-room implementation**. The official Apache-2.0
  ACP SDKs (`agentclientprotocol/{rust,typescript,python,java,kotlin}-sdk`),
  `lostbean/acpex`, and `xai-org/grok-build` were studied as *design
  references only*: ideas, never code, and never a source of copied
  license terms.
- **`priv/schema-oracle/`**: the official ACP JSON Schema (Apache-2.0),
  SHA256-pinned at `schema-v1.19.0`, used **only** as a dev/test validation
  oracle. It never ships: excluded from the published Hex package via
  `mix.exs`'s `:files` list. This is what keeps the *shipped* package
  pure-MIT despite studying an Apache-2.0 spec.

This layered provenance is a deliberate license-discipline decision, not an
accident. See [ADR-0041](https://github.com/DROOdotFOO/raxol-agent/blob/main/docs/adr/0041-agent-client-protocol-package.md)
for the full reasoning.

## Conformance

Three independent nets, each catching a different class of drift. The
suites live in the package's
[`test/`](https://github.com/DROOdotFOO/raxol-agent/tree/main/packages/raxol_agent_client_protocol/test)
directory in the repository; none of them ships in the Hex package.

- **`test/conformance/acpx_cases_test.exs`** replays the 21 ported `acpx`
  case fixtures (`test/conformance/cases/*.json`) through a native Elixir
  runner (`test/support/conformance/case_runner.ex`) against mock
  agent/client handlers: an external, MIT-licensed opinion on wire
  behavior this package didn't author.
- **`priv/schema-oracle/`** (via `mix acp.schema.verify` + the schema test
  suite) pins the *official* ACP JSON Schema and validates our hand-written
  `Schema.*` types against it, catching drift from the spec itself, not
  just from `acpx`'s interpretation of it.
- **`test/torture/`**: `wire_torture_test.exs` (malformed/adversarial wire
  input, total-decode fuzzing) and `pbus_coverage_audit_test.exs` (an
  audit that every journal and reattach invariant has at least one
  exercising test): the interop/robustness net beyond happy-path
  conformance.

## Testing

From a checkout of [the repository](https://github.com/DROOdotFOO/raxol-agent):

```bash
cd packages/raxol_agent_client_protocol && MIX_ENV=test mix test
mix acp.schema.verify   # oracle drift gate
```

Focused runs:

```bash
# One layer
MIX_ENV=test mix test test/schema/
MIX_ENV=test mix test test/ext/

# Conformance + torture nets only
MIX_ENV=test mix test test/conformance/ test/torture/

# Property-based round-trip tests (StreamData)
MIX_ENV=test mix test test/schema/roundtrip_property_test.exs
```

## Invariants a change must keep

Any change to the reattach/attach-policy surface (`Ext.*`) or to the
connection/router core must keep these:

- **Connection and router.** The `Connection` never blocks on a peer,
  never runs handler code in its own process, never mints an atom from
  wire input, and sends at most one response frame per inbound id, also
  under cancellation races.
- **Attach.** Every attach is decided by exactly one fail-closed
  authorization funnel (no second try/catch wrapper around it), a
  reattacher registers as a live subscriber before it reads the high
  watermark, and the `RXC1` token format has no algorithm field to
  downgrade.
- **On-disk writes.** `Ext.Journal.Mem` keeps the journal in memory, so
  nothing is written to disk. A store that writes to disk must create its
  files with `0600`/`0700` permissions: durable records never land
  world-readable.

## Two `Ctx` modules

`Raxol.AgentClientProtocol.Connection.Ctx` (the per-dispatch struct every
handler callback receives) and `Raxol.AgentClientProtocol.Ctx` (a separate
ergonomic layer of plain pid-taking wrapper functions for code running
*inside* a `session/prompt` turn task) share the "Ctx" name but are
deliberately two different things: a turn task cannot structurally reach
the dispatch-time `Connection.Ctx` at all, so `Raxol.AgentClientProtocol.Ctx`
does not compete with it as a second struct; its moduledoc has the full
"why this isn't built on `Connection.Ctx`" rationale.
