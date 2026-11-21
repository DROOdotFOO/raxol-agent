# ADR-0042: Lean on OMP

## Status

Accepted, 2026-10-24. Supersedes ADRs 0022, 0024, 0026, 0027, 0028 and 0035, which are deleted.
Narrows 0021, 0032 (deleted), [0034](0034-foreign-coding-agent-seams.md) and
[0036](0036-agent-telemetry-coverage-and-shape.md). Amends
[ADR-0012](https://github.com/DROOdotFOO/raxol/blob/master/docs/adr/0012-mcp-as-rendering-target.md)
in the runtime repository: derived tool names are session-scoped, and a session's tool set
persists until the session stops.

The coding harness was deleted on 2026-11-13, and the modules nothing called (`Raxol.Agent.Turn`,
`Command`, `Policy`, `Cache`, `LlmPrices`) were deleted after it.

Decision 7's agent tools ship as `Raxol.Agent.McpTools` (`agent_spawn`, `agent_list`,
`agent_ask`, `agent_status`, `agent_stop`, and a journal resource). Not built in this
repository: decision 4's `omp_gateway` backend and catalog cut (the catalog still lists 11
backends), decision 6's OMP RPC client, and decision 7's team and payment tools.

## Context

Raxol had grown a full coding-agent harness: a TUI, a one-shot mode, foreign CLI drivers,
memory, compaction, self-improvement and a dozen model backends. That market is crowded. OMP
(Oh My Pi, `omp`, <https://omp.sh>) already ships the harness and speaks MCP. No coding harness offers what Raxol
already has: apps that agents operate through widget-derived MCP tools, supervised agents with
durable journals and fail-closed spend limits, and every surface (terminal, LiveView, SSH, MCP,
chat).

## Decision

1. Raxol is not a coding harness. OMP is the harness people talk to, and Raxol is what it plugs
   into: Raxol apps are OMP tools, and Raxol agents are crash-isolated workers that OMP starts,
   asks and stops.
2. Apps go into OMP first. Derived tools are named `<session>.<widget>.<action>`. The server sends
   `tools/list_changed`. A tool stays registered until its session stops, and resolves its
   widget's live state when called. OMP treats every MCP tool as a write and auto-approves, so
   the Raxol authorizer is the only gate. Over stdio the peer is the process that spawned the
   server, so `raxol mcp` installs an authorizer that allows every registered tool, sensitive ones
   included. A network deployment must configure a function `:mcp_authorizer`, because derived
   names are dynamic and an exact-name allowlist cannot list them. `raxol mcp` needs no Elixir
   toolchain.
3. Delete the coding harness in one cutover: `Raxol.Agent.Code.*`, the native drivers and
   backends, shell, LSP, compaction, memory, self-improvement, the coding actions, and the
   `agent`, `code`, `p`, `login` and `setup` commands (about 25k lines). Kept: `Session`, `Team`,
   `Comm`, `Supervisor`, `SpendGate`, `Sandbox`, `ToolPolicy`, `ThreadLog`, `Stream`, the
   scheduler, skills, `McpBundle`, `Backend.Mock`, `Auth.*` (used by `raxol_broker`) and
   `raxol_agent_client_protocol`.
4. Model access: `anthropic`, `ollama`, `mock` and an `omp_gateway` backend over
   `omp auth-gateway stdio`. The gateway must be selected explicitly and never claims to handle
   tools internally, which would bypass `SpendGate`.
5. ACP stays, aimed at Raxol agents: `raxol acp --agent <app>[:<id>]`. The journal persists
   across runs, but the agent's state starts fresh. `session/load` is not offered. A sensitive
   action asks the editor on every call. Editors that want a coding agent use `omp acp`.
6. Later, Raxol surfaces front an OMP session through OMP's RPC mode, with approvals routed to the
   surface's authenticated user. A surface without an authenticated user refuses to start an OMP
   session.
7. Raxol agents into OMP: agent and team tools in `raxol mcp`, limited to an allowlist of apps.
   Payment tools go through `Raxol.Payments.Actions.SpendGate` and a durable ledger owned by a
   single process. Recipients must be explicit and approved, caps never come from tool
   arguments, and an amount that needs confirmation is refused, because OMP cannot ask a human
   through MCP.

## Consequences

- Raxol depends on a third-party harness for the coding experience. MCP is the stable seam. CI
  pins a tested OMP version.
- A Raxol agent that holds a wallet never relies on OMP's approval mode as a control.
- Superseded ADRs are removed from `docs/adr`. Their text is in git history.
