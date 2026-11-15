defmodule Raxol.Broker.HaltRequestTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.{Executor, HaltRequest, Intent, Journal, Mode}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  test "a halt marker blocks sending before the worker polls" do
    ctx = Broker.journal!()
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    :ok = HaltRequest.request(ctx.path)
    assert Mode.current(ctx.journal) == :disarmed
    assert Journal.mode(ctx.journal) == {:error, :halt_requested}
    assert Bitwise.band(File.stat!(HaltRequest.path(ctx.path)).mode, 0o777) == 0o600
  end

  test "a second OS process requests a kill despite the journal writer lock" do
    ctx = Broker.journal!()
    fake = Fake.start()
    executor = Broker.executor!(ctx.journal, fake)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    {:ok, intent} = Intent.limit(:buy, "AAPL", Broker.d("1"), Broker.d("125"), provenance: :human)
    assert {:ok, %{status: :placed}} = Executor.run(executor, intent, %Context{})

    worker =
      start_supervised!(
        {HaltRequest,
         path: ctx.path, journal: ctx.journal, executor: executor, strategies: :no_strategies}
      )

    :erlang.trace(worker, true, [:receive])

    {output, status} =
      System.cmd("mix", ["raxol.broker.kill", "--journal", ctx.path], stderr_to_stdout: true)

    assert status == 0, output
    assert output =~ "halt requested"
    assert Mode.current(ctx.journal) == :disarmed

    assert_receive {:trace, ^worker, :receive, {:halt_result, _, {:ok, summary}}}, 5_000
    assert [%{outcome: "placed"}] = summary.results
    :sys.get_state(worker)
    assert [%{"state" => "cancelled"}] = Fake.orders(fake)
  end

  test "symlinks, shared directories and nonprivate markers are refused" do
    ctx = Broker.journal!()
    marker = HaltRequest.path(ctx.path)
    target = Path.join(ctx.base, "unrelated")
    File.write!(target, "not a halt")
    File.ln_s!(target, marker)
    assert {:error, :untrusted_halt_request} = HaltRequest.request(ctx.path)
    assert File.read!(target) == "not a halt"
    File.rm!(marker)

    File.write!(marker, "")
    File.chmod!(marker, 0o644)
    assert {:error, :untrusted_halt_request} = HaltRequest.request(ctx.path)
    File.rm!(marker)

    File.chmod!(ctx.path, 0o770)
    assert {:error, :untrusted_halt_directory} = HaltRequest.request(ctx.path)
    refute File.exists?(marker)
  end
end
