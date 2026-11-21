# ADR-0034: Foreign coding-agent seams

## Status

Accepted, 2026-09-05. Narrowed 2026-11-13 by [ADR-0042](0042-lean-on-omp.md): the native CLI
backends and their drivers (`NativeHarness`, `Harness.*`, `AcpStreamAdapter`) are removed.

## Context

A foreign coding agent such as Oh My Pi (`omp`) can be driven three ways: as an ACP server, as a
native CLI backend that parses its JSON output, or as a Symphony runner (the
tracker-driven orchestrator, now in its own repository). The native seam discarded
reasoning and tool calls and bypassed authorization. Five registries also disagreed about which
backends existed.

## Decision

- ACP is the seam for a foreign coding agent. It is the only one where the agent runs inside
  raxol's governance: streamed tool calls, `session/request_permission`, and `usage_update`.
- `Raxol.Agent.Backend.Catalog` is the single declaration of backends. `Backend.Selector`'s
  module table, `Backend.Resolver`'s provider list and `ExecutorConfig`'s `backend()` type are
  derived from it, never merged into it. A user-writable agent registry, if one is added, stays
  separate and must be bounded, because each entry mints an atom and spawns a process.
- A backend that runs its own tool loop declares `AIBackend.handles_tools_internally?/0`, and
  `Raxol.Agent.Stream` then skips its ReAct loop.
- Operator constraint: an `omp` behind raxol's permission gate must be launched with no
  `--approval-mode` and no `--auto-approve`. Under `always-ask` or `write`, omp asks for
  permission, receives `allow_once` and still fails the call. `--auto-approve` never asks.

## Consequences

- omp asks permission for `bash` but never for `write`. Filesystem writes from an ACP-hosted
  agent are ungated, so this seam is for a trusted local workspace only.
- The three backend tables cannot drift, because they are compiled from one list.
