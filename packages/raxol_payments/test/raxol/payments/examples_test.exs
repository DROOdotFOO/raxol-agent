defmodule Raxol.Payments.ExamplesTest do
  # Runs the offline examples the way `examples/README.md` tells a new user
  # to, as their own `mix run`: each script halts the VM when a step fails.
  use ExUnit.Case, async: true

  @package_root Path.expand("../../..", __DIR__)
  @offline_examples [
    "examples/agent_payment_tour.exs",
    "examples/privacy_modes.exs",
    "examples/crosschain_stealth_payment.exs"
  ]

  # A run reuses the suite's `_build/test`, so it takes seconds; the bound is
  # a hang detector with room for a cold CI runner, not a performance budget.
  # The child is killed at `@deadline`, before ExUnit's timeout, so a hang
  # fails with the script's output rather than ExUnit's stack dump.
  @deadline :timer.minutes(4)
  @moduletag timeout: :timer.minutes(5)

  for example <- @offline_examples do
    test "#{example} runs offline and exits 0" do
      mix = System.find_executable("mix")

      case run(mix, ["run", unquote(example)], @deadline) do
        {:exited, 0, _output} ->
          :ok

        {:exited, status, output} ->
          flunk("#{unquote(example)} exited #{status}:\n\n#{output}")

        {:killed, output} ->
          flunk("#{unquote(example)} hung past #{@deadline} ms and was killed:\n\n#{output}")
      end
    end
  end

  # The one script that takes a user's key, run without one and with no
  # server: the target is a loopback port closed a moment ago, so no 402
  # arrives and nothing is signed. This pins today's behaviour, exit status
  # included; it does not endorse it.
  test "examples/preflight.exs without a key warns, mints a throwaway one, and stops at the target" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    env = [
      {"PREFLIGHT_TARGET_URL", "http://127.0.0.1:#{port}/anything"},
      {"PREFLIGHT_WALLET_KEY", false},
      {"PREFLIGHT_AUTO_APPROVE", false}
    ]

    mix = System.find_executable("mix")

    assert {:exited, 0, output} =
             run(mix, ["run", "examples/preflight.exs"], @deadline, env: env)

    assert output =~ "[warn] PREFLIGHT_WALLET_KEY not set; generating ephemeral dev key"
    assert output =~ "target:   http://127.0.0.1:#{port}/anything"
    assert output =~ "[error] %Req.TransportError{reason: :econnrefused}"
    refute output =~ "[ok]"
  end

  test "a child that hangs is killed, not left running after the test" do
    sleep = System.find_executable("sleep")

    test_pid = self()

    assert {:killed, _output} =
             run(sleep, ["600"], 200, on_spawn: &send(test_pid, {:child, &1}))

    assert_received {:child, os_pid}
    refute alive?(os_pid)
  end

  # `System.cmd/3` cannot stop its child: a `mix run` VM does not read stdin,
  # so closing the port when ExUnit kills the test leaves the VM running. The
  # port's OS pid is the VM (`env`, `elixir` and `erl` each `exec` the next),
  # and it is killed here on a deadline and in `on_exit/1`, which ExUnit runs
  # after a test exits for any reason, its own timeout included.
  #
  # `:env` adds to the child's environment; a `false` value removes the
  # variable. `:on_spawn` is called with the child's OS pid.
  defp run(executable, args, deadline, opts \\ []) do
    env =
      for {name, value} <- [{"MIX_ENV", "test"} | Keyword.get(opts, :env, [])],
          do: env(name, value)

    port =
      Port.open({:spawn_executable, executable}, [
        :binary,
        :exit_status,
        :stderr_to_stdout,
        args: args,
        cd: @package_root,
        env: env
      ])

    {:os_pid, os_pid} = Port.info(port, :os_pid)
    on_exit(fn -> kill(os_pid) end)
    Keyword.get(opts, :on_spawn, fn _os_pid -> :ok end).(os_pid)

    collect(port, os_pid, System.monotonic_time(:millisecond) + deadline, [])
  end

  defp env(name, false), do: {String.to_charlist(name), false}
  defp env(name, value), do: {String.to_charlist(name), String.to_charlist(value)}

  defp collect(port, os_pid, deadline_at, output) do
    remaining = max(deadline_at - System.monotonic_time(:millisecond), 0)

    receive do
      {^port, {:data, data}} ->
        collect(port, os_pid, deadline_at, [output | data])

      {^port, {:exit_status, status}} ->
        {:exited, status, IO.iodata_to_binary(output)}
    after
      remaining ->
        kill(os_pid)
        {:killed, IO.iodata_to_binary(output)}
    end
  end

  # Already gone is the usual case, so the result is not checked.
  defp kill(os_pid),
    do: System.cmd("kill", ["-KILL", Integer.to_string(os_pid)], stderr_to_stdout: true)

  # Polled briefly, because the kernel reaps the child just after the signal.
  defp alive?(os_pid, tries \\ 20)
  defp alive?(os_pid, 0), do: signalable?(os_pid)

  defp alive?(os_pid, tries) do
    if signalable?(os_pid) do
      Process.sleep(25)
      alive?(os_pid, tries - 1)
    else
      false
    end
  end

  defp signalable?(os_pid) do
    {_out, status} = System.cmd("kill", ["-0", Integer.to_string(os_pid)], stderr_to_stdout: true)
    status == 0
  end
end
