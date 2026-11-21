# Raxol Agent Client Protocol

Elixir/OTP implementation of [ACP (Agent Client Protocol)](https://agentclientprotocol.com),
the JSON-RPC 2.0 protocol between code editors and AI coding agents. Not to be
confused with the Virtuals Agent Commerce Protocol (`Raxol.Earn`).

```elixir
def deps do
  [{:raxol_agent_client_protocol, "~> 0.2"}]
end
```

## Features

- The full ACP v1 surface in both roles, including agent-to-client requests
  (`session/request_permission`, `fs/*`, `terminal/*`).
- One supervised process per connection and per session; handlers run in
  supervised tasks; permission asks fail closed.
- Transports: `Transport.Stdio` (newline-delimited JSON; frames over 16 MiB or
  nested over 256 deep are refused) and the in-process `Transport.Paired`.
- `use Raxol.AgentClientProtocol.Client, fs_sandbox: root` answers `fs/*`
  inside `root` only (see `Client.FsSandbox` for the exact guarantees).
- Resumable sessions (vendor extension): an append-only journal with
  gap-free, duplicate-free reattach, and offline-verifiable `RXC1` capability
  tokens.

## Layout

```
Raxol.AgentClientProtocol
├── Schema.*              ACP data model; decode never raises or creates atoms
├── Rpc.*                 JSON-RPC 2.0 envelope; ids keep their wire type
├── Transport.*           Stdio, Paired, Framer
├── Connection            one GenServer per peer link, either role
├── Session               agent-side turn state machine
├── Agent / Client        `use`-able behaviours generated from MethodTable
├── MethodTable / Router  the wire vocabulary and generated dispatch
└── Ext.*                 resumable sessions (journal, reattach, attach policy)
```

`Connection.Ctx` is the struct each handler callback receives;
`Raxol.AgentClientProtocol.Ctx` is a set of helpers for code running inside a
prompt turn.

## Quickstart

An echo agent and a client that runs it as a subprocess. Save both files in
one directory and run `elixir my_client.exs`.

```elixir
# my_agent.exs. Stdout carries only protocol frames, so Mix.install output
# and logs go to stderr.
leader = Process.group_leader()
Process.group_leader(self(), Process.whereis(:standard_error))
Mix.install([{:raxol_agent_client_protocol, "~> 0.2"}])
Process.group_leader(self(), leader)

{:ok, handler} = :logger.get_handler_config(:default)
:ok = :logger.remove_handler(:default)

:ok =
  :logger.add_handler(
    :default,
    handler.module,
    handler |> Map.drop([:id, :module]) |> Map.put(:config, %{type: :standard_error})
  )

defmodule MyAgent do
  use Raxol.AgentClientProtocol.Agent

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Schema.{ContentChunk, TextContent}
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification
  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeResponse, NewSessionResponse, PromptResponse}

  @impl true
  def initialize(req, _ctx), do: {:ok, InitializeResponse.new(req.protocol_version)}

  @impl true
  def new_session(_params, _ctx), do: {:ok, NewSessionResponse.new("sess-1")}

  @impl true
  def prompt(%{session_id: session_id, prompt: blocks}, ctx) do
    text = Enum.map_join(blocks, "", fn {:text, tc} -> tc.text; _ -> "" end)
    chunk = ContentChunk.new({:text, TextContent.new("echo: #{text}")})
    Connection.notify(ctx.conn, "session/update", SessionNotification.new(session_id, {:agent_message_chunk, chunk}))
    {:ok, PromptResponse.new(:end_turn)}
  end
end

alias Raxol.AgentClientProtocol.Transport.Stdio

{:ok, handle} = Stdio.start_self()

# The supervisor exits when the client closes the pipe; wait for it so the VM
# halts with its client.
Process.flag(:trap_exit, true)
{:ok, sup} = Raxol.AgentClientProtocol.Agent.start_link(MyAgent, transport: {Stdio, handle})

receive do
  {:EXIT, ^sup, _reason} -> :ok
end
```

```elixir
# my_client.exs
Mix.install([{:raxol_agent_client_protocol, "~> 0.2"}])

defmodule MyClient do
  use Raxol.AgentClientProtocol.Client
end

alias Raxol.AgentClientProtocol.{Client, Connection}
alias Raxol.AgentClientProtocol.Schema.AgentTypes.{InitializeRequest, NewSessionRequest, PromptRequest}
alias Raxol.AgentClientProtocol.Schema.ContentBlock
alias Raxol.AgentClientProtocol.Transport.Stdio

{:ok, handle} = Stdio.start_spawn("elixir", ["my_agent.exs"])
{:ok, sup} = Client.start_link(MyClient, transport: {Stdio, handle})
{:ok, conn} = Client.connection(sup)

# The agent installs the package before answering, hence the long timeout.
{:ok, _init} = Connection.request(conn, "initialize", InitializeRequest.new(1), 30_000)
{:ok, session} = Connection.request(conn, "session/new", NewSessionRequest.new(File.cwd!()), 5_000)

prompt = PromptRequest.new(session.session_id, [ContentBlock.from_string("hello, agent")])
{:ok, {updates, response}} = Client.prompt(conn, prompt)

for update <- updates, do: IO.inspect(update, label: "agent said")
IO.inspect(response.stop_reason, label: "stop reason")
```

It prints one `agent_message_chunk` with `"echo: hello, agent"` and
`:end_turn`. `Transport.Stdio` documents the other boot forms (releases,
`mix run`); `Transport.Paired.create_pair/0` wires both sides in one VM.

## Resumable sessions

Opt-in primitives under `Ext.*`, carried over `_meta["raxol.io"]` and
`_raxol/*` methods:

- Each session has one `Ext.Journal.Writer` that appends before it publishes.
- A reattach (`_raxol/session.load`, or `session/load` with the rider)
  subscribes first, then reads the high watermark `h`, replays `(from..h]` and
  replies with `h`. Live records with offset `<= h` are dropped, so nothing is
  lost or duplicated.
- Every attach goes through one fail-closed policy funnel:
  `AttachPolicy.LocalNode` for in-BEAM attaches, `AttachPolicy.Token` for
  Ed25519-signed `RXC1` tokens (no `alg` field to downgrade).
- Records carry a taint annotation; nothing is filtered by taint.

The shipped store, `Ext.Journal.Mem`, is in memory: sessions outlive
connections, not the node. The application starts the registries and
supervisors this needs. Your agent starts a `Session` with
`emitter: Session.Emitter.Journal`, defers prompts to `Session.begin_prompt/4`,
and routes `raxol_load_session/2` to `Reattach.attach/1`. The `RefAgent` in
[`test/integration/end_to_end_test.exs`](https://github.com/DROOdotFOO/raxol-agent/blob/main/packages/raxol_agent_client_protocol/test/integration/end_to_end_test.exs)
is a complete example.

## Invariants

- The Connection never blocks on a peer, never runs handler code in its own
  process, never creates atoms from wire input, and sends at most one response
  per inbound id.
- Every attach is decided by one fail-closed funnel, and a reattacher
  subscribes before reading the high watermark.
- A disk-backed journal store must create files `0600` and directories `0700`.

`test/INVARIANTS.md` lists every named invariant and the test that enforces it.

## Testing

```bash
cd packages/raxol_agent_client_protocol
mix test
mix acp.schema.verify   # check the pinned ACP schema oracle
```

The suite includes the acpx v1 conformance corpus (`test/conformance/`),
validation against the official ACP JSON Schema (`priv/schema-oracle/`, not
shipped), and wire torture tests (`test/torture/`).

## Provenance

The schema layer is ported (MIT) from
[`f1729/agent_client_protocol`](https://github.com/f1729/agent-client-protocol-elixir),
(c) 2025 f1729. The OTP runtime and `Ext.*` are original. The ACP JSON Schema
(Apache-2.0, pinned at v1.19.0) is a test oracle only. See [NOTICE.md](NOTICE.md)
and [ADR-0041](https://github.com/DROOdotFOO/raxol-agent/blob/main/docs/adr/0041-agent-client-protocol-package.md).
