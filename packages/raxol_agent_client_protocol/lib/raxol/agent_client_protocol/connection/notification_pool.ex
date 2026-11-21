defmodule Raxol.AgentClientProtocol.Connection.NotificationPool do
  @moduledoc false
  # Accounting for notification handlers: at most `max_running` run at once,
  # up to `max_queued` more wait in arrival order, and anything beyond that is
  # refused. A handler counts as running from admission until the Connection
  # reads its result or exit, so `running` never falls below the number of
  # handlers actually executing. Pure; the Connection starts the tasks.

  alias Raxol.AgentClientProtocol.Connection.Ctx

  @type item :: {method :: String.t(), dispatchable :: term(), Ctx.t()}

  @type t :: %__MODULE__{
          sup: pid() | nil,
          max_running: pos_integer(),
          max_queued: pos_integer(),
          running: non_neg_integer(),
          backlog: :queue.queue(item()),
          queued: non_neg_integer()
        }

  # `backlog` is set by new/2: a `:queue.new()` default would be compiled into
  # a literal, which breaks the queue's opaque type.
  @enforce_keys [:max_running, :max_queued, :backlog]
  defstruct [:sup, :max_running, :max_queued, :backlog, running: 0, queued: 0]

  @spec new(pos_integer(), pos_integer()) :: t()
  def new(max_running, max_queued),
    do: %__MODULE__{max_running: max_running, max_queued: max_queued, backlog: :queue.new()}

  @doc """
  Admits a new item: `{:run, pool}` when it may start now (it is counted as
  running), `{:queued, pool}` when it waits, `:full` when it is refused. An
  item never overtakes one already waiting.
  """
  @spec admit(t(), item()) :: {:run, t()} | {:queued, t()} | :full
  def admit(%__MODULE__{queued: 0, running: running, max_running: max} = pool, _item)
      when running < max,
      do: {:run, %{pool | running: running + 1}}

  def admit(%__MODULE__{queued: queued, max_queued: max} = pool, item) when queued < max,
    do: {:queued, %{pool | backlog: :queue.in(item, pool.backlog), queued: queued + 1}}

  def admit(%__MODULE__{}, _item), do: :full

  @doc """
  Frees one running slot (a handler finished, or a counted start failed) and
  returns, in order, the waiting items that may start now, each counted as
  running.
  """
  @spec release(t()) :: {[item()], t()}
  def release(%__MODULE__{running: running} = pool) when running > 0,
    do: take_ready(%{pool | running: running - 1}, [])

  defp take_ready(%{queued: 0} = pool, acc), do: {Enum.reverse(acc), pool}

  defp take_ready(%{running: running, max_running: max} = pool, acc) when running >= max,
    do: {Enum.reverse(acc), pool}

  defp take_ready(pool, acc) do
    {{:value, item}, backlog} = :queue.out(pool.backlog)

    take_ready(
      %{pool | backlog: backlog, queued: pool.queued - 1, running: pool.running + 1},
      [item | acc]
    )
  end

  @doc "Forgets every running and waiting item (the link went down)."
  @spec reset(t()) :: t()
  def reset(%__MODULE__{} = pool), do: %{pool | running: 0, backlog: :queue.new(), queued: 0}
end
