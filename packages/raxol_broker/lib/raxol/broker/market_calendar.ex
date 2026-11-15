defmodule Raxol.Broker.MarketCalendar do
  @moduledoc """
  The exchange day, in America/New_York.

    * `day_start/1`: the UTC instant of the New York midnight that began the
      exchange day containing `now`. The daily notional cap counts from it,
      so it resets at New York midnight on both sides of a daylight-saving
      change, not at UTC midnight.
    * `trading_day?/1`: whether the New York date is a weekday other than a
      full-day NYSE holiday in 2026 or 2027.
    * `session/1`: `:regular` (09:30 to 16:00 New York time on trading
      days), `:extended` (04:00 to 09:30 and 16:00 to 20:00 on those days)
      or `:closed`. Full-day NYSE holidays in 2026 and 2027 are closed all
      day. Half days and holidays outside those years are not modelled.

  The time zone database (`Tz.TimeZoneDatabase`) is passed explicitly; the
  VM default is left alone.
  """

  @zone "America/New_York"
  @db Tz.TimeZoneDatabase

  # NYSE Holidays & Trading Hours, including observed dates:
  # https://www.nyse.com/markets/hours-calendars
  @holidays MapSet.new([
              ~D[2026-01-01],
              ~D[2026-01-19],
              ~D[2026-02-16],
              ~D[2026-04-03],
              ~D[2026-05-25],
              ~D[2026-06-19],
              ~D[2026-07-03],
              ~D[2026-09-07],
              ~D[2026-11-26],
              ~D[2026-12-25],
              ~D[2027-01-01],
              ~D[2027-01-18],
              ~D[2027-02-15],
              ~D[2027-03-26],
              ~D[2027-05-31],
              ~D[2027-06-18],
              ~D[2027-07-05],
              ~D[2027-09-06],
              ~D[2027-11-25],
              ~D[2027-12-24]
            ])

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

  @doc "Whether `now` falls on a New York trading date; see the moduledoc."
  @spec trading_day?(DateTime.t()) :: boolean()
  def trading_day?(%DateTime{} = now), do: now |> local() |> DateTime.to_date() |> trading_date?()

  @doc "The market session at `now`; see the moduledoc."
  @spec session(DateTime.t()) :: :regular | :extended | :closed
  def session(%DateTime{} = now) do
    local = local(now)
    minute = local.hour * 60 + local.minute

    cond do
      not trading_date?(DateTime.to_date(local)) -> :closed
      minute >= 9 * 60 + 30 and minute < 16 * 60 -> :regular
      minute >= 4 * 60 and minute < 20 * 60 -> :extended
      true -> :closed
    end
  end

  defp trading_date?(date), do: Date.day_of_week(date) <= 5 and not MapSet.member?(@holidays, date)

  defp local(now), do: DateTime.shift_zone!(now, @zone, @db)
end
