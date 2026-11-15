defmodule Raxol.Broker.MarketCalendar do
  @moduledoc """
  The exchange day, in America/New_York.

    * `day_start/1`: the UTC instant of the New York midnight that began the
      exchange day containing `now`. The daily notional cap counts from it,
      so it resets at New York midnight on both sides of a daylight-saving
      change, not at UTC midnight.
    * `session/1`: `:regular` (09:30 to 16:00 New York time, Monday to
      Friday), `:extended` (04:00 to 09:30 and 16:00 to 20:00 on those days)
      or `:closed`. Exchange holidays and half days are not modelled: on a
      holiday this says `:regular` or `:extended` and Robinhood refuses the
      order.

  The time zone database (`Tz.TimeZoneDatabase`) is passed explicitly; the
  VM default is left alone.
  """

  @zone "America/New_York"
  @db Tz.TimeZoneDatabase

  @doc "The UTC instant the New York exchange day containing `now` began."
  @spec day_start(DateTime.t()) :: DateTime.t()
  def day_start(%DateTime{} = now) do
    date = now |> local() |> DateTime.to_date()

    case DateTime.new(date, ~T[00:00:00], @zone, @db) do
      {:ok, midnight} -> DateTime.shift_zone!(midnight, "Etc/UTC", @db)
      # Midnight never falls in a New York gap or overlap; this is the
      # database refusing a date outside its range.
      {:ambiguous, first, _second} -> DateTime.shift_zone!(first, "Etc/UTC", @db)
      {:gap, _before, after_gap} -> DateTime.shift_zone!(after_gap, "Etc/UTC", @db)
    end
  end

  @doc "The market session at `now`; see the moduledoc."
  @spec session(DateTime.t()) :: :regular | :extended | :closed
  def session(%DateTime{} = now) do
    local = local(now)
    minute = local.hour * 60 + local.minute

    cond do
      Date.day_of_week(local) > 5 -> :closed
      minute >= 9 * 60 + 30 and minute < 16 * 60 -> :regular
      minute >= 4 * 60 and minute < 20 * 60 -> :extended
      true -> :closed
    end
  end

  defp local(now), do: DateTime.shift_zone!(now, @zone, @db)
end
