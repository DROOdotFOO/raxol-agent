defmodule Raxol.Agent.Test.Signal do
  @moduledoc """
  Waiting for a process the test started to reach a point, without a clock.

  `assert_receive msg, 100` bets that a freshly spawned process gets scheduled,
  loads the modules it calls and sends within 100ms. Under a loaded full suite
  it sometimes does not, and the test fails although nothing went wrong. The
  test can only end two ways: the process sends, or it exits first.
  `await/2` waits for whichever comes first and fails at once on the exit,
  giving the reason. A process that hangs is caught by ExUnit's per-test
  timeout.
  """

  import ExUnit.Assertions, only: [flunk: 1]

  @doc """
  Wait for `{tag, payload}` while `pid` is alive and return `payload`. Flunk if
  `pid` exits before that message arrives.

  The message can come from any process. `pid` is the one whose progress it
  depends on.
  """
  @spec await(pid(), atom()) :: term()
  def await(pid, tag) when is_pid(pid) and is_atom(tag) do
    ref = Process.monitor(pid)

    receive do
      {^tag, payload} ->
        Process.demonitor(ref, [:flush])
        payload

      {:DOWN, ^ref, :process, ^pid, reason} ->
        flunk("#{inspect(pid)} exited (#{inspect(reason)}) before #{inspect(tag)} arrived")
    end
  end

  @doc """
  Kill `pid` and return once it is dead, with the reason it exited for:
  `:killed`, or `:noproc` if it was already gone.

  A kill takes effect only when the target handles the signal, so how long
  that takes depends on scheduling. The `:DOWN` always comes, so this waits
  for it without a clock.
  """
  @spec kill(pid()) :: term()
  def kill(pid) when is_pid(pid) do
    ref = Process.monitor(pid)
    Process.exit(pid, :kill)

    receive do
      {:DOWN, ^ref, :process, ^pid, reason} -> reason
    end
  end
end
