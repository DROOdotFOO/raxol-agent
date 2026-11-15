defmodule Raxol.Broker.MarketCalendarHolidayTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.MarketCalendar

  # https://www.nyse.com/markets/hours-calendars
  @holidays [
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
  ]

  defp local(date, time),
    do: DateTime.new!(date, time, "America/New_York", Tz.TimeZoneDatabase)

  test "every published 2026 and 2027 full-day holiday is closed all New York day" do
    for date <- @holidays,
        time <- [~T[00:00:00], ~T[04:00:00], ~T[09:30:00], ~T[15:59:59], ~T[19:59:59], ~T[23:59:59]] do
      now = local(date, time)
      refute MarketCalendar.trading_day?(now), "unexpected trading day: #{now}"
      assert MarketCalendar.session(now) == :closed, "unexpected open session: #{now}"
    end
  end

  test "all other weekdays remain trading dates, including days adjacent to observed holidays" do
    for date <- Date.range(~D[2026-01-01], ~D[2027-12-31]),
        Date.day_of_week(date) <= 5,
        date not in @holidays do
      assert MarketCalendar.trading_day?(local(date, ~T[12:00:00]))
      assert MarketCalendar.session(local(date, ~T[09:30:00])) == :regular
      assert MarketCalendar.session(local(date, ~T[04:00:00])) == :extended
    end

    # NYSE does not observe Saturday 2028-01-01 on Friday 2027-12-31.
    assert MarketCalendar.session(~U[2027-12-31 17:00:00Z]) == :regular
  end

  test "weekends are closed throughout the New York day" do
    for date <- [~D[2026-07-04], ~D[2026-07-05], ~D[2027-06-19], ~D[2027-06-20]],
        time <- [~T[00:00:00], ~T[09:30:00], ~T[19:59:59], ~T[23:59:59]] do
      refute MarketCalendar.trading_day?(local(date, time))
      assert MarketCalendar.session(local(date, time)) == :closed
    end
  end

  test "holiday boundaries use New York midnight rather than UTC midnight in EST and EDT" do
    for {before_holiday, start, last, following_day} <- [
          {~U[2026-01-01 04:59:59Z], ~U[2026-01-01 05:00:00Z],
           ~U[2026-01-02 04:59:59Z], ~U[2026-01-02 05:00:00Z]},
          {~U[2026-06-19 03:59:59Z], ~U[2026-06-19 04:00:00Z],
           ~U[2026-06-20 03:59:59Z], ~U[2026-06-22 04:00:00Z]}
        ] do
      assert MarketCalendar.trading_day?(before_holiday)
      refute MarketCalendar.trading_day?(start)
      refute MarketCalendar.trading_day?(last)
      assert MarketCalendar.trading_day?(following_day)
      assert MarketCalendar.day_start(start) == start
      assert MarketCalendar.day_start(last) == start
    end

    # At this UTC date boundary, it is still the preceding trading day in New York.
    assert MarketCalendar.session(~U[2026-07-03 00:00:00Z]) == :closed
    assert MarketCalendar.trading_day?(~U[2026-07-03 00:00:00Z])
    refute MarketCalendar.trading_day?(~U[2026-07-03 04:00:00Z])
  end
end
