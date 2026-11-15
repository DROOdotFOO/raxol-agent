# Kill-to-all-cancelled latency

`bench/kill_latency.exs` against `Raxol.Broker.MCP.Fake`, which answers in
process: this is the broker's own overhead (disarm, listing, one journaled
group per cancel, the parallel cancel calls, the `halt` record), with no
network latency.

    MIX_ENV=test mix run bench/kill_latency.exs 5 20
    MIX_ENV=test mix run bench/kill_latency.exs 20 10

Measured 2026-11-15 on an Apple M1 (8 GB), Elixir 1.20.2, OTP 29:

| Open orders | Runs | Min | Median | Max |
| --- | --- | --- | --- | --- |
| 5 | 20 | 1.9 ms | 2.3 ms | 7.3 ms |
| 20 | 10 | 7.2 ms | 8.7 ms | 9.1 ms |

Against Robinhood each cancel adds a round trip, sent in parallel, so the
live figure is roughly this plus the slowest single cancel; the live soak
records it.
