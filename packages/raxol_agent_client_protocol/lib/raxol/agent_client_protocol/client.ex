defmodule Raxol.AgentClientProtocol.Client do
  @moduledoc """
  `use Raxol.AgentClientProtocol.Client` to implement the client (editor) side
  of ACP: answering permission, filesystem and terminal requests and receiving
  `session/update` notifications. Mirrors `Raxol.AgentClientProtocol.Agent`:
  the same table-generated callbacks (see `callbacks/0`), defaults, extension
  routing and supervision subtree, with `role: :client`.

  ## Example

      defmodule MyClient do
        use Raxol.AgentClientProtocol.Client
        alias Raxol.AgentClientProtocol.Client.FsSandbox

        @impl true
        def init(root), do: {:ok, %{root: root}}

        @impl true
        def read_text_file(req, ctx), do: FsSandbox.read(ctx.handler_state.root, req)
      end

      {:ok, sup} = Client.start_link(MyClient, transport: {mod, handle}, handler_arg: "/project")
      {:ok, conn} = Client.connection(sup)

  ## Prompting

  `prompt/3` and `prompt_stream/4` send `session/prompt` and consume the
  Connection's direct turn delivery: the Connection itself sends this process
  every update of the turn, a turn-end count and the result, so mailbox order is
  wire order. A count mismatch fails the turn with `{:error, {:delivery_gap, _}}`.

  The default `c:session_update/2` also broadcasts each update as
  `{:acp_session_update, session_id, update}` to processes registered with
  `subscribe/3`. That path runs one handler task per notification and has no
  ordering guarantee relative to the prompt result.

  ## Filesystem sandbox

  `use Raxol.AgentClientProtocol.Client, fs_sandbox: "/root"` implements
  `c:read_text_file/2` and `c:write_text_file/2` (still overridable) confined to
  that directory via `Raxol.AgentClientProtocol.Client.FsSandbox`; reads are
  capped at 16 MiB unless `fs_max_read_bytes:` says otherwise. `terminal/*`
  callbacks are never defaulted.
  """

  require Logger
  require Raxol.AgentClientProtocol.Handler.Codegen
  require Raxol.AgentClientProtocol.MethodTable

  alias Raxol.AgentClientProtocol.Client.Subscriptions
  alias Raxol.AgentClientProtocol.{Connection, Delivery, MethodTable}
  alias Raxol.AgentClientProtocol.Handler.{Codegen, Wiring}
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  # Recompile when the method table changes.
  MethodTable.depend_on_source()

  @typedoc "Per-dispatch context."
  @type ctx :: Connection.Ctx.t()

  @typedoc "A decoded `session/update` payload."
  @type update :: SessionUpdate.t()

  @type prompt_result :: struct() | {:ext, map()}

  Codegen.defcallbacks(:client)

  @doc "The generated callbacks as `{callback, arity, wire_method}`, in table order."
  @spec callbacks() :: [{atom(), arity(), String.t()}]
  def callbacks, do: Codegen.callbacks(:client)

  @doc """
  Registers `subscriber` for `{:acp_session_update, session_id, update}`
  broadcasts from `conn`. Idempotent: subscribing the same pid twice registers
  it once. Registrations end when the subscriber or the connection exits.
  """
  @spec subscribe(pid(), String.t(), pid()) :: :ok
  def subscribe(conn, session_id, subscriber \\ self())
      when is_pid(conn) and is_binary(session_id) and is_pid(subscriber),
      do: Subscriptions.subscribe(conn, session_id, subscriber)

  @doc "Removes a `subscribe/3` registration; unknown entries are a no-op."
  @spec unsubscribe(pid(), String.t(), pid()) :: :ok
  def unsubscribe(conn, session_id, subscriber \\ self())
      when is_pid(conn) and is_binary(session_id) and is_pid(subscriber),
      do: Subscriptions.unsubscribe(conn, session_id, subscriber)

  @doc false
  # Called by the default `session_update/2`. Best effort; never raises.
  @spec broadcast_update(pid(), String.t(), term()) :: :ok
  def broadcast_update(conn, session_id, update) do
    for subscriber <- Subscriptions.subscribers(conn, session_id) do
      send(subscriber, {:acp_session_update, session_id, update})
    end

    :ok
  end

  @doc """
  Decodes a raw `session/update` payload, returning `{:raw, map}` (and logging)
  instead of an error. The live dispatch path decodes strictly and drops
  undecodable notifications before any handler runs; this is for callers
  decoding raw maps themselves (replay tooling, tests).
  """
  @spec decode_update(map()) :: {:ok, SessionUpdate.t()} | {:raw, map()}
  def decode_update(raw) when is_map(raw) do
    case SessionUpdate.from_json(raw) do
      {:ok, update} ->
        {:ok, update}

      {:error, reason} ->
        Logger.warning(
          "ACP client: undecodable sessionUpdate variant, passing raw: #{inspect(reason)}"
        )

        {:raw, raw}
    end
  end

  @doc """
  Sends `session/prompt` and returns `{:ok, {updates, response}}` with the
  turn's updates oldest first, or `{:error, reason}` (timeout, transport, decode
  failure, `{:delivery_gap, %{delivered: n, expected: m}}`, or `:connection_closed`
  when the Connection dies mid-turn).
  """
  @spec prompt(pid(), struct(), pos_integer()) ::
          {:ok, {[update()], prompt_result()}} | {:error, term()}
  def prompt(conn, request, timeout_ms \\ 60_000)
      when is_pid(conn) and is_integer(timeout_ms) and timeout_ms > 0 do
    with {:ok, {updates, response}} <- run_turn(conn, request, timeout_ms, [], &[&1 | &2]) do
      {:ok, {Enum.reverse(updates), response}}
    end
  end

  @doc """
  Like `prompt/3`, but calls `on_update` in this process for each update as it
  arrives instead of accumulating them. Returns `{:ok, response}` or
  `{:error, reason}`.
  """
  @spec prompt_stream(pid(), struct(), (update() -> any()), pos_integer()) ::
          {:ok, prompt_result()} | {:error, term()}
  def prompt_stream(conn, request, on_update, timeout_ms \\ 60_000)
      when is_pid(conn) and is_function(on_update, 1) and is_integer(timeout_ms) and
             timeout_ms > 0 do
    step = fn update, acc ->
      on_update.(update)
      acc
    end

    with {:ok, {nil, response}} <- run_turn(conn, request, timeout_ms, nil, step) do
      {:ok, response}
    end
  end

  # The monitor covers a Connection killed without running its teardown, which
  # would otherwise leave this process waiting forever.
  defp run_turn(conn, request, timeout_ms, acc, step) do
    tag = make_ref()
    mon = Process.monitor(conn)

    try do
      with :ok <-
             Connection.async_request(conn, "session/prompt", request, self(), tag, timeout_ms) do
        await_turn(%{tag: tag, mon: mon, next: 0, count: nil, acc: acc, step: step})
      end
    after
      Process.demonitor(mon, [:flush])
    end
  end

  defp await_turn(%{tag: tag, next: next} = turn) do
    receive do
      {:acp_turn_update, ^tag, ^next, notif} ->
        await_turn(%{turn | next: next + 1, acc: turn.step.(notif.update, turn.acc)})

      # Unreachable with a single sender; a tripwire, never a silent skip.
      {:acp_turn_update, ^tag, ordinal, _notif} ->
        fail_turn(:delivery_order, %{expected: next, got: ordinal})

      {:acp_turn_end, ^tag, n} ->
        await_turn(%{turn | count: n})

      {:acp_result, ^tag, {:ok, response}} ->
        if turn.count != nil and next < turn.count,
          do: fail_turn(:delivery_gap, %{delivered: next, expected: turn.count}),
          else: {:ok, {turn.acc, response}}

      {:acp_result, ^tag, {:error, _} = error} ->
        error

      {:DOWN, mon, :process, _pid, _reason} when mon == turn.mon ->
        {:error, :connection_closed}
    end
  end

  # A gap is corruption, not lateness: fail the turn rather than retry.
  defp fail_turn(reason, meta) do
    Delivery.emit(Map.put(meta, :decision, :fail))
    {:error, {reason, meta}}
  end

  defmacro __using__(opts) do
    fs_sandbox = Keyword.get(opts, :fs_sandbox)
    fs_opts = Keyword.take(opts, [:fs_max_read_bytes])

    quote do
      unquote(Codegen.using(__MODULE__, :client))

      # Replaces the generated `:ok` default; still overridable.
      @impl Raxol.AgentClientProtocol.Client
      def session_update(notification, ctx) do
        Raxol.AgentClientProtocol.Client.broadcast_update(
          ctx.conn,
          notification.session_id,
          notification.update
        )
      end

      defoverridable session_update: 2

      unquote(Raxol.AgentClientProtocol.Client.__fs_sandbox_block__(fs_sandbox, fs_opts))
    end
  end

  @doc false
  @spec __fs_sandbox_block__(String.t() | nil, keyword()) :: Macro.t()
  def __fs_sandbox_block__(path, opts \\ [])

  def __fs_sandbox_block__(nil, _opts), do: quote(do: :ok)

  def __fs_sandbox_block__(path, opts) when is_binary(path) do
    read_opts =
      case Keyword.fetch(opts, :fs_max_read_bytes) do
        {:ok, max} when is_integer(max) and max > 0 ->
          [max_read_bytes: max]

        {:ok, other} ->
          raise ArgumentError,
                "fs_max_read_bytes must be a positive integer, got: #{inspect(other)}"

        :error ->
          []
      end

    quote do
      alias Raxol.AgentClientProtocol.Client.FsSandbox

      @impl Raxol.AgentClientProtocol.Client
      def read_text_file(req, _ctx),
        do:
          Raxol.AgentClientProtocol.Client.FsSandbox.read(unquote(path), req, unquote(read_opts))

      @impl Raxol.AgentClientProtocol.Client
      def write_text_file(req, _ctx),
        do: FsSandbox.write(unquote(path), req)

      defoverridable read_text_file: 2, write_text_file: 2
    end
  end

  defmodule ConnectionSupervisor do
    @moduledoc false
    use Supervisor

    @spec start_link(Raxol.AgentClientProtocol.Handler.Wiring.init_arg(), keyword()) ::
            Supervisor.on_start()
    def start_link(init_arg, opts \\ []), do: Supervisor.start_link(__MODULE__, init_arg, opts)

    @impl Supervisor
    def init(init_arg), do: Raxol.AgentClientProtocol.Handler.Wiring.init(:client, init_arg)
  end

  @doc """
  Child spec for embedding one client connection subtree. Requires `:handler`
  and `:transport`; accepts `:handler_arg`, `:name` and `:id` (default
  `#{inspect(__MODULE__)}`).
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
  `ConnectionSupervisor` pid, not an outer supervisor.
  """
  @spec connection(pid()) :: {:ok, pid()} | {:error, :not_found}
  def connection(sup) when is_pid(sup), do: Wiring.connection(sup)
end
