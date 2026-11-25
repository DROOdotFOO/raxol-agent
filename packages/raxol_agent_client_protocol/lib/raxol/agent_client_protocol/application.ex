defmodule RaxolAgentClientProtocol.Application do
  @moduledoc """
  The package OTP application: the shared supervision tree the per-connection
  subtrees and the reattach extension depend on.

  ## What it starts

  Connections and Sessions are started per connection (`Agent.child_spec/1`,
  `Client.child_spec/1`). Shared per node:

    1. `Raxol.AgentClientProtocol.SessionRegistry` -- the unique `Registry` keyed
       `{conn_pid, session_id}`; `Connection` reads it for `session/cancel`, so
       the name is contract.
    2. `Raxol.AgentClientProtocol.Ext.Journal.WriterRegistry` and
       `...WriterSupervisor` -- the journal Writers, started lazily by
       `Ext.Journal.ensure_writer/3`.
    3. `Raxol.AgentClientProtocol.Ext.AttachPolicy.TaskSupervisor` -- without it
       every real attach denies `:policy_infra`.
    4. `Raxol.AgentClientProtocol.ConnectionsSupervisor` -- a `DynamicSupervisor`
       an embedder can `start_child/2` a `ConnectionSupervisor` under (standalone
       mode; there is no `mix acp.serve` or `connect/3`).
    5. The `Client.subscribe/3` table owner.

  None opens a file, port or listener.

  ## When it starts

  Declared as `mod:` in `mix.exs`, so it starts before a dependent project's
  application. Do not also start `children/0` yourself while it runs, or your
  supervisor fails `{:already_started, _}`. Only this package's own
  `MIX_ENV=test` build (captured at compile time as `@auto_start`) starts an
  empty tree; a consumer's tests get the full tree.

  ## Library mode

  To own these processes, list the package in `included_applications` and splice
  `children/0` into your tree; the names modules resolve against are satisfied
  with no further wiring. Not possible under `raxol_agent`, which starts this
  application itself.
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
      # owner of the Client.subscribe/3 table; first, so it stops last.
      Raxol.AgentClientProtocol.Client.Subscriptions,
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
