# `:telemetry` reaches this package only through raxol_core, which is a
# `runtime: false` dependency, so nothing starts it. Every emit site in `lib/`
# is `Code.ensure_loaded?(:telemetry)`-guarded; the suite starts it so
# `Raxol.AgentClientProtocol.Test.InvariantSentinel` and the D9 handlers
# observe real events.
{:ok, _} = Application.ensure_all_started(:telemetry)

# The suite passes real messages between processes; a 1s assert_receive
# default keeps a slow CI host from reading late as missing.
ExUnit.configure(assert_receive_timeout: 1_000)
ExUnit.start()
