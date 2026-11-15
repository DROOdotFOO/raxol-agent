defmodule Raxol.Broker.Halt do
  @moduledoc """
  Stopping the broker short of a restart.

  `pause/2` is the drawdown breaker's: it disarms, journals a `halt` record
  naming the reason, and pauses every strategy runner (`{:pause, reason}`,
  sent, never called, so a runner blocked on the executor cannot deadlock
  it). Only a fresh `mix raxol.broker.arm` resumes them: arming resumes
  every runner paused for a reason arming clears.

  Options: `:journal` (default `Raxol.Broker.Journal`), `:strategies` (the
  strategy supervisor, default `Raxol.Broker.Strategy.Supervisor`),
  `:detail` (a map journaled with the reason).
  """

  alias Raxol.Broker.{Journal, Mode}
  alias Raxol.Broker.Strategy

  @doc "Disarm, journal a `halt` record and pause every runner for `reason`."
  @spec pause(atom(), keyword()) :: :ok
  def pause(reason, opts \\ []) when is_atom(reason) do
    journal = Keyword.get(opts, :journal, Journal)
    name = Atom.to_string(reason)

    _ = Mode.disarm(name, journal: journal, by: "broker")
    fields = %{"reason" => name, "detail" => Keyword.get(opts, :detail, %{})}
    _ = Journal.record_halt(fields, journal)
    Strategy.Supervisor.pause_all(reason, supervisor: strategies(opts))
  end

  defp strategies(opts), do: Keyword.get(opts, :strategies, Strategy.Supervisor)
end
