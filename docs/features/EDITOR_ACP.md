# Editor ACP

The [Agent Client Protocol](https://agentclientprotocol.com) is JSON-RPC 2.0 between an editor
(the client, such as Zed) and an agent, usually over the agent's stdio. To write an agent or a
client with the protocol package, see
[`raxol_agent_client_protocol`](../../packages/raxol_agent_client_protocol/README.md) and
[ADR-0041](../adr/0041-agent-client-protocol-package.md). Unrelated to the Agent Commerce Protocol in
[`raxol_earn`](../../packages/raxol_earn/README.md).

## Serving a Raxol agent

```bash
curl -fsSL https://raxol.io/install | bash
raxol doctor                     # confirms "acp surface: available"
raxol acp --agent <app>[:<id>]
```

`<app>` must be one of `config :raxol_agent, :mcp_spawnable_apps`. The default is
`Raxol.Agent.Reference.Counter`. From a source checkout, `bin/raxol-acp` takes the same arguments.

Zed, and other hosts with the same `agent_servers` shape:

```json
{
  "agent_servers": {
    "Raxol": {
      "command": "/usr/local/bin/raxol",
      "args": ["acp", "--agent", "Raxol.Agent.Reference.Counter"]
    }
  }
}
```

Each session (in an editor, each thread) gets its own agent. With `--agent <app>:<id>` the id is
pinned, so a later run continues that agent's journal, and only one session per server process is
allowed.

### Serving your own agent

The packaged binary can start only the modules compiled into it. To serve your own agent, depend on
a source build of `raxol_agent`, list your module:

```elixir
config :raxol_agent, mcp_spawnable_apps: [MyApp.Agent]
```

and call `Raxol.Agent.ClientProtocol.Serve.run(["--agent", "MyApp.Agent"])` from your project, as
`bin/raxol-acp` does. Compile first, so stdout carries only the wire. The agent implements the
[agent turn contract](AGENT_FRAMEWORK.md#agent-turn-contract). Only tool calls passed to
`approver` are shown to the editor and, for `sensitive` actions, asked about.

### Behaviour

- `initialize` always answers. `loadSession` is false, and `authMethods` offers a browser
  sign-in for each provider that has one. Without a listed `--agent`, `session/new` is refused
  and the error lists the apps that are allowed.
- `session/new` requires `cwd` to be an existing absolute directory of at most 4,096 bytes. Its
  real path decides where the journal lives:
  `<sessions dir>/<first 8 hex of sha256(root)>/<id>`.
- A prompt is one agent turn, answered as one `agent_message_chunk`. There is no token streaming.
- Each tool call that passes `approver` is reported as a `tool_call` with bounded `rawInput`.
  When the turn ends it is closed as `completed` or `failed`.
- A `sensitive` action sends one `session/request_permission` (allow once or reject once). A
  rejection, no answer within 600 s, a disconnect or a client without the method denies the call.
- `session/cancel` answers the prompt `cancelled` once the turn's process is down.
- `session/load` is not offered, because a restarted agent has its journal but none of its state.
- The agent lives as long as the connection.
- `RAXOL_MAX_TURNS` and `RAXOL_MAX_COST_USD` cap one connection. A cost cap needs
  `RAXOL_COST_PER_MTOK_IN` and `RAXOL_COST_PER_MTOK_OUT`. Past a cap, a prompt gets a
  `budget_exhausted` error.
- The wire is UTF-8 whatever the locale.
- `mcpServers` in `session/new` is ignored.
- Journals live in `$RAXOL_SESSIONS_DIR` (default `~/.raxol/sessions`). On Windows every
  `session/new` is refused, because the journal has no cross-process lock there.
- Exit codes: 0 when the editor disconnects; 64 for a usage error or an unreadable cap; 1 for a
  build without ACP or an abnormal end.

Agents started by ACP and by the `agent_*` MCP tools share the id namespace and, for one project
root, the journal directory, but neither can see the other's agents.

### Provider sign-in

`authMethods` offers "Sign in with OpenRouter". It mints an OpenRouter key, stores it in a new
1Password item (vault `$RAXOL_OP_VAULT`, default `Private`), and writes the `op://` reference to
the [provider store](AGENT_FRAMEWORK.md#credentials). The key never stays on disk. Without the
`op` CLI the sign-in fails. OpenRouter is billed in API credits, so `auto_provider: true` skips it
unless `RAXOL_ALLOW_PAID_API=1` is set. Remove it with `Raxol.Agent.Setup.remove(:openrouter)` or
by editing `~/.raxol/providers.json`.

### Verifying an integration

`scripts/acp_probe.py` is a dependency-free ACP client that runs the handshake, answers permission
requests and records every frame:

```bash
PROBE_PROMPT=increment scripts/acp_probe.py raxol acp --agent Raxol.Agent.Reference.Counter
```

A `__NON_JSON_STDOUT__` entry means something wrote non-JSON to the wire.

`raxol_agent` 3.1.0 and later always include the ACP surface. `raxol_agent` 3.0.0 from Hex does
not. `raxol doctor` reports which one you have.
