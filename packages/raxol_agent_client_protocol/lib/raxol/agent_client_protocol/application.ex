defmodule RaxolAgentClientProtocol.Application do
  @moduledoc """
  The package OTP application — the single shared supervision tree that the
  per-connection subtrees and the reattach extension depend on.

  ## What it starts

  The `Connection`/`Session` per-connection subtree is started PER CONNECTION
  (library mode via `Agent.child_spec/1` / `Client.child_spec/1`, or standalone
  via `ConnectionsSupervisor`). But three things are **package-level shared** —
  a durable session outlives every connection (process identity ≠ session
  identity), and the attach funnel is one per node:

    1. `Raxol.AgentClientProtocol.SessionRegistry` — the ONE package-level unique
       `Registry` keyed `{conn_pid, session_id}`. The `Connection` reads it for
       `session/cancel` direct dispatch, so its name is contract.
    2. `Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry` +
       `Raxol.AgentClientProtocol.Ext.Journal.WriterSupervisor` — the journal
       single-publisher Writers, started lazily on first append/subscribe.
       `Ext.Journal.ensure_writer/3` starts them here.
    3. `Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor` — the
       `Task.Supervisor` the fail-closed admission funnel isolates policy tasks
       under. **Without it, a REAL attach denies `:policy_infra` on every
       request** — the fail-closed leg, correct but useless for a legitimate
       attach.

  It also starts `Raxol.AgentClientProtocol.ConnectionsSupervisor`, the
  standalone-mode `DynamicSupervisor` an embedder `DynamicSupervisor.start_child/2`s
  a `ConnectionSupervisor` under (`Agent.child_spec/1` / `Client.child_spec/1`'s
  start MFA, wrapped in a plain child spec) when they want this module's shared
  tree to also host the connection subtree itself, rather than splicing
  `Agent.child_spec/1`/`Client.child_spec/1` into their own supervisor.
  There is no `mix acp.serve` task and no `connect/3` function: standalone mode
  is this `DynamicSupervisor` plus the embedder's own `start_child/2` call.

  ## When it starts

  The application module is declared in `mix.exs` (`mod:`), so in a project
  that depends on this package it starts before the project's own
  application, with all five children: two `Registry`s, two
  `DynamicSupervisor`s and one `Task.Supervisor`. None of them opens a file,
  a port or a listener. Use them as they are: do not also start
  `children/0` in your own supervisor while this application runs, or your
  supervisor fails with `{:already_started, _}`.

  Only this package's own `MIX_ENV=test` build starts an **empty tree**, so
  its suite (which starts each named supervisor manually, per test, with the
  SAME names) is never disturbed by a colliding auto-started one. The env is
  captured at COMPILE time (`@auto_start`), and a dependency is compiled
  with `MIX_ENV=prod` unless its `:env` option says otherwise, so a
  consumer's tests get the full tree too. No `Mix` call happens at runtime
  or in a release.

  ## Library mode (an embedder that keeps it from starting)

  An embedder that wants these processes under its own supervisor lists the
  package in `included_applications` in its `mix.exs` `application/0`: the
  application is then loaded (and included in a release) but not started,
  and the embedder splices `children/0` into its own tree. The child specs
  are the exact list this module starts, so the names the modules resolve
  against (`Runner`'s default `Task.Supervisor`, `Writer.registry/0`,
  `Session.registry/0`) are satisfied with no further wiring. A project
  that depends on `raxol_agent` cannot do this: `raxol_agent` lists this
  package among the applications it starts.
  """

  use Application

  @session_registry Raxol.AgentClientProtocol.SessionRegistry
  @writer_registry Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry
  @writer_supervisor Raxol.AgentClientProtocol.Ext.Journal.WriterSupervisor
  @attach_task_supervisor Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor
  @connections_supervisor Raxol.AgentClientProtocol.ConnectionsSupervisor

  # Captured at compile time: the package's own test suite starts every named
  # supervisor manually, so the auto-started tree MUST be empty under :test to
  # avoid `{:already_started, _}` name collisions. A boolean literal is baked in
  # here, so nothing calls `Mix` at runtime.
  @auto_start Mix.env() != :test

  @impl Application
  def start(_type, _args) do
    children = if @auto_start, do: children(), else: []

    Supervisor.start_link(children,
      strategy: :one_for_one,
      name: RaxolAgentClientProtocol.Supervisor
    )
  end

  @doc """
  The package-level shared child specs, for an embedder that keeps this
  application from starting (see "Library mode" above). Never start them
  while the application runs.

  All ids are the module names each spec registers under, which is exactly what
  the consuming modules resolve against by default — so nothing else needs to
  be named or configured.
  """
  @spec children() :: [Supervisor.child_spec() | {module(), term()}]
  def children do
    [
      # (1) the ONE package-level Session registry.
      {Registry, keys: :unique, name: @session_registry},
      # (2) the journal single-publisher Writers.
      {Registry, keys: :unique, name: @writer_registry},
      {DynamicSupervisor, name: @writer_supervisor, strategy: :one_for_one},
      # (3) the attach-policy fail-closed funnel's Task.Supervisor
      #     (without it every attach denies :policy_infra).
      {Task.Supervisor, name: @attach_task_supervisor},
      # standalone-mode connection host.
      {DynamicSupervisor, name: @connections_supervisor, strategy: :one_for_one}
    ]
  end

  @doc "The standalone-mode `DynamicSupervisor` name."
  @spec connections_supervisor() :: atom()
  def connections_supervisor, do: @connections_supervisor

  @doc "The journal Writer `DynamicSupervisor` name — where `Ext.Journal.ensure_writer/3` starts Writers."
  @spec writer_supervisor() :: atom()
  def writer_supervisor, do: @writer_supervisor
end
