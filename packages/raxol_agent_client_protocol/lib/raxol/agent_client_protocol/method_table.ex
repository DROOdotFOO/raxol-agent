defmodule Raxol.AgentClientProtocol.MethodTable do
  @moduledoc """
  Single source of truth for the ACP method vocabulary: every wire method
  string, its direction, its JSON-RPC kind, the callback atom used for both
  the behaviour `@callback` and the `Router` dispatch clause, its
  param/result schema modules, its capability gate, and its layer.

  The method set follows the pinned ACP JSON Schema `schema-v1.19.0`
  (`meta.json`), not the f1729 reference implementation — f1729 has
  `session/fork`/`session/set_model` (not in the pinned oracle) and lacks
  `session/delete`/`session/close`/`logout`/`$/cancel_request` (which the
  oracle has). The table is literal data in this module: the oracle copy at
  `priv/schema-oracle/v1/meta.json` is a dev/test file in the repository, not
  shipped in the package and not read at compile time;
  `test/method_table_test.exs` checks the table against it.

  ## What lives here vs. what doesn't

  This module owns `rows/0`, `rows/1`, `rows_for_side/1`, `capability_for/1`,
  the `:capability` column data, and the compile-time table invariants below
  (incl. invariant 7 guarding the capability paths). The negotiated-caps
  PREDICATE (`Capabilities.negotiated?/2`) and the `Connection`-side
  pre-filter for `layer: :protocol`/`:session_control` rows are consumers of
  this table, not implemented here.

  ## Compile-time invariants (raise `CompileError` on violation)

  1. `{direction, wire}` is unique across all rows.
  2. `kind: :notification` implies `result == nil`; `kind: :request` implies
     `result != nil`.
  3. `callback` is unique per handling side (the set of callbacks visible to
     `rows_for_side(:agent)` has no duplicates, ignoring `nil`; ditto
     `:client`) — the anti-name-drift invariant.
  4. `layer in [:protocol, :session_control]` if and only if
     `callback == nil`.
  5. `ext == nil` rows must not start with `"_"`; `ext == :raxol` rows must
     start with `"_raxol/"`; a `"$/"` wire prefix is only allowed on
     `layer: :protocol` rows.

  A sixth check (every `params`/`result` module referenced must exist and
  export `from_json/1`) runs in `test/method_table_test.exs` rather than at
  compile time, to avoid compile-order knots between this module and the
  `Schema.*` modules it references.
  """

  alias Raxol.AgentClientProtocol.Ext.Schema, as: ExtSchema
  alias Raxol.AgentClientProtocol.Schema.{AgentTypes, ClientTypes, LifecycleExtras, Unstable}

  @typedoc "Which side sends this row's wire method."
  @type direction :: :client_to_agent | :agent_to_client | :both

  @typedoc "JSON-RPC 2.0 shape: does this method get a reply?"
  @type kind :: :request | :notification

  @typedoc """
  `:app` — has an app-level `@callback` and `Router` dispatch clause.
  `:protocol` — protocol-level (`$/cancel_request`); `Connection` pre-filters
  before `Router.decode/4` is ever called.
  `:session_control` — app-shaped wire method, but Connection-routed with NO
  app callback (currently only `session/cancel`).
  """
  @type layer :: :app | :protocol | :session_control

  @typedoc """
  How a row is capability-gated:

    * `nil` — baseline method, always available (no capability gate).
    * `{:agent | :client, path}` — a field path into the *receiver's own*
      negotiated capability struct (`Schema.AgentTypes.AgentCapabilities`
      for `:agent`, `Schema.ClientTypes.ClientCapabilities` for `:client`).
      `Raxol.AgentClientProtocol.Capabilities.negotiated?/2` walks the path;
      a truthy leaf ⇒ negotiated, anything else (missing field, `nil`,
      `false`) ⇒ NOT negotiated (fail closed). The path uses **Elixir struct
      field atoms**, not the JSON wire keys, because the snapshot resolved
      against is the decoded struct — see invariant 7 and the ORACLE-DIVERGENCE
      note below.
    * `:never` — the oracle gates this method by a capability the ported
      Elixir capability structs cannot express, so it is unconditionally NOT
      negotiated (fail closed, `-32601`). No row currently uses it.

  ### ORACLE-DIVERGENCE (schema-oracle v1.19.0 vs. ported f1729 structs)

  The pinned oracle's capability tree is richer than the Elixir structs
  ported from the older f1729 snapshot; three oracle leaves that f1729 lacks
  are ported so their methods gate on a real path:

    * `sessionCapabilities.{delete,close}` — ported as
      `Schema.AgentTypes.SessionDeleteCapabilities`/`SessionCloseCapabilities`
      onto the `SessionCapabilities` struct's `delete`/`close` fields.
      `session/delete`/`session/close` gate on
      `{:agent, [:session_capabilities, :delete | :close]}`.
    * `agentCapabilities.auth.logout` — ported as
      `Schema.AgentTypes.AgentAuthCapabilities`/`LogoutCapabilities` onto the
      `AgentCapabilities` struct's `auth` field. `logout` gates on
      `{:agent, [:auth, :logout]}`.
    * JSON-key vs struct-field: paths name Elixir struct fields
      (`[:session_capabilities, :list]`, `[:file_system, :read_text_file]`,
      …), not oracle JSON keys (`[:sessions, :list]`, `[:fs, :read_text_file]`),
      which resolve against neither the oracle JSON nor the struct;
      invariant 7 guards the first segment against drift.
  """
  @type capability :: nil | :never | {:agent | :client, [atom()]}

  @typedoc "`nil` for the core v1.19.0 surface; `:raxol` for registered `_raxol/*` vendor rows."
  @type ext :: nil | :raxol

  @type row :: %{
          wire: String.t(),
          direction: direction(),
          kind: kind(),
          callback: atom() | nil,
          params: module() | nil,
          result: module() | nil,
          capability: capability(),
          layer: layer(),
          ext: ext()
        }

  # Top-level struct fields of the two negotiated capability roots, as literal
  # atoms (NOT introspected from the struct modules: reaching into `Schema.*`
  # at compile time reintroduces the compile-order knot that keeps the sixth
  # check in tests). Invariant 7 checks every gated path's FIRST segment
  # against these; `test/capabilities_test.exs` asserts these literals still
  # match `Map.keys(struct(...)) -- [:_meta]`, catching drift.
  @agent_cap_fields [
    :load_session,
    :prompt_capabilities,
    :mcp_capabilities,
    :session_capabilities,
    :auth
  ]
  @client_cap_fields [:terminal, :file_system]

  # -- Agent methods (direction: client_to_agent) -- 13 rows, meta.json `agentMethods` --

  @agent_rows [
    %{
      wire: "initialize",
      direction: :client_to_agent,
      kind: :request,
      callback: :initialize,
      params: AgentTypes.InitializeRequest,
      result: AgentTypes.InitializeResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "authenticate",
      direction: :client_to_agent,
      kind: :request,
      callback: :authenticate,
      params: AgentTypes.AuthenticateRequest,
      result: AgentTypes.AuthenticateResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/new",
      direction: :client_to_agent,
      kind: :request,
      callback: :new_session,
      params: AgentTypes.NewSessionRequest,
      result: AgentTypes.NewSessionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/load",
      direction: :client_to_agent,
      kind: :request,
      callback: :load_session,
      params: AgentTypes.LoadSessionRequest,
      result: AgentTypes.LoadSessionResponse,
      capability: {:agent, [:load_session]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/set_mode",
      direction: :client_to_agent,
      kind: :request,
      callback: :set_session_mode,
      params: AgentTypes.SetSessionModeRequest,
      result: AgentTypes.SetSessionModeResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/set_config_option",
      direction: :client_to_agent,
      kind: :request,
      callback: :set_session_config_option,
      params: Unstable.SetSessionConfigOptionRequest,
      result: Unstable.SetSessionConfigOptionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/prompt",
      direction: :client_to_agent,
      kind: :request,
      callback: :prompt,
      params: AgentTypes.PromptRequest,
      result: AgentTypes.PromptResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      # Session-control, Connection-routed, no app callback — same treatment
      # as $/cancel_request, keyed by session id instead of request id. See
      # invariant 4.
      wire: "session/cancel",
      direction: :client_to_agent,
      kind: :notification,
      callback: nil,
      params: AgentTypes.CancelNotification,
      result: nil,
      capability: nil,
      layer: :session_control,
      ext: nil
    },
    %{
      wire: "session/list",
      direction: :client_to_agent,
      kind: :request,
      callback: :list_sessions,
      params: Unstable.ListSessionsRequest,
      result: Unstable.ListSessionsResponse,
      capability: {:agent, [:session_capabilities, :list]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/delete",
      direction: :client_to_agent,
      kind: :request,
      callback: :delete_session,
      params: LifecycleExtras.DeleteSessionRequest,
      result: LifecycleExtras.DeleteSessionResponse,
      # Gates on `session_capabilities.delete`
      # (`Schema.AgentTypes.SessionDeleteCapabilities`), see the `capability`
      # typedoc ORACLE-DIVERGENCE note.
      capability: {:agent, [:session_capabilities, :delete]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/resume",
      direction: :client_to_agent,
      kind: :request,
      callback: :resume_session,
      params: Unstable.ResumeSessionRequest,
      result: Unstable.ResumeSessionResponse,
      capability: {:agent, [:session_capabilities, :resume]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/close",
      direction: :client_to_agent,
      kind: :request,
      callback: :close_session,
      params: LifecycleExtras.CloseSessionRequest,
      result: LifecycleExtras.CloseSessionResponse,
      # Gates on `session_capabilities.close`
      # (`Schema.AgentTypes.SessionCloseCapabilities`), see the `capability`
      # typedoc ORACLE-DIVERGENCE note.
      capability: {:agent, [:session_capabilities, :close]},
      layer: :app,
      ext: nil
    },
    %{
      # params: nil — logout's request body carries nothing besides
      # the universal _meta envelope (schema.json LogoutRequest has no other
      # properties). decode passes nil straight through; the generated
      # callback drops to arity 1 (ctx only). See LifecycleExtras moduledoc
      # for why there is no LogoutRequest struct.
      wire: "logout",
      direction: :client_to_agent,
      kind: :request,
      callback: :logout,
      params: nil,
      result: LifecycleExtras.LogoutResponse,
      # Gates on `auth.logout` (`Schema.AgentTypes.AgentAuthCapabilities`/
      # `LogoutCapabilities`), see the `capability` typedoc ORACLE-DIVERGENCE
      # note.
      capability: {:agent, [:auth, :logout]},
      layer: :app,
      ext: nil
    }
  ]

  # -- Client methods (direction: agent_to_client) -- 9 rows, meta.json `clientMethods` --

  @client_rows [
    %{
      wire: "session/request_permission",
      direction: :agent_to_client,
      kind: :request,
      callback: :request_permission,
      params: ClientTypes.RequestPermissionRequest,
      result: ClientTypes.RequestPermissionResponse,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "session/update",
      direction: :agent_to_client,
      kind: :notification,
      callback: :session_update,
      params: LifecycleExtras.SessionNotification,
      result: nil,
      capability: nil,
      layer: :app,
      ext: nil
    },
    %{
      wire: "fs/write_text_file",
      direction: :agent_to_client,
      kind: :request,
      callback: :write_text_file,
      params: ClientTypes.WriteTextFileRequest,
      result: ClientTypes.WriteTextFileResponse,
      capability: {:client, [:file_system, :write_text_file]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "fs/read_text_file",
      direction: :agent_to_client,
      kind: :request,
      callback: :read_text_file,
      params: ClientTypes.ReadTextFileRequest,
      result: ClientTypes.ReadTextFileResponse,
      capability: {:client, [:file_system, :read_text_file]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/create",
      direction: :agent_to_client,
      kind: :request,
      callback: :create_terminal,
      params: ClientTypes.CreateTerminalRequest,
      result: ClientTypes.CreateTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/output",
      direction: :agent_to_client,
      kind: :request,
      callback: :terminal_output,
      params: ClientTypes.TerminalOutputRequest,
      result: ClientTypes.TerminalOutputResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/release",
      direction: :agent_to_client,
      kind: :request,
      callback: :release_terminal,
      params: ClientTypes.ReleaseTerminalRequest,
      result: ClientTypes.ReleaseTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/wait_for_exit",
      direction: :agent_to_client,
      kind: :request,
      callback: :wait_for_terminal_exit,
      params: ClientTypes.WaitForTerminalExitRequest,
      result: ClientTypes.WaitForTerminalExitResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    },
    %{
      wire: "terminal/kill",
      direction: :agent_to_client,
      kind: :request,
      callback: :kill_terminal,
      params: ClientTypes.KillTerminalRequest,
      result: ClientTypes.KillTerminalResponse,
      capability: {:client, [:terminal]},
      layer: :app,
      ext: nil
    }
  ]

  # -- Protocol methods (direction: both) -- 1 row, meta.json `protocolMethods` --

  @protocol_rows [
    %{
      # Connection pre-filters this wire method before Router.decode/4 is
      # ever called; no Router clause is generated for it.
      wire: "$/cancel_request",
      direction: :both,
      kind: :notification,
      callback: nil,
      params: LifecycleExtras.CancelRequestNotification,
      result: nil,
      capability: nil,
      layer: :protocol,
      ext: nil
    }
  ]

  # -- Reattach extension rows (ext: :raxol, additive: two wire entrances to
  # one attach seam, plus the ONE generic `_raxol/session.record` frame for
  # non-`session_update` kinds, plus live steering). All rows: `layer: :app`,
  # `capability: nil` (support is advertised via
  # `initialize.result._meta["raxol.io"]`; an unimplemented optional callback
  # answers -32601, identical to an unadvertised capability). The other
  # `_raxol/session.*` agent-to-client notifications (caught_up/lagged/closed)
  # are sent as raw notifications by `Ext.Reattach` and are not table rows;
  # neither is the client-to-agent `_raxol/session.detach`.
  #
  #   * `_raxol/session.load` reuses `LoadSessionRequest`/`LoadSessionResponse`
  #     verbatim (identical shape; the attach rider rides `_meta`).
  #   * `_raxol/session.record` carries `Ext.Schema.SessionRecordNotification`.
  @ext_rows [
    %{
      wire: "_raxol/session.load",
      direction: :client_to_agent,
      kind: :request,
      callback: :raxol_load_session,
      params: AgentTypes.LoadSessionRequest,
      result: AgentTypes.LoadSessionResponse,
      capability: nil,
      layer: :app,
      ext: :raxol
    },
    %{
      wire: "_raxol/session.record",
      direction: :agent_to_client,
      kind: :notification,
      callback: :raxol_session_record,
      params: ExtSchema.SessionRecordNotification,
      result: nil,
      capability: nil,
      layer: :app,
      ext: :raxol
    },
    %{
      # Live steering: a client→agent request, addressed by
      # sessionId, that redirects the running turn with new user input WITHOUT
      # killing it. The `Session` resolves the `expected_turn_id` compare-and-swap
      # from its own mailbox (single-writer by construction) and returns the
      # honest CAS outcome synchronously (`SteerResponse` vocabulary). Additive:
      # a stock/older agent answers -32601 (unimplemented callback), identical to
      # an unadvertised capability. Payload: text + expected_turn_id +
      # client_msg_id.
      wire: "_raxol/session.steer",
      direction: :client_to_agent,
      kind: :request,
      callback: :raxol_steer_session,
      params: ExtSchema.SteerRequest,
      result: ExtSchema.SteerResponse,
      capability: nil,
      layer: :app,
      ext: :raxol
    }
  ]

  @rows @agent_rows ++ @client_rows ++ @protocol_rows ++ @ext_rows

  # -- Compile-time invariants -------------------------------------------------

  duplicate_direction_wire =
    @rows
    |> Enum.frequencies_by(&{&1.direction, &1.wire})
    |> Enum.filter(fn {_key, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))

  if duplicate_direction_wire != [] do
    raise CompileError,
      description:
        "MethodTable invariant 1 violated: duplicate {direction, wire} rows: " <>
          inspect(duplicate_direction_wire)
  end

  bad_result_arity =
    Enum.filter(@rows, fn
      %{kind: :notification, result: result} -> result != nil
      %{kind: :request, result: result} -> result == nil
    end)

  if bad_result_arity != [] do
    raise CompileError,
      description:
        "MethodTable invariant 2 violated (notification must have result: nil, " <>
          "request must have result != nil): " <>
          inspect(Enum.map(bad_result_arity, & &1.wire))
  end

  agent_handling_rows = Enum.filter(@rows, &(&1.direction in [:client_to_agent, :both]))
  client_handling_rows = Enum.filter(@rows, &(&1.direction in [:agent_to_client, :both]))

  duplicate_callbacks = fn side_rows ->
    side_rows
    |> Enum.map(& &1.callback)
    |> Enum.reject(&is_nil/1)
    |> Enum.frequencies()
    |> Enum.filter(fn {_cb, count} -> count > 1 end)
    |> Enum.map(&elem(&1, 0))
  end

  dup_agent_callbacks = duplicate_callbacks.(agent_handling_rows)
  dup_client_callbacks = duplicate_callbacks.(client_handling_rows)

  if dup_agent_callbacks != [] or dup_client_callbacks != [] do
    raise CompileError,
      description:
        "MethodTable invariant 3 violated (duplicate callback atom per handling side): " <>
          "agent=#{inspect(dup_agent_callbacks)} client=#{inspect(dup_client_callbacks)}"
  end

  bad_layer_callback =
    Enum.filter(@rows, fn row ->
      case row.layer do
        layer when layer in [:protocol, :session_control] -> row.callback != nil
        :app -> row.callback == nil
      end
    end)

  if bad_layer_callback != [] do
    raise CompileError,
      description:
        "MethodTable invariant 4 violated (layer in [:protocol, :session_control] " <>
          "<=> callback == nil): " <> inspect(Enum.map(bad_layer_callback, & &1.wire))
  end

  bad_core_ext_prefix =
    Enum.filter(@rows, fn row -> row.ext == nil and String.starts_with?(row.wire, "_") end)

  bad_raxol_ext_prefix =
    Enum.filter(@rows, fn row ->
      row.ext == :raxol and not String.starts_with?(row.wire, "_raxol/")
    end)

  bad_protocol_prefix =
    Enum.filter(@rows, fn row ->
      String.starts_with?(row.wire, "$/") and row.layer != :protocol
    end)

  if bad_core_ext_prefix != [] or bad_raxol_ext_prefix != [] or bad_protocol_prefix != [] do
    raise CompileError,
      description:
        "MethodTable invariant 5 violated: " <>
          "core-with-underscore=#{inspect(Enum.map(bad_core_ext_prefix, & &1.wire))} " <>
          "raxol-without-prefix=#{inspect(Enum.map(bad_raxol_ext_prefix, & &1.wire))} " <>
          "dollar-outside-protocol=#{inspect(Enum.map(bad_protocol_prefix, & &1.wire))}"
  end

  # Invariant 7: every gated `{side, path}` capability must
  # RESOLVE against the negotiated caps struct shape. Checked at the enforceable
  # compile-time granularity — the FIRST path segment must be a real top-level
  # field of that side's capability struct (catching the `[:sessions, …]` /
  # `[:fs, …]` / `[:logout]` drift class). Deeper segments are validated at
  # runtime by `Capabilities.negotiated?/2` via fail-closed field access, and
  # end-to-end in `test/capabilities_test.exs`. `nil` (baseline) and `:never`
  # (unrepresentable, see the `capability` typedoc) carry no path and are skipped.
  bad_capability_paths =
    Enum.filter(@rows, fn
      %{capability: {:agent, [first | _]}} -> first not in @agent_cap_fields
      %{capability: {:client, [first | _]}} -> first not in @client_cap_fields
      %{capability: {_side, []}} -> true
      _ -> false
    end)

  if bad_capability_paths != [] do
    raise CompileError,
      description:
        "MethodTable invariant 7 violated (capability path first segment is not a " <>
          "top-level field of the caps struct, or path is empty): " <>
          inspect(Enum.map(bad_capability_paths, &{&1.wire, &1.capability}))
  end

  # -- Public API ---------------------------------------------------------------

  # The absolute path of THIS module's source, captured at compile time.
  @table_source __ENV__.file

  @doc """
  Register a compile-time dependency on this table's SOURCE FILE into the calling
  module.

  Any module that expands `rows/0` data into its own compiled output — the
  `Router` decode/dispatch/result_marker clauses, the `Agent`/`Client` `@callback`
  surface — MUST call this in its module body. A plain `rows/0` call is only an
  EXPORTS dependency (recompile when `rows/0`'s API changes); a row-DATA edit does
  not change that signature, so without this an incremental build leaves the
  generated code stale (a new row present in the table but absent from
  `Router`/`Agent` until a `mix clean`).
  `@external_resource` forces the caller to recompile whenever this file changes.
  """
  defmacro depend_on_source do
    quote do
      @external_resource unquote(@table_source)
    end
  end

  @doc "All table rows, in declaration order (agent methods, then client methods, then protocol methods)."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc "Rows whose `direction` matches exactly."
  @spec rows(direction()) :: [row()]
  def rows(direction) when direction in [:client_to_agent, :agent_to_client, :both] do
    Enum.filter(@rows, &(&1.direction == direction))
  end

  @doc """
  Rows a given handling side must be able to decode/dispatch: `:agent` sees
  everything sent `:client_to_agent` plus `:both`; `:client` sees everything
  sent `:agent_to_client` plus `:both`.
  """
  @spec rows_for_side(:agent | :client) :: [row()]
  def rows_for_side(:agent), do: rows(:client_to_agent) ++ rows(:both)
  def rows_for_side(:client), do: rows(:agent_to_client) ++ rows(:both)

  @doc """
  The capability gate for a wire `method`, normalized for
  `Raxol.AgentClientProtocol.Capabilities.negotiated?/2`:

    * `:none` — baseline method, always available (table `capability: nil`).
    * `:never` — unrepresentable in the ported caps model; fail closed.
    * `{:agent | :client, path}` — a field path into the receiver's own caps.
    * `:unknown_method` — `method` is not in the table (`decode/4` will
      `-32601` it; the caller MUST NOT treat this as a capability denial).
  """
  @spec capability_for(String.t()) ::
          :none | :never | :unknown_method | {:agent | :client, [atom()]}
  def capability_for(method) when is_binary(method) do
    case Enum.find(@rows, &(&1.wire == method)) do
      nil -> :unknown_method
      %{capability: nil} -> :none
      %{capability: :never} -> :never
      %{capability: {_side, _path} = cap} -> cap
    end
  end

  @doc "The literal top-level field atoms of a side's capability struct (drift-guarded by invariant 7 + tests)."
  @spec cap_fields(:agent | :client) :: [atom()]
  def cap_fields(:agent), do: @agent_cap_fields
  def cap_fields(:client), do: @client_cap_fields
end
