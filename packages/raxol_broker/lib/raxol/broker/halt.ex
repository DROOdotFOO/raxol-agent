defmodule Raxol.Broker.Halt do
  @moduledoc """
  Stopping the broker short of a restart.

  ## Kill switch

  `kill/1`, in this order:

    1. disarms (`Raxol.Broker.Mode.disarm/2`, reason `kill`);
    2. stops every strategy runner (the strategies stay added);
    3. lists the account's open agent-initiated equity orders and pending
       trade approvals and cancels or declines each through the executor
       (`Raxol.Broker.Executor.halt_orders/2`), all at once, each call
       bounded by `:bound` milliseconds, so every cancel and decline is a
       journaled group;
    4. journals a `halt` record (`reason: "kill"`) with the trigger and how
       each cancel and decline ended.

  Nothing is retried: a cancel that timed out is journaled `unknown` with
  the `:timeout` and reported, and the person decides what to do next.
  Exposed as `mix raxol.broker.kill` and the dashboard's `K` key.

  ## Pause

  `pause/2` is the drawdown breaker's: it disarms, journals a `halt` record
  naming the reason, and pauses every strategy runner (`{:pause, reason}`,
  sent, never called, so a runner blocked on the executor cannot deadlock
  it). Only a fresh `mix raxol.broker.arm` resumes them.

  ## Options

  `:journal` (default `Raxol.Broker.Journal`), `:strategies` (the strategy
  supervisor, default `Raxol.Broker.Strategy.Supervisor`); for `kill/1`
  also `:executor` (default `Raxol.Broker.Executor`), `:bound` (default
  10_000) and `:trigger` (who pulled it, default `"cli"`); for `pause/2`
  `:detail` (a map journaled with the reason).
  """

  alias Raxol.Broker.{Executor, Journal, Mode}
  alias Raxol.Broker.Strategy

  @default_bound 10_000

  @type result :: %{kind: :cancel | :decline, id: String.t(), outcome: String.t()}

  @doc """
  Pull the kill switch (see the moduledoc). `{:ok, summary}` with
  `:disarmed` (`:ok` or the journal's refusal), `:orders` and `:approvals`
  (each `{:ok, ids}` or `{:error, reason}` as listed) and `:results`.
  """
  @spec kill(keyword()) :: {:ok, map()}
  def kill(opts \\ []) do
    journal = Keyword.get(opts, :journal, Journal)
    trigger = Keyword.get(opts, :trigger, "cli")
    bound = Keyword.get(opts, :bound, @default_bound)

    disarmed = Mode.disarm("kill", journal: journal, by: trigger)
    Strategy.Supervisor.stop_all(supervisor: strategies(opts))
    orders = halt_orders(Keyword.get(opts, :executor, Executor), bound)
    summary = summary(disarmed, orders)

    fields = %{
      "reason" => "kill",
      "trigger" => trigger,
      "results" =>
        Enum.map(summary.results, &Map.new(&1, fn {k, v} -> {Atom.to_string(k), v} end))
    }

    _ = Journal.record_halt(fields, journal)
    {:ok, summary}
  end

  defp halt_orders(executor, bound) do
    Executor.halt_orders(executor, bound)
  catch
    :exit, reason -> {:error, {:executor_down, reason}}
  end

  defp summary(disarmed, {:ok, %{orders: orders, approvals: approvals, results: results}}) do
    %{
      disarmed: disarmed,
      orders: orders,
      approvals: approvals,
      results: Enum.map(results, &result/1)
    }
  end

  defp summary(disarmed, {:error, reason}),
    do: %{disarmed: disarmed, orders: {:error, reason}, approvals: {:error, reason}, results: []}

  defp result(%{kind: kind, id: id, outcome: outcome}),
    do: %{kind: kind, id: id, outcome: outcome_text(outcome)}

  defp outcome_text({:ok, status, %{"error" => error}}) when is_binary(error),
    do: "#{status} #{error}"

  defp outcome_text({:ok, status, _response}), do: Atom.to_string(status)
  defp outcome_text({:error, reason}), do: "error " <> inspect(reason, structs: false)
  defp outcome_text(reason), do: "error " <> inspect(reason, structs: false)

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
