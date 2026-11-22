defmodule Raxol.Agent.Test.SignalTest do
  @moduledoc """
  The helper that replaces clock-bound waits: a wait that could never fail
  would hide a process that died before signalling.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Test.Signal

  describe "await/2" do
    test "returns the payload of the tagged message" do
      parent = self()
      pid = spawn(fn -> send(parent, {:ready, :payload}) end)

      assert Signal.await(pid, :ready) == :payload
    end

    test "returns a message sent before the process exited" do
      parent = self()
      {pid, ref} = spawn_monitor(fn -> send(parent, {:ready, 1}) end)
      receive do: ({:DOWN, ^ref, :process, ^pid, :normal} -> :ok)

      assert Signal.await(pid, :ready) == 1
    end

    # Waited out first, so the process is gone before `await/2` monitors it:
    # an exit while it waits would race the monitor and report either reason.
    test "flunks when the process exits without signalling" do
      {pid, ref} = spawn_monitor(fn -> exit(:gave_up) end)
      receive do: ({:DOWN, ^ref, :process, ^pid, :gave_up} -> :ok)

      error = assert_raise ExUnit.AssertionError, fn -> Signal.await(pid, :ready) end
      assert error.message =~ ":noproc"
      assert error.message =~ ":ready"
    end

    test "leaves no monitor message behind" do
      parent = self()
      pid = spawn(fn -> send(parent, {:ready, nil}) end)

      Signal.await(pid, :ready)
      refute_received {:DOWN, _ref, :process, ^pid, _reason}
    end
  end

  describe "kill/1" do
    test "returns once the process is dead" do
      pid = spawn(fn -> Process.sleep(:infinity) end)

      assert Signal.kill(pid) == :killed
      refute Process.alive?(pid)
    end

    test "returns :noproc for a process that is already gone" do
      {pid, ref} = spawn_monitor(fn -> :ok end)
      receive do: ({:DOWN, ^ref, :process, ^pid, :normal} -> :ok)

      assert Signal.kill(pid) == :noproc
    end
  end
end
