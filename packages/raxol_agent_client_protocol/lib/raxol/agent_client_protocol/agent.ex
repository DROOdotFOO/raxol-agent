defmodule Raxol.AgentClientProtocol.Agent do
  @moduledoc """
  `use Raxol.AgentClientProtocol.Agent` to implement the agent side of ACP:
  answering `initialize`, creating and loading sessions, serving prompt turns.

  A thin layer over `Connection` and `Session`: it generates the callback
  surface and wires the supervision tree, nothing more.

  ## Callbacks

  One callback per agent-side `MethodTable` row with an app-level handler
  (everything but `session/cancel`), named and typed from the table; see
  `callbacks/0`. Rows without params (`logout`) take `(ctx)`, the rest take
  `(params, ctx)`. `ctx` is a read-only `Connection.Ctx`.

  A request callback returns `{:ok, result}`, `{:error, %Error{}}`, or
  `:deferred` after `Connection.delegate_reply/3` (otherwise the Connection
  answers `-32603`). Notification return values are ignored.

  Every callback has an overridable default: requests answer `-32601`
  (method not found), notifications return `:ok`, and `c:init/1` returns
  `{:ok, handler_arg}`. Implement only what you support. `"_"`-prefixed methods
  without a table row go to `c:handle_ext_request/3` and
  `c:handle_ext_notification/3`.

  ## Example

      defmodule MyAgent do
        use Raxol.AgentClientProtocol.Agent
        alias Raxol.AgentClientProtocol.Schema.AgentTypes.InitializeResponse

        @impl true
        def initialize(_req, _ctx), do: {:ok, InitializeResponse.new(1)}
      end

      {:ok, sup} = Raxol.AgentClientProtocol.Agent.start_link(MyAgent, transport: {mod, handle})

  `start_link/2` and `child_spec/1` start one `ConnectionSupervisor` subtree
  (task supervisor, session supervisor, `:temporary` Connection) that shuts down
  as a whole when the Connection exits.
  """

  require Raxol.AgentClientProtocol.Handler.Codegen
  require Raxol.AgentClientProtocol.MethodTable

  alias Raxol.AgentClientProtocol.Connection
  alias Raxol.AgentClientProtocol.Handler.{Codegen, Wiring}
  alias Raxol.AgentClientProtocol.MethodTable

  # Recompile when the method table changes.
  MethodTable.depend_on_source()

  @typedoc "Per-dispatch context."
  @type ctx :: Connection.Ctx.t()

  Codegen.defcallbacks(:agent)

  @doc "The generated callbacks as `{callback, arity, wire_method}`, in table order."
  @spec callbacks() :: [{atom(), arity(), String.t()}]
  def callbacks, do: Codegen.callbacks(:agent)

  defmacro __using__(_opts), do: Codegen.using(__MODULE__, :agent)

  defmodule ConnectionSupervisor do
    @moduledoc false
    use Supervisor

    @spec start_link(Raxol.AgentClientProtocol.Handler.Wiring.init_arg(), keyword()) ::
            Supervisor.on_start()
    def start_link(init_arg, opts \\ []), do: Supervisor.start_link(__MODULE__, init_arg, opts)

    @impl Supervisor
    def init(init_arg), do: Raxol.AgentClientProtocol.Handler.Wiring.init(:agent, init_arg)
  end

  @doc """
  Child spec for embedding one agent connection subtree. Requires `:handler` and
  `:transport` (`{module, handle}`); accepts `:handler_arg`, `:name` and `:id`
  (default `#{inspect(__MODULE__)}`; set it when embedding several).
  """
  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) when is_list(opts),
    do: Wiring.child_spec(ConnectionSupervisor, __MODULE__, opts)

  @doc "Starts a standalone subtree. Options as `child_spec/1`, minus `:handler` and `:id`."
  @spec start_link(module(), keyword()) :: Supervisor.on_start()
  def start_link(handler, opts \\ []) when is_atom(handler),
    do: Wiring.start_link(ConnectionSupervisor, handler, opts)

  @doc """
  Returns the `Connection` pid of a started subtree. `sup` must be the
  `ConnectionSupervisor` pid (what `start_link/2`, `start_supervised!/1` and
  `DynamicSupervisor.start_child/2` return), not an outer supervisor.
  """
  @spec connection(pid()) :: {:ok, pid()} | {:error, :not_found}
  def connection(sup) when is_pid(sup), do: Wiring.connection(sup)
end
