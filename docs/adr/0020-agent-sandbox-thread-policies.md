# ADR-0020: Agent sandbox and thread log

## Status

Accepted, 2026-07-22. Narrowed 2026-11-13 by [ADR-0042](0042-lean-on-omp.md): the
`Policy` structs, `PolicyApplier`, `Raxol.Agent.Cache`, `ThreadLogRouter`, the `thread_log/0`
callback and `PermissionHook` are removed.

## Context

`PermissionHook` collapsed independent permissions (shell, inter-agent messaging, async work)
into one linear mode ladder, so an agent could not allow one without the others. Nothing kept a
durable, append-only record of what an agent did.

## Decision

- `Raxol.Agent.Sandbox` is a protocol. Each struct gates one dimension and returns `:ok`,
  `{:deny, reason}`, or `:ok` as an abstention for actions outside its dimension. A list is
  walked in order and the first `:deny` wins.
- Three dimensions ship: `Sandbox.Shell` (`Directive.Shell`), `Sandbox.SendAgent`
  (`Directive.SendAgent`) and `Sandbox.Async` (`Directive.Async`). There is no filesystem,
  network or resource dimension.
- An agent declares `sandbox/0`. When it is non-empty, `Raxol.Agent.SandboxHook` is appended to
  the agent's `command_hooks/0` chain, so sandboxes run through the existing hook seam.
- `Raxol.Agent.ThreadLog` is a behaviour for append-only `Raxol.Agent.ThreadEvent` storage,
  keyed by `{thread_id, sequence}`. The adapter assigns sequences. Adapters: `ThreadLog.Ets`
  (default) and `ThreadLog.Postgrex` (optional dep). One writer per `thread_id` is assumed.
  `Raxol.Agent.Scheduler` writes to it.

## Consequences

- Permissions are orthogonal: tightening shell access does not affect messaging or async work.
- Sandboxing is opt-in per agent. An agent with no `sandbox/0` behaves as before.
- ThreadLog adapters do not truncate on their own; retention is the operator's job.
- `Policy.Grants.shell_allow/2` binds on the dispatcher context, which carries no `:jail`, so
  `SandboxHook` is the only gate in front of `Directive.Shell` in this repo.
