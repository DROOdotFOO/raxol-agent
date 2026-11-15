defmodule Mix.Tasks.Raxol.Broker.ArmTest do
  @moduledoc """
  The arm, disarm and connect tasks with the broker running in this VM: the
  journal and the read-only client are registered under their default
  names, the client on the Fake.
  """
  use ExUnit.Case, async: false

  alias Mix.Tasks.Raxol.Broker.{Arm, Connect, Disarm}
  alias Raxol.Broker.{Journal, Mode}
  alias Raxol.Broker.MCP.{Client, Fake}
  alias Raxol.Broker.Test.Broker

  @moduletag :capture_log

  setup do
    previous_shell = Mix.shell()
    Mix.shell(Mix.Shell.Process)
    on_exit(fn -> Mix.shell(previous_shell) end)

    ctx = Broker.journal!(name: Journal)
    fake = Fake.start(quotes: %{"F" => "9.80"})
    start_supervised!({Client, Fake.client_opts(fake, name: Client)})
    Map.put(ctx, :policy, Broker.policy_file!(ctx.base))
  end

  defp lines do
    receive do
      {:mix_shell, :info, [line]} -> [line | lines()]
    after
      0 -> []
    end
  end

  test "arm asks for ARM after printing its checks; disarm undoes it", ctx do
    send(self(), {:mix_shell_input, :prompt, "ARM\n"})
    Arm.run(["--policy", ctx.policy, "--account", "FAKE-0001"])

    assert_received {:mix_shell, :prompt, ["Type ARM to place real orders:"]}
    printed = lines()
    assert "account FAKE-0001 is the agentic account" in printed

    assert "trade approvals in the Robinhood app: OFF (human_must_approve_trades: false)" in printed

    assert "armed" in printed
    assert Mode.current(Journal) == :armed
    assert {:ok, :armed, %{"human_must_approve_trades" => false}} = Journal.mode(Journal)

    Disarm.run(["--reason", "test"])
    assert lines() == ["disarmed"]
    assert Mode.current(Journal) == :disarmed
  end

  test "arm without the typed confirmation fails and writes nothing", ctx do
    send(self(), {:mix_shell_input, :prompt, "yes\n"})

    assert_raise Mix.Error, ~r/confirmation not typed/, fn ->
      Arm.run(["--policy", ctx.policy, "--account", "FAKE-0001"])
    end

    assert Journal.mode(Journal) == {:ok, :disarmed, nil}
  end

  test "arm refuses an account that is not the agentic one", ctx do
    assert_raise Mix.Error, ~r/not_the_agentic_account/, fn ->
      Arm.run(["--policy", ctx.policy, "--account", "OTHER-1"])
    end

    assert Journal.mode(Journal) == {:ok, :disarmed, nil}
  end

  test "connect before init exits naming the policy file", ctx do
    missing = Path.join(ctx.base, "broker.policy.exs")

    assert_raise Mix.Error, ~r/#{Regex.escape(missing)} does not load/, fn ->
      Connect.run(["--policy", missing])
    end
  end
end
