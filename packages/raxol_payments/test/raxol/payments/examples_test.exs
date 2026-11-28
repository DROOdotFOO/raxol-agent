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

  # The README runs the examples as `mix run`, the dev environment, while the
  # tests above run them under `test`, where `test/support` is compiled in.
  # The one thing that separates the two for an example is a test-only
  # module, so this fails when an example names one: the suite would
  # otherwise stay green while a new user's first command does not compile.
  # A check rather than a second run under dev, which on a cold CI runner
  # would compile a second dependency tree inside the deadline.
  test "no example names a module that only the test environment compiles" do
    support = test_support_modules()
    assert support != [], "found no test/support modules to check against"

    for example <- Path.wildcard(Path.join(@package_root, "examples/*.exs")) do
      named = for ref <- aliases_in(example), module <- support, suffix?(module, ref), do: module

      assert named == [],
             "#{Path.relative_to(example, @package_root)} names test-only " <>
               "#{inspect(Enum.uniq(named))}; `mix run` outside MIX_ENV=test cannot load it"
    end
  end

  defp test_support_modules do
    for module <- Application.spec(:raxol_payments, :modules),
        source = module.module_info(:compile)[:source],
        String.contains?(to_string(source), "/test/support/"),
        do: module
  end

  # Every alias the script spells, with `alias A.{B, C.D}` expanded, as a list
  # of segments. An alias used after `alias X.Y` is spelled from `Y`, so a
  # reference matches a module it is a trailing part of.
  defp aliases_in(path) do
    {:ok, ast} = path |> File.read!() |> Code.string_to_quoted()

    {_ast, refs} =
      Macro.prewalk(ast, [], fn
        {{:., _, [{:__aliases__, _, base}, :{}]}, _, children} = node, refs ->
          {node, for({:__aliases__, _, parts} <- children, do: base ++ parts) ++ refs}

        {:__aliases__, _, parts} = node, refs when is_list(parts) ->
          {node, [parts | refs]}

        node, refs ->
          {node, refs}
      end)

    Enum.uniq(refs)
  end

  defp suffix?(module, ref) do
    parts = module |> Module.split() |> Enum.map(&String.to_atom/1)
    ref != [] and Enum.all?(ref, &is_atom/1) and List.ends_with?(parts, ref)
  end

  # The one script that takes a user's key, run without one and with no
  # server: the target is a loopback port closed a moment ago, so no 402
  # arrives and nothing is signed.
  test "examples/preflight.exs without a key warns, mints a throwaway one, and fails at the target" do
    {:ok, socket} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(socket)
    :ok = :gen_tcp.close(socket)

    env = [
      {"PREFLIGHT_TARGET_URL", "http://127.0.0.1:#{port}/anything"},
      {"PREFLIGHT_WALLET_KEY", false},
      {"PREFLIGHT_AUTO_APPROVE", false}
    ]

    mix = System.find_executable("mix")

    target = "http://127.0.0.1:#{port}/anything"

    assert {:exited, 1, output} =
             run(mix, ["run", "examples/preflight.exs"], @deadline, env: env)

    assert output =~ "[warn] PREFLIGHT_WALLET_KEY not set; generating ephemeral dev key"
    assert output =~ "target:   #{target}"
    assert output =~ "[error] cannot reach #{target}: connection refused\n"
    refute output =~ "%Req."
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
