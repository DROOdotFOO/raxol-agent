# ADR-0021: Agent skill runtime

## Status

Accepted, 2026-07-22. Narrowed 2026-11-13 by [ADR-0042](0042-lean-on-omp.md): the after-turn
self-improvement task (`Raxol.Agent.SelfImprove`), the `Raxol.Agent.Curator` and the turn
recorder that fed them are removed. The skill runtime remains.

## Context

Agents had episodic memory but no procedural memory: no named, reusable "how to do X" that an
agent can read when it needs it and write for itself. The user's skill library already follows the
agentskills.io `SKILL.md` format, so the missing piece was a runtime, not a format.

## Decision

- A skill is a directory on disk holding a `SKILL.md` (YAML frontmatter plus a markdown body)
  and optional supporting files. It is not a module or a database row.
- `Raxol.Agent.Skill` parses and renders `SKILL.md` as pure functions.
- `Raxol.Agent.Skills.Store` is a GenServer that indexes skills on disk. It scans a writable
  managed root (default `~/.raxol/skills`) and read-only `external_dirs` (default
  `~/.agents/skills`). Disk is the source of truth. Per-skill usage counts persist to DETS.
- Three actions read and write skills: `skills_list` (metadata only), `skill_view` (one file)
  and `skill_manage` (create, patch, edit or delete; managed skills only).
- An agent opts in through `skills_provider/0`, which defaults to `nil`. When it is set,
  `available_actions/0` includes the skill actions. `Raxol.Agent.Supervisor` starts the store
  only when `:raxol_agent, :skills_provider` is configured.

## Consequences

- An agent can save a working procedure and read it in a later session.
- The user's existing `~/.agents/skills` library is readable without conversion.
- Skills are not aged or consolidated automatically, so the library grows until someone prunes it.
