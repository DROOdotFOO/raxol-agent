defmodule Raxol.AgentClientProtocol.Connection.NotificationPool do
  @moduledoc false
  # Accounting for notification handlers; the Connection starts the tasks.
  #
  # At most `max_running` handlers run at once. Items arriving at that cap wait
  # in arrival order, as long as the backlog stays within `max_queued` items
  # and `max_queued_bytes` (the external term size of the decoded params, so a
  # peer cannot park gigabytes in a few thousand large frames); anything beyond
  # either bound is refused. A handler counts as running from admission until
  # the Connection reads its result or exit, so `running` never falls below the
  # number of handlers actually executing.

  alias Raxol.AgentClientProtocol.Connection.Ctx

  @type item :: {method :: String.t(), dispatchable :: term(), Ctx.t()}

  @type t :: %__MODULE__{
          max_running: pos_integer(),
          max_queued: pos_integer(),
          max_queued_bytes: pos_integer(),
          running: non_neg_integer(),
          backlog: :queue.queue({non_neg_integer(), item()}),
          queued: non_neg_integer(),
          queued_bytes: non_neg_integer()
        }

  # `backlog` is set by new/3: a `:queue.new()` default would be compiled into
  # a literal, which breaks the queue's opaque type.
  @enforce_keys [:max_running, :max_queued, :max_queued_bytes, :backlog]
  defstruct [
    :max_running,
    :max_queued,
    :max_queued_bytes,
    :backlog,
    running: 0,
    queued: 0,
    queued_bytes: 0
  ]

  @spec new(pos_integer(), pos_integer(), pos_integer()) :: t()
  def new(max_running, max_queued, max_queued_bytes) do
    %__MODULE__{
      max_running: max_running,
      max_queued: max_queued,
      max_queued_bytes: max_queued_bytes,
      backlog: :queue.new()
    }
  end

  # `{:run, pool}`: the item may start now and is counted as running.
  # `{:queued, pool}`: it waits. `:full`: it is refused. An item never
  # overtakes one already waiting.
  @spec admit(t(), item()) :: {:run, t()} | {:queued, t()} | :full
  def admit(%__MODULE__{queued: 0, running: running, max_running: max} = pool, _item)
      when running < max,
      do: {:run, %{pool | running: running + 1}}

  def admit(%__MODULE__{queued: queued, max_queued: max} = pool, {_, dispatchable, _} = item)
      when queued < max do
    size = :erlang.external_size(dispatchable)

    if pool.queued_bytes + size <= pool.max_queued_bytes do
      {:queued,
       %{
         pool
         | backlog: :queue.in({size, item}, pool.backlog),
           queued: queued + 1,
           queued_bytes: pool.queued_bytes + size
       }}
    else
      :full
    end
  end

  def admit(%__MODULE__{}, _item), do: :full

  # Frees one running slot (a handler finished, or a counted start failed) and
  # returns, in order, the waiting items that may start now, each counted as
  # running. With nothing running there is no slot to free: the pool is
  # returned unchanged rather than letting a miscount stop the Connection.
  @spec release(t()) :: {[item()], t()}
  def release(%__MODULE__{running: 0} = pool), do: {[], pool}

  def release(%__MODULE__{running: running} = pool),
    do: take_ready(%{pool | running: running - 1}, [])

  defp take_ready(%{queued: 0} = pool, acc), do: {Enum.reverse(acc), pool}

  defp take_ready(%{running: running, max_running: max} = pool, acc) when running >= max,
    do: {Enum.reverse(acc), pool}

  defp take_ready(pool, acc) do
    {{:value, {size, item}}, backlog} = :queue.out(pool.backlog)

    take_ready(
      %{
        pool
        | backlog: backlog,
          queued: pool.queued - 1,
          queued_bytes: pool.queued_bytes - size,
          running: pool.running + 1
      },
      [item | acc]
    )
  end

  # Forgets every running and waiting item (the link went down) and returns
  # the waiting ones, so their loss can be reported.
  @spec reset(t()) :: {[item()], t()}
  def reset(%__MODULE__{} = pool) do
    dropped = pool.backlog |> :queue.to_list() |> Enum.map(&elem(&1, 1))
    {dropped, %{pool | running: 0, backlog: :queue.new(), queued: 0, queued_bytes: 0}}
  end
end
