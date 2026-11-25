defmodule Mix.Tasks.Raxol.Broker.StrategyTest do
  use ExUnit.Case, async: false

  alias Mix.Tasks.Raxol.Broker.Strategy, as: Task
  alias Raxol.Broker.Journal

  @moduletag :capture_log

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    base = Path.join(System.tmp_dir!(), "broker-strategy-#{System.unique_integer([:positive])}")
    File.mkdir_p!(base)

    on_exit(fn ->
      Mix.shell(previous_shell)
      File.rm_rf!(base)
    end)

    {:ok, path: Path.join(base, "journal")}
  end

  defp lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | lines()]
    after
      0 -> []
    end
  end

  test "add, list and stop write the journal when no broker runs here", %{path: path} do
    Task.run(~w(add dip_buy --symbol f --usd 25 --journal #{path}))
    assert lines() == ["added dip_buy-F (dip_buy symbol=f usd=25)"]

    Task.run(~w(list --journal #{path}))
    assert lines() == ["dip_buy-F  dip_buy  symbol=f usd=25  stopped"]

    Task.run(~w(stop dip_buy-F --journal #{path}))
    assert lines() == ["stopped dip_buy-F"]

    Task.run(~w(list --journal #{path}))
    assert lines() == ["no strategies"]
    refute Process.whereis(Journal)
  end

  test "an unknown strategy or bad parameter is refused", %{path: path} do
    assert_raise Mix.Error, ~r/unknown strategy nope/, fn ->
      Task.run(~w(add nope --journal #{path}))
    end

    assert_raise Mix.Error, ~r/invalid_param/, fn ->
      Task.run(~w(add dip_buy --symbol F --usd 0 --journal #{path}))
    end
  end
end
