defmodule Raxol.AgentClientProtocol.MethodTable do
  @moduledoc """
  The ACP method vocabulary: every wire method with its direction, JSON-RPC
  kind, callback name, param/result schema modules, capability gate and layer.
  `Router`, `Agent` and `Client` generate their code from it.

  The method set follows the pinned ACP schema `v1.19.0`; the test suite checks
  it against `priv/schema-oracle/v1/meta.json` (not shipped, not read at compile
  time) and that every referenced schema module exports `from_json/1`.

  Compile-time invariants (each raises `CompileError`):

    1. `{direction, wire}` is unique.
    2. Notifications have no `result`; requests have one.
    3. Callback names are unique per handling side.
    4. `layer` is `:protocol` or `:session_control` exactly when `callback` is `nil`.
    5. Only `ext: :raxol` rows start with `"_"` (and then with `"_raxol/"`);
       only `:protocol` rows start with `"$/"`.
    6. A capability path's first segment is a field of that side's capability struct.
  """

  alias Raxol.AgentClientProtocol.Ext.Schema, as: ExtSchema
  alias Raxol.AgentClientProtocol.Schema.{AgentTypes, ClientTypes, LifecycleExtras, Unstable}

  @typedoc "Which side sends the method."
  @type direction :: :client_to_agent | :agent_to_client | :both

  @type kind :: :request | :notification

  @typedoc """
  `:app` rows have a handler callback. `:protocol` (`$/cancel_request`) and
  `:session_control` (`session/cancel`) rows are handled by the Connection.
  """
  @type layer :: :app | :protocol | :session_control

  @typedoc """
  `nil` is ungated. `{side, path}` is a struct-field path (Elixir field atoms,
  not wire keys) into the receiver's own negotiated `AgentCapabilities` or
  `ClientCapabilities`; a missing, `nil` or `false` leaf is not negotiated.
  `:never` is never negotiated.
  """
  @type capability :: nil | :never | {:agent | :client, [atom()]}

  @typedoc "`nil` for core ACP; `:raxol` for `_raxol/*` vendor rows."
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

  # Literal (not introspected, to avoid compile-order cycles with Schema.*);
  # test/capabilities_test.exs checks they match the structs.
  @agent_cap_fields [
    :load_session,
    :prompt_capabilities,
    :mcp_capabilities,
    :session_capabilities,
    :auth
  ]
  @client_cap_fields [:terminal, :file_system]

  build = fn direction, entries ->
    for {wire, kind, callback, params, result, extra} <- entries do
      Map.merge(
        %{
          wire: wire,
          direction: direction,
          kind: kind,
          callback: callback,
          params: params,
          result: result,
          capability: nil,
          layer: :app,
          ext: nil
        },
        Map.new(extra)
      )
    end
  end

  session_cap = &[capability: {:agent, [:session_capabilities, &1]}]
  terminal = [capability: {:client, [:terminal]}]

  # meta.json `agentMethods`
  @agent_rows build.(:client_to_agent, [
                {"initialize", :request, :initialize, AgentTypes.InitializeRequest,
                 AgentTypes.InitializeResponse, []},
                {"authenticate", :request, :authenticate, AgentTypes.AuthenticateRequest,
                 AgentTypes.AuthenticateResponse, []},
                {"session/new", :request, :new_session, AgentTypes.NewSessionRequest,
                 AgentTypes.NewSessionResponse, []},
                {"session/load", :request, :load_session, AgentTypes.LoadSessionRequest,
                 AgentTypes.LoadSessionResponse, [capability: {:agent, [:load_session]}]},
                {"session/set_mode", :request, :set_session_mode,
                 AgentTypes.SetSessionModeRequest, AgentTypes.SetSessionModeResponse, []},
                {"session/set_config_option", :request, :set_session_config_option,
                 Unstable.SetSessionConfigOptionRequest, Unstable.SetSessionConfigOptionResponse,
                 []},
                {"session/prompt", :request, :prompt, AgentTypes.PromptRequest,
                 AgentTypes.PromptResponse, []},
                {"session/cancel", :notification, nil, AgentTypes.CancelNotification, nil,
                 [layer: :session_control]},
                {"session/list", :request, :list_sessions, Unstable.ListSessionsRequest,
                 Unstable.ListSessionsResponse, session_cap.(:list)},
                {"session/delete", :request, :delete_session,
                 LifecycleExtras.DeleteSessionRequest, LifecycleExtras.DeleteSessionResponse,
                 session_cap.(:delete)},
                {"session/resume", :request, :resume_session, Unstable.ResumeSessionRequest,
                 Unstable.ResumeSessionResponse, session_cap.(:resume)},
                {"session/close", :request, :close_session, LifecycleExtras.CloseSessionRequest,
                 LifecycleExtras.CloseSessionResponse, session_cap.(:close)},
                # No params besides `_meta`, so the callback takes only `ctx`.
                {"logout", :request, :logout, nil, LifecycleExtras.LogoutResponse,
                 [capability: {:agent, [:auth, :logout]}]}
              ])

  # meta.json `clientMethods`
  @client_rows build.(:agent_to_client, [
                 {"session/request_permission", :request, :request_permission,
                  ClientTypes.RequestPermissionRequest, ClientTypes.RequestPermissionResponse,
                  []},
                 {"session/update", :notification, :session_update,
                  LifecycleExtras.SessionNotification, nil, []},
                 {"fs/write_text_file", :request, :write_text_file,
                  ClientTypes.WriteTextFileRequest, ClientTypes.WriteTextFileResponse,
                  [capability: {:client, [:file_system, :write_text_file]}]},
                 {"fs/read_text_file", :request, :read_text_file, ClientTypes.ReadTextFileRequest,
                  ClientTypes.ReadTextFileResponse,
                  [capability: {:client, [:file_system, :read_text_file]}]},
                 {"terminal/create", :request, :create_terminal,
                  ClientTypes.CreateTerminalRequest, ClientTypes.CreateTerminalResponse,
                  terminal},
                 {"terminal/output", :request, :terminal_output,
                  ClientTypes.TerminalOutputRequest, ClientTypes.TerminalOutputResponse,
                  terminal},
                 {"terminal/release", :request, :release_terminal,
                  ClientTypes.ReleaseTerminalRequest, ClientTypes.ReleaseTerminalResponse,
                  terminal},
                 {"terminal/wait_for_exit", :request, :wait_for_terminal_exit,
                  ClientTypes.WaitForTerminalExitRequest, ClientTypes.WaitForTerminalExitResponse,
                  terminal},
                 {"terminal/kill", :request, :kill_terminal, ClientTypes.KillTerminalRequest,
                  ClientTypes.KillTerminalResponse, terminal}
               ])

  # meta.json `protocolMethods`
  @protocol_rows build.(:both, [
                   {"$/cancel_request", :notification, nil,
                    LifecycleExtras.CancelRequestNotification, nil, [layer: :protocol]}
                 ])

  # Vendor extension rows. Support is advertised in `initialize`'s
  # `_meta["raxol.io"]`; an unimplemented callback answers -32601. The other
  # `_raxol/session.*` notifications are sent raw by `Ext.Reattach`.
  @ext_rows build.(:client_to_agent, [
              {"_raxol/session.load", :request, :raxol_load_session,
               AgentTypes.LoadSessionRequest, AgentTypes.LoadSessionResponse, [ext: :raxol]}
            ]) ++
              build.(:agent_to_client, [
                {"_raxol/session.record", :notification, :raxol_session_record,
                 ExtSchema.SessionRecordNotification, nil, [ext: :raxol]}
              ]) ++
              build.(:client_to_agent, [
                # Redirects the running turn without killing it; see `Session.steer/2`.
                {"_raxol/session.steer", :request, :raxol_steer_session, ExtSchema.SteerRequest,
                 ExtSchema.SteerResponse, [ext: :raxol]}
              ])

  @rows @agent_rows ++ @client_rows ++ @protocol_rows ++ @ext_rows

  # -- Compile-time invariants --------------------------------------------------

  check! = fn bad, message ->
    if bad != [], do: raise(CompileError, description: "MethodTable #{message}: #{inspect(bad)}")
  end

  duplicates = fn values ->
    values |> Enum.frequencies() |> Enum.filter(&(elem(&1, 1) > 1)) |> Enum.map(&elem(&1, 0))
  end

  side_callbacks = fn directions ->
    for %{direction: d, callback: cb} <- @rows, d in directions, cb != nil, do: cb
  end

  check!.(duplicates.(Enum.map(@rows, &{&1.direction, &1.wire})), "duplicate {direction, wire}")

  check!.(
    for(%{kind: k, result: r, wire: w} <- @rows, k == :notification != is_nil(r), do: w),
    "notification/result mismatch"
  )

  check!.(
    duplicates.(side_callbacks.([:client_to_agent, :both])) ++
      duplicates.(side_callbacks.([:agent_to_client, :both])),
    "duplicate callback per side"
  )

  check!.(
    for(%{layer: l, callback: cb, wire: w} <- @rows, l == :app == is_nil(cb), do: w),
    "layer/callback mismatch"
  )

  bad_prefix =
    for %{wire: w, ext: ext, layer: layer} <- @rows,
        (ext == nil and String.starts_with?(w, "_")) or
          (ext == :raxol and not String.starts_with?(w, "_raxol/")) or
          (String.starts_with?(w, "$/") and layer != :protocol),
        do: w

  check!.(bad_prefix, "bad wire prefix")

  cap_fields = %{agent: @agent_cap_fields, client: @client_cap_fields}

  bad_cap_paths =
    for %{capability: {side, path} = cap, wire: w} <- @rows,
        path == [] or hd(path) not in Map.fetch!(cap_fields, side),
        do: {w, cap}

  check!.(bad_cap_paths, "capability path does not start at a capability struct field")

  # -- API ----------------------------------------------------------------------

  @table_source __ENV__.file

  @doc """
  Makes the calling module recompile whenever this table's source changes.
  Required in any module that compiles row data into its own code; a plain
  `rows/0` call would only track the function's signature.
  """
  defmacro depend_on_source do
    quote do
      @external_resource unquote(@table_source)
    end
  end

  @doc "All rows: agent methods, client methods, protocol methods, extensions."
  @spec rows() :: [row()]
  def rows, do: @rows

  @doc "Rows with exactly this `direction`."
  @spec rows(direction()) :: [row()]
  def rows(direction) when direction in [:client_to_agent, :agent_to_client, :both] do
    Enum.filter(@rows, &(&1.direction == direction))
  end

  @doc "Rows a side receives: those sent towards it plus `:both`."
  @spec rows_for_side(:agent | :client) :: [row()]
  def rows_for_side(:agent), do: rows(:client_to_agent) ++ rows(:both)
  def rows_for_side(:client), do: rows(:agent_to_client) ++ rows(:both)

  @doc """
  The capability gate for `method`: `:none`, `:never`, `{side, path}`, or
  `:unknown_method` (not a denial; decode answers `-32601`).
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

  @doc "The top-level field atoms of a side's capability struct."
  @spec cap_fields(:agent | :client) :: [atom()]
  def cap_fields(:agent), do: @agent_cap_fields
  def cap_fields(:client), do: @client_cap_fields
end
