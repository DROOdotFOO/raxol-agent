defmodule Raxol.Broker.Clock do
  @moduledoc "Isolates configured clocks and rebuilds valid UTC ISO timestamps."

  alias Raxol.Broker.Plain

  @timeout 5_000

  def now(clock) when is_function(clock, 0) do
    task = Task.async(clock)

    case Task.yield(task, @timeout) || Task.shutdown(task, :brutal_kill) do
      {:ok, %DateTime{} = now} -> utc(Plain.normalize(now))
      {:ok, other} -> {:error, {:invalid_clock, other}}
      {:exit, reason} -> {:error, {:clock_crashed, reason}}
      nil -> {:error, :clock_timeout}
    end
  end

  def now(_clock), do: {:error, :invalid_clock}

  defp utc(
         {:ok,
          %DateTime{
            time_zone: "Etc/UTC",
            utc_offset: 0,
            std_offset: 0,
            microsecond: {micro, precision}
          } = now}
       )
       when precision in 0..6 do
    if Calendar.ISO.valid_date?(now.year, now.month, now.day) and
         Calendar.ISO.valid_time?(now.hour, now.minute, now.second, {micro, precision}),
       do: {:ok, now},
       else: {:error, {:invalid_clock, now}}
  end

  defp utc({:ok, other}), do: {:error, {:invalid_clock, other}}
  defp utc({:error, reason}), do: {:error, {:invalid_clock, reason}}
end
