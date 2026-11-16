defmodule Raxol.Broker.Journal.DayBaselineTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.Journal
  alias Raxol.Broker.Journal.Codec
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log
  @day ~U[2026-10-02 04:00:00Z]

  defmodule CallerCalendar do
    def naive_datetime_to_iso_days(year, month, day, hour, minute, second, microsecond) do
      send(Process.whereis(Raxol.Broker.Journal.DayBaselineTest), :caller_calendar_ran)
      Calendar.ISO.naive_datetime_to_iso_days(year, month, day, hour, minute, second, microsecond)
    end

    def day_rollover_relative_to_midnight_utc do
      send(Process.whereis(Raxol.Broker.Journal.DayBaselineTest), :caller_calendar_ran)
      {0, 1}
    end
  end

  defp fields(value \\ "1000") do
    %{
      account: "FAKE-0001",
      day_start: @day,
      value: Broker.d(value),
      currency: "USD",
      request_started_at: @day,
      observed_at: @day
    }
  end

  test "atomic first write cannot be replaced, even with a lower value" do
    fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})
    ctx = Broker.baseline_journal!(fake, @day)

    assert Journal.record_day_baseline(fields("900"), ctx.journal) ==
             {:error, :day_baseline_exists}

    assert Journal.record_day_baseline(fields(), ctx.journal) == {:error, :day_baseline_exists}
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, Broker.d("1000")}
    assert length(Broker.records(ctx.path)) == 1
  end

  test "writer independently rejects a capture outside the journal clock window" do
    fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})
    ctx = Broker.journal!(clock: fn -> DateTime.add(@day, 60) end)
    Broker.capture_baseline!(ctx.journal, fake, fn -> @day end)
    assert Journal.day_baseline("FAKE-0001", @day, ctx.journal) == {:ok, nil}
    assert Broker.records(ctx.path) == []
  end

  test "writer rejects nonpositive, nonfinite and non-boundary observations" do
    ctx = Broker.journal!(clock: fn -> @day end)

    invalid = [
      fields("0"),
      fields("-1"),
      fields("NaN"),
      fields("Infinity"),
      %{fields() | currency: "EUR"},
      %{fields() | account: ""},
      %{fields() | day_start: DateTime.add(@day, 1)},
      %{fields() | request_started_at: DateTime.add(@day, -1)},
      %{fields() | observed_at: DateTime.add(@day, 60)},
      %{fields() | observed_at: DateTime.add(@day, -1)}
    ]

    for fields <- invalid do
      assert Journal.record_day_baseline(fields, ctx.journal) == {:error, :invalid_day_baseline}
    end

    assert Broker.records(ctx.path) == []
  end

  test "baseline timestamps never dispatch caller calendars inside the journal" do
    Process.register(self(), __MODULE__)
    ctx = Broker.journal!(clock: fn -> @day end)

    for key <- [:day_start, :request_started_at, :observed_at] do
      forged = Map.put(fields(), key, %{@day | calendar: CallerCalendar})
      assert Journal.record_day_baseline(forged, ctx.journal) == {:error, :invalid_day_baseline}
      refute_received :caller_calendar_ran
    end

    assert Journal.mode(ctx.journal) == {:ok, :disarmed, nil}
    assert Broker.records(ctx.path) == []
  end

  test "malformed ISO timestamps and oversized decimals cannot become a baseline" do
    ctx = Broker.journal!(clock: fn -> @day end)

    malformed = [
      %{@day | month: 13},
      %{@day | hour: 24},
      %{@day | microsecond: {1_000_000, 6}}
    ]

    for timestamp <- malformed, key <- [:day_start, :request_started_at, :observed_at] do
      assert Journal.record_day_baseline(Map.put(fields(), key, timestamp), ctx.journal) ==
               {:error, :invalid_day_baseline}
    end

    assert Journal.record_day_baseline(
             %{fields() | value: %Decimal{coef: 1, exp: 1_000_000}},
             ctx.journal
           ) ==
             {:error, :invalid_day_baseline}

    assert Broker.records(ctx.path) == []
  end

  test "recovery rejects malformed and duplicate baseline records despite a valid hash chain" do
    for extra <- [:duplicate, :negative, :oversized, :late, :missing] do
      fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})
      ctx = Broker.baseline_journal!(fake, @day)
      GenServer.stop(ctx.baseline.worker)
      GenServer.stop(ctx.journal)
      {:ok, record} = Codec.encode_day_baseline(fields(), @day)

      record =
        case extra do
          :duplicate -> record
          :negative -> Map.put(record, "value", "-1")
          :oversized -> Map.put(record, "value", "1E+1000000")
          :late -> Map.put(record, "observed_at", "2026-10-02T04:01:00Z")
          :missing -> Map.delete(record, "day_start")
        end

      {base, session} = Journal.location(ctx.path)
      {:ok, store} = FileStore.open(session, base_dir: base, chain: true)
      {:ok, [_offset]} = FileStore.append_many(store, [record], 5_000)
      :ok = FileStore.close(store)
      Broker.start_journal!(ctx.journal_opts)
      assert {:error, _reason} = Journal.status(ctx.journal)
      assert {:error, _reason} = Journal.day_baseline("FAKE-0001", @day, ctx.journal)
    end
  end

  test "damaged or unavailable journals never return a baseline" do
    fake = Fake.start(portfolio: %{"total_value" => "1000", "currency" => "USD"})
    ctx = Broker.baseline_journal!(fake, @day)
    Broker.flip_byte!(ctx.path)
    assert {:broken, _} = Journal.verify(ctx.journal)
    assert {:error, _} = Journal.day_baseline("FAKE-0001", @day, ctx.journal)
    GenServer.stop(ctx.journal)
    assert {:error, :journal_not_running} = Journal.day_baseline("FAKE-0001", @day, ctx.journal)
  end
end
