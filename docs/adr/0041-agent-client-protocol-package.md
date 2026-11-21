# ADR-0041: `raxol_agent_client_protocol`: origin, layering and license

## Status

Accepted. Published to Hex from 0.1.0. Module root: `Raxol.AgentClientProtocol`.

## Context

ACP (<https://agentclientprotocol.com>) is JSON-RPC 2.0 between editors and coding agents. Raxol
needs both roles in Elixir. The prior art is split by license: `f1729/agent_client_protocol`
(MIT, schema layer only) and the `openclaw/acpx` fixtures (MIT) on one side; the official SDKs,
`lostbean/acpex` and the official JSON Schema (all Apache-2.0) on the other. The package must ship
as pure MIT.

## Decision

1. `Schema.*` is ported from `f1729/agent_client_protocol` (MIT). Ported modules carry an
   attribution line and `NOTICE.md` records it. Defects found during the port were fixed.
2. The runtime is clean-room: `Connection`, `Session`, `Transport.*`, the supervision tree and
   `Ext.*`. The Apache-2.0 projects were read for design only, and no lines were copied.
3. Three layers, each testable alone:
   - `Schema.*`: pure data. Decoding is total and never mints atoms from wire input.
   - `Rpc.*` and `Transport.*`: JSON-RPC framing and carriers (`Stdio`, `Paired`). This layer
     knows nothing of ACP methods.
   - `Connection`, `Session`, `Agent`/`Client`, `MethodTable`/`Router`: the ACP runtime.
     `MethodTable` is the single source from which the dispatch clauses, callbacks and
     capability gating are generated.
4. The Apache-2.0 JSON Schema is vendored only as a SHA256-pinned dev/test oracle in
   `priv/schema-oracle/` (`mix acp.schema.verify`). It is excluded from the Hex package.
5. The module root is spelled out (`AgentClientProtocol`) so it never collides with the Agent
   Commerce Protocol in `raxol_earn`. Renaming it later would break every consumer, so this
   choice cannot be undone.
6. Vendor extensions (durable resumable sessions, `RXC1` capability tokens, taint annotation)
   ride `_meta["raxol.io"]` on standard methods and use the `_raxol/*` method prefix for new
   methods. `MethodTable` enforces the boundary between standard and vendor names at compile
   time. A peer that does not know the extension can ignore it.
7. Runtime rules: never block on a peer, never run handler code in the `Connection` process,
   never mint atoms from wire input, and keep the response-count invariant under cancel races.
   Every attach passes through one fail-closed authorization funnel.

## Consequences

- Consumers get a single MIT license with no Apache NOTICE obligation.
- A future disk-backed `Ext.Journal` store must create its files `0600` and directories `0700`
  from the first write. Today's `Ext.Journal.Mem` is in memory only.
