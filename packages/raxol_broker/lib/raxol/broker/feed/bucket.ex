defmodule Raxol.Broker.Feed.Bucket do
  @moduledoc """
  The request budget every `Raxol.Broker.Feed` shares: at most `:limit`
  grants (default 10) in any `:window` milliseconds (default 60_000).

  The window slides: `take/1` grants when fewer than `:limit` grants fall
  within the last `:window` milliseconds, else answers `{:wait, ms}`, the
  time until the oldest of them leaves the window. `:clock` is a zero-arity
  function returning monotonic milliseconds (default
  `System.monotonic_time(:millisecond)`).
  """

  use GenServer

  @default_limit 10
  @default_window 60_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, opts, Keyword.put_new(gen_opts, :name, __MODULE__))
  end

  @doc "Take one grant: `:ok`, or `{:wait, ms}` when the window is full."
  @spec take(GenServer.server()) :: :ok | {:wait, pos_integer()}
  def take(bucket \\ __MODULE__), do: GenServer.call(bucket, :take)

  @impl GenServer
  def init(opts) do
    {:ok,
     %{
       limit: Keyword.get(opts, :limit, @default_limit),
       window: Keyword.get(opts, :window, @default_window),
       clock: Keyword.get(opts, :clock, fn -> System.monotonic_time(:millisecond) end),
       grants: :queue.new()
     }}
  end

  @impl GenServer
  def handle_call(:take, _from, state) do
    now = state.clock.()
    grants = expire(state.grants, now - state.window)

    if :queue.len(grants) < state.limit do
      {:reply, :ok, %{state | grants: :queue.in(now, grants)}}
    else
      {:value, oldest} = :queue.peek(grants)
      {:reply, {:wait, max(oldest + state.window - now, 1)}, %{state | grants: grants}}
    end
  end

  defp expire(grants, cutoff) do
    case :queue.peek(grants) do
      {:value, at} when at <= cutoff -> expire(:queue.drop(grants), cutoff)
      _ -> grants
    end
  end
end
