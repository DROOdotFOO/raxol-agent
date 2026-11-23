defmodule Raxol.Earn.Telemetry do
  @moduledoc """
  The registry of every `:telemetry` event `raxol_earn` emits, each classified
  as exactly one of `:invariant`, `:peer` or `:operational`.

  `:invariant` events are armed by `Raxol.Core.Telemetry.InvariantSentinel`,
  which fails any test in which one fires undeclared. `:peer` (a remote party
  misbehaved) and `:operational` (normal life) are recorded, not enforced. If a
  peer, the network, the chain, the filesystem, the clock or a user can cause
  it, it is NOT an invariant: a false invariant makes the suite flaky.

  ## No invariants yet

  Every entry is `:operational`. `raxol_earn` emits broad channels (one event
  name per state machine, runtime or solver, with the occurrence in metadata),
  and the sentinel keys on event names, so a channel carrying the happy path
  cannot be enforced. For `[:raxol, :earn, :job_session, :transition]`:
  `JobSession.commit_status/4` emits only after validation passes, an illegal
  transition emits nothing, and `apply_event/3` (observed on-chain status,
  unvalidated) reports with `action: :apply_event`. An invariant would need a
  distinct event from the rejection branch.

  ## Dynamic families

  The buyer/seller `queue` and `resync` modules build the last segment at run
  time, so they are declared as `dynamic:` families with their suffix ranges. A
  dynamic family cannot be `:invariant` (the sentinel cannot subscribe to it);
  these four are `:operational` as umbrellas.

  ## Completeness

  `test/raxol/earn/telemetry_registry_test.exs` scans `lib/` and fails on any
  emitted event missing here.
  """

  # Each entry carries WHY it lands where it does, read off the emit site
  # rather than guessed from the event name.
  use Raxol.Core.Telemetry.Invariants,
    events: %{
      # OPERATIONAL. The single channel for every COMMITTED status change of an
      # ACP job session (`Raxol.Earn.JobSession.commit_status/4`). Legal
      # role-gated transitions and authoritative observed events
      # (`action: :apply_event`) share the name; rejected transitions emit
      # nothing. Enforcing it would fail on the happy path. See the moduledoc
      # for why the invariant this event's name suggests is not expressible.
      [:raxol, :earn, :job_session, :transition] => :operational,

      # OPERATIONAL x2. `Buyer.Runtime`/`Seller.Runtime` are deliberately thin
      # bridges: they emit once per `{:acp_event, event}` message received from
      # the configured backend and forward it to the Queue uninterpreted. The
      # event is a receipt for EVERY inbound message, so it fires constantly on
      # the normal path. The message content originates with a remote ACP event
      # source, which the criterion puts outside our control anyway.
      [:raxol, :earn, :buyer, :runtime, :event_received] => :operational,
      [:raxol, :earn, :seller, :runtime, :event_received] => :operational,

      # OPERATIONAL. `Xochi.SolverAgent.emit/4` funnels its whole lifecycle
      # through one name with the occurrence in `metadata.event`: normal steps
      # (`:job_created`, `:job_funded`, `:settling`, `:submitted`,
      # `:job_completed`, `:reattached`, `:budget_proposed`) alongside
      # RPC/chain/peer failures (`:settle_error`, `:submit_error`,
      # `:budget_error`, `:requirement_error`, `:reattach_failed`). A channel
      # that carries `:job_created` cannot be enforced.
      [:raxol, :earn, :xochi, :solver, :event] => :operational,

      # OPERATIONAL. `Xochi.Heartbeat` emits on a fixed interval regardless of
      # job flow, because the solver is an outbound SSE client with no inbound
      # port and a wedged stream looks identical to an idle one. Its firing is
      # the healthy signal; its ABSENCE is the alarm, and absence is what
      # external monitoring watches. Emitted via the `@telemetry_event`
      # attribute, which is why the registry test also does a text-level scan.
      [:raxol, :earn, :xochi, :solver, :heartbeat] => :operational,

      # PEER. `Transport.SSE` emits it when the ACP server sent an event larger
      # than `:max_sse_buffer_bytes`, which was dropped unrecovered. Only the
      # remote party can cause it.
      [:raxol, :earn, :transport, :sse_dropped] => :peer
    },
    # Umbrella :operational (the `dynamic:` default). Suffixes recorded so a
    # future reader knows exactly what each family hides.
    dynamic: [
      # Buyer dispatch authority. Suffixes: `:purchased` (a job we originated),
      # `:dispatched` (a lifecycle event routed to its client), `:dropped`
      # (unknown type, untracked job_id, or a spend policy rejection). Drops are
      # peer- or policy-caused; purchases and dispatches are the happy path.
      [:raxol, :earn, :buyer, :queue],

      # Buyer drain-before-act on boot. Suffixes: `:rehydrated` (a job re-tracked
      # from the authoritative job list), `:skipped` (a job we could not adopt),
      # `:drain_failed` (the job API was unreachable -- peer). Best-effort by
      # design: a failed drain does not block buying.
      [:raxol, :earn, :buyer, :resync],

      # Seller dispatch authority. Suffixes: `:dispatched`, `:dropped` (unknown
      # type/job_id), `:oob_post_failed` (an out-of-band delivery POST to the
      # remote endpoint failed -- peer, and deliberately not a dispatch failure).
      [:raxol, :earn, :seller, :queue],

      # Seller drain-before-act on boot and after a backend restart. Suffixes:
      # `:completed` (drain summary), `:skipped` (unknown or numeric phase, or a
      # session that would not start), `:failed` (the job API was unreachable).
      # Unknown phases are skipped rather than guessed, so `:skipped` is a
      # report about remote data, not about us.
      [:raxol, :earn, :seller, :resync]
    ]
end
