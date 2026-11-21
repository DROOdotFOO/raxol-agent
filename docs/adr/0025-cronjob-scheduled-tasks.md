# ADR-0025: Scheduled agent jobs

## Status

Accepted. Implemented 2026-07-26 (`Raxol.Agent.Scheduler`, `Raxol.Agent.Schedule`, the
`cronjob` action, `Scheduler.Fire` and `Scheduler.Delivery`).

## Context

An agent had no way to run a task on a schedule, such as "every weekday at 9am, summarize my
open PRs and send the summary to a chat".

## Decision

- `Raxol.Agent.Scheduler` is a single-node GenServer. It holds one `Process.send_after/3` timer
  per enabled job. Jobs persist to `Raxol.Core.Stores.Dets` when a path is configured and are
  replayed on boot. No OS cron daemon is involved.
- `Raxol.Agent.Schedule.parse/1` accepts four formats: relative (`30m`), interval (`every 2h`),
  5-field cron, and ISO 8601. A timestamp job runs once; the others recur.
- The `cronjob` action manages jobs (`create`, `list`, `update`, `pause`, `resume`, `run`,
  `remove`) through `context[:scheduler]`. A job has a `prompt`, a `schedule`, `skills`, a
  `target` and `enabled`.
- A fire never runs inside the scheduler process. The scheduler records the fire to its optional
  thread log, re-arms the timer and hands the work to `:dispatch`. `Scheduler.Fire` runs the job
  as a fresh agent turn through `Raxol.Agent.Stream`, with no history, and injects the job's
  skills as a system prompt. `:deliver` then sends the output to the job's target.
- Recursion guard: a fire runs with `in_cron: true`, and `cronjob` then refuses `create`, `run`,
  `update` and `resume` with `{:error, :cron_in_cron}`.
- The scheduler treats `target` as an opaque string. `Delivery.local/1` posts to an in-process
  callback. A surface that routes targets to chat passes its own `:deliver`.

## Consequences

- Jobs are durable state that an agent can create. They are capped per owner (`:max_per_owner`,
  default 50).
- Missed fires are not back-filled. After downtime, a recurring job is re-armed from the current
  time, and a one-shot job whose time has passed fires once.
- Only a single node is supported, and fires are best-effort with no exactly-once guarantee.
