defmodule Raxol.AgentClientProtocol.Ext.Journal.Record do
  @moduledoc """
  One grow-only journal record.

  Fields ONLY ever get ADDED (optional-with-default); never renamed, retyped,
  reordered, narrowed. A reader that meets an unknown `kind` skips/passes it
  through — never an error. This is what makes the generic `_raxol/session.record`
  delivery frame future-proof.

  Field meanings:

    * `offset` — per-session positive integer, from 1, contiguous, strictly
      increasing in append order (THE OFFSET LAW in
      `Raxol.AgentClientProtocol.Ext.Journal`). Assigned
      atomically inside `append` (offset = current `high_watermark` + 1, under
      the Writer's single-mailbox serialization). Never reused/reordered.
    * `session_id` — binary, NEVER atomized.
    * `kind` — grow-only vocabulary, a STRING on disk/wire (`"session_created"`,
      `"session_update"`, `"turn_started"`, `"turn_completed"`, …). Never
      `String.to_atom`'d on read.
    * `payload` — JSON-safe wire map (string keys); value-identity under any
      Layer-2 codec so a writerless reader in another language needs no Elixir
      terms.
    * `taint` — trust classification, STAMPED at append, NEVER filtered on the
      delivery path (annotate-never-filter).
    * `ts_hook` — ms epoch assigned by the store clock at append.
  """

  @enforce_keys [:offset, :session_id, :kind, :payload, :taint, :ts_hook]
  defstruct [:offset, :session_id, :kind, :payload, :taint, :ts_hook]

  @type t :: %__MODULE__{
          offset: pos_integer(),
          session_id: String.t(),
          kind: String.t(),
          payload: map(),
          taint: String.t(),
          ts_hook: integer()
        }
end

defmodule Raxol.AgentClientProtocol.Ext.Journal do
  @moduledoc """
  The durable session journal — behaviour + live-bus registration facade.

  This is the foundation cell of the reattach extension. Sessions hold only
  ephemeral turn state; the DURABLE state
  lives here, and a reattach replays it from an exact offset.

  ## THE OFFSET LAW (storage-independent)

  1. Offsets are **per-session positive integers starting at 1, contiguous,
     strictly increasing in append order**. Assigned atomically inside `append`
     (offset = current `high_watermark` + 1), under the Writer's single-mailbox
     serialization. Never reused, never reordered, never reassigned.
  2. `high_watermark(j)` returns the **last DURABLE offset** (`0` = empty
     session), **read from the store** — a conforming impl MUST NOT serve a
     cached counter that can lag or lead the durable state.
  3. `read(j, from, to)` returns exactly the records with `from <= offset <= to`,
     in offset order, value-identical to what `append` stored.
  4. A record, once `append` returns `{:ok, record}`, is read-visible: a
     `high_watermark` or `read` issued after that return observes it. This is
     what makes the Writer's "append THEN publish" order meaningful.
  5. **Genesis:** offset 1 of a journal-managed session is ALWAYS a
     `"session_created"` record (appended by the Writer on first use).
  6. Retention: grow-only, no truncation.

  ## The handle is PER-SESSION

  The opaque handle `j` binds `session_id`, so the callbacks are
  `append(j, entry)` / `read(j, from, to)` / `high_watermark(j)`.
  `session_id` is carried inside `j` and stamped
  into every record; a per-session `:ordered_set` keyed by `offset` is the ETS
  layout (`Raxol.AgentClientProtocol.Ext.Journal.Mem`).

  ## Storage callbacks

    * `open(session_id, opts)` — construct a per-session handle. The store (ETS
      table / on-disk log) is owned by a process that OUTLIVES any single Writer
      (the app supervisor in production), so the journal survives Writer death —
      the precondition for the Writer-restart tip-fold orphan repair.
    * `append(j, entry)` — assign the next offset atomically, stamp `session_id`
      + `ts_hook`, persist, and return the COMPLETE stamped `%Record{}` (the
      Writer needs the whole record to publish it — the offset is
      `record.offset`). `entry` is `%{kind:, payload:, taint:}`.
    * `read(j, from, to)` — offset-ordered records in `[from, to]`.
    * `high_watermark(j)` — last durable offset, read from the store.
    * `close(j)` — release the handle (grow-only convenience; not load-bearing).

  ## Live-bus registration (facade → Writer)

  `subscribe/2` and `unsubscribe/2` are the "live bus registration" surface. They
  are DELIBERATELY NOT storage callbacks: registration must be **serialized
  against appends in ONE mailbox** — the Writer's — so the ordering between a
  registration and any append is a mailbox-order guarantee, not a memory-model
  one. These facade functions therefore route to
  `Raxol.AgentClientProtocol.Ext.Journal.Writer` (the single publisher), which
  owns the subscriber set in its own state. A bare journal-level registry insert
  would break that seam.
  """

  alias Raxol.AgentClientProtocol.Ext.Journal.Record
  alias Raxol.AgentClientProtocol.Ext.Journal.Writer

  # The package `Application`-started `DynamicSupervisor` under which Writers
  # start lazily. Its name is contract: `Application.children/0`
  # starts it, `ensure_writer/3` places children under it. An embedder in
  # library mode gets the identical name from `Application.children/0`.
  @writer_supervisor Raxol.AgentClientProtocol.Ext.Journal.WriterSupervisor

  @typedoc "Opaque, per-session storage handle."
  @type j :: term()

  @typedoc "An append request: the Writer supplies kind/payload/taint; the store stamps the rest."
  @type entry :: %{
          required(:kind) => String.t(),
          required(:payload) => map(),
          required(:taint) => String.t()
        }

  @callback open(session_id :: String.t(), opts :: keyword()) ::
              {:ok, j} | {:error, term()}
  @callback append(j, entry()) ::
              {:ok, Record.t()} | {:error, :read_only | term()}
  @callback read(j, from :: pos_integer(), to :: non_neg_integer()) ::
              {:ok, [Record.t()]} | {:error, term()}
  @callback high_watermark(j) :: non_neg_integer()
  @callback close(j) :: :ok

  @optional_callbacks close: 1

  # -- Lazy Writer start (→ WriterSupervisor) --------------------------------

  @doc """
  Start-or-lookup the single-publisher `Writer` for `session_id`, lazily, under
  the package `Application`'s `WriterSupervisor` (a concurrent
  `:already_started` is folded into `{:ok, pid}`). Idempotent: a live
  Writer for the session is returned as-is (`{:ok, pid}`) without a second start.

  `journal` is the `{module, handle}` durable store for the session; the handle's
  owner MUST outlive the Writer (so a restarted Writer can tip-fold). `opts`
  are extra `Writer.start_link/1` opts (e.g. `:session_meta`). Children start
  `:transient` — a Writer that exits `:normal` is not resurrected, but a crash is
  restarted so the live tail survives (the journal, not the Writer, is durable).

  Returns `{:error, :no_supervisor}` when the `WriterSupervisor` is not running
  (the `Application` did not start / an embedder omitted it from `children/0`) —
  fail soft, never raise into a turn.
  """
  @spec ensure_writer(String.t(), {module(), term()}, keyword()) ::
          {:ok, pid()} | {:error, :no_supervisor | term()}
  def ensure_writer(session_id, journal, opts \\ [])
      when is_binary(session_id) and is_tuple(journal) do
    case Writer.whereis(session_id) do
      pid when is_pid(pid) -> {:ok, pid}
      nil -> start_writer(session_id, journal, opts)
    end
  end

  defp start_writer(session_id, journal, opts) do
    if is_pid(Process.whereis(@writer_supervisor)) do
      spec =
        Supervisor.child_spec(
          {Writer, [session_id: session_id, journal: journal] ++ opts},
          restart: :transient
        )

      case DynamicSupervisor.start_child(@writer_supervisor, spec) do
        {:ok, pid} -> {:ok, pid}
        {:error, {:already_started, pid}} -> {:ok, pid}
        {:error, _} = err -> err
      end
    else
      {:error, :no_supervisor}
    end
  end

  # -- Live-bus registration facade (→ Writer, the single publisher) ----------

  @doc """
  Register `subscriber` for the live tail of `session_id`. Routed through the
  session's Writer so it is serialized against appends in ONE mailbox.
  Returns `{:error, :no_writer}` if no live Writer serves the session
  (writerless / history-only sessions have no live tail).
  """
  @spec subscribe(String.t(), pid()) :: :ok | {:error, :no_writer}
  def subscribe(session_id, subscriber)
      when is_binary(session_id) and is_pid(subscriber) do
    case Writer.whereis(session_id) do
      nil -> {:error, :no_writer}
      server -> Writer.subscribe(server, subscriber)
    end
  end

  @doc """
  Idempotently detach `subscriber` from the live tail of `session_id`. A missing
  Writer is a no-op (`:ok`) — there is nothing to detach from.
  """
  @spec unsubscribe(String.t(), pid()) :: :ok
  def unsubscribe(session_id, subscriber)
      when is_binary(session_id) and is_pid(subscriber) do
    case Writer.whereis(session_id) do
      nil -> :ok
      server -> Writer.unsubscribe(server, subscriber)
    end
  end
end
