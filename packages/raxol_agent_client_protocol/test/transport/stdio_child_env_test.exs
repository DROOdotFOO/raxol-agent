defmodule Raxol.AgentClientProtocol.Transport.StdioChildEnvTest do
  # Not async: these set node-wide variables (a bare `TOKEN`) and
  # `Raxol.Core.ChildEnv`'s application config, which every spawn reads.
  use ExUnit.Case, async: false

  alias Raxol.AgentClientProtocol.Transport.Stdio

  test "raxol_core's wider shapes are unset in the child" do
    suffix = System.unique_integer([:positive])
    names = ["ACP_STDIO_#{suffix}_DATABASE_URL", "ACP_STDIO_#{suffix}_API_KEYS", "TOKEN"]
    gap = "ACP_STDIO_#{suffix}_DSN"
    plain = "ACP_STDIO_#{suffix}_PLAIN"
    all = [gap, plain | names]

    previous = Map.new(all, &{&1, System.get_env(&1)})
    for name <- all, do: System.put_env(name, "v")

    on_exit(fn ->
      for {name, value} <- previous,
          do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
    end)

    format = Enum.map_join(all, ",", &~s("#{&1}":"%s"))
    args = Enum.map_join(all, " ", &~s("${#{&1}-unset}"))
    script = "printf '{#{format}}\\n' #{args}"

    {:ok, _transport} = Stdio.start_spawn("sh", ["-c", script], owner: self())
    assert_receive {:acp_transport, _ref, {:message, seen}}, 2_000

    for name <- [gap | names], do: assert(seen[name] == "unset", name)
    assert seen[plain] == "v"
  end

  describe "with a Raxol.Core.ChildEnv config" do
    setup do
      previous = Application.fetch_env(:raxol_core, Raxol.Core.ChildEnv)

      on_exit(fn ->
        case previous do
          {:ok, value} -> Application.put_env(:raxol_core, Raxol.Core.ChildEnv, value)
          :error -> Application.delete_env(:raxol_core, Raxol.Core.ChildEnv)
        end
      end)
    end

    test "Core's pass: is not honoured; extra_secrets: is" do
      suffix = System.unique_integer([:positive])
      passed = "ACP_STDIO_#{suffix}_TOKEN"
      passed_gap = "ACP_STDIO_#{suffix}_PASS"
      passed_plain = "ACP_STDIO_#{suffix}_PLAIN"
      extra = "ACP_STDIO_#{suffix}_WALLET"
      all = [passed, passed_gap, passed_plain, extra]

      Application.put_env(:raxol_core, Raxol.Core.ChildEnv,
        pass: [passed, passed_gap, passed_plain],
        extra_secrets: [extra]
      )

      seen = spawn_seen(all, [])

      for name <- all, do: assert(seen[name] == "unset", name)
      for name <- all, do: assert(Stdio.secret?(name), name)
    end

    # Core matches its named set case-insensitively and `pass:` exactly, so
    # passing `SSH_AUTH_SOCK` makes Core let `ssh_auth_sock` through too.
    test "a case variant of a Core-passed named secret is still unset" do
      Application.put_env(:raxol_core, Raxol.Core.ChildEnv, pass: ["SSH_AUTH_SOCK"])
      refute Raxol.Core.ChildEnv.secret?("ssh_auth_sock")

      previous = Map.new(~w(SSH_AUTH_SOCK ssh_auth_sock), &{&1, System.get_env(&1)})

      on_exit(fn ->
        for {name, value} <- previous,
            do: if(value, do: System.put_env(name, value), else: System.delete_env(name))
      end)

      seen = spawn_seen(~w(SSH_AUTH_SOCK ssh_auth_sock), [])

      assert seen["SSH_AUTH_SOCK"] == "unset"
      assert seen["ssh_auth_sock"] == "unset"
      assert Stdio.secret?("ssh_auth_sock")
    end

    test "precedence: :env, then :unset_env, then :pass, then the scrub" do
      suffix = System.unique_integer([:positive])
      given = "ACP_STDIO_#{suffix}_GIVEN_TOKEN"
      unset_and_passed = "ACP_STDIO_#{suffix}_BOTH_TOKEN"
      passed = "ACP_STDIO_#{suffix}_TOKEN"
      core_passed = "ACP_STDIO_#{suffix}_CORE_TOKEN"
      scrubbed = "ACP_STDIO_#{suffix}_API_KEY"
      all = [given, unset_and_passed, passed, core_passed, scrubbed]

      Application.put_env(:raxol_core, Raxol.Core.ChildEnv, pass: [core_passed])

      seen =
        spawn_seen(all,
          env: [{given, "given"}],
          unset_env: [given, unset_and_passed],
          pass: [given, unset_and_passed, passed, core_passed]
        )

      assert seen[given] == "given"
      assert seen[unset_and_passed] == "unset"
      assert seen[passed] == "v"
      assert seen[core_passed] == "v"
      assert seen[scrubbed] == "unset"

      refute Stdio.secret?(passed, pass: [passed])
      assert Stdio.secret?(passed)
    end

    test "malformed :pass and :unset_env raise in the caller" do
      for {key, value} <- [pass: "GH_TOKEN", pass: [:GH_TOKEN], unset_env: [nil]] do
        assert_raise ArgumentError, ~r/#{key} must be a list of strings/, fn ->
          Stdio.start_spawn("sh", ["-c", "true"], [{key, value}])
        end
      end
    end

    test "a malformed config raises in the caller" do
      Application.put_env(:raxol_core, Raxol.Core.ChildEnv, pas: ["GH_TOKEN"])

      assert_raise ArgumentError, ~r/unknown or repeated keys/, fn ->
        Stdio.start_spawn("sh", ["-c", "true"], owner: self())
      end

      # scrub_env: false reads no config.
      assert {:ok, _transport} =
               Stdio.start_spawn("sh", ["-c", "true"], owner: self(), scrub_env: false)
    end
  end

  # raxol_core is a `runtime: false` dependency: nothing starts it, and
  # `Raxol.Core.ChildEnv` reads only its application env, which
  # `Application.put_env/3` sets for an application that is not loaded.
  test "the scrub works while raxol_core is not started" do
    refute :raxol_core in Enum.map(Application.started_applications(), &elem(&1, 0))
    refute :mnesia in Enum.map(Application.started_applications(), &elem(&1, 0))

    assert Stdio.secret?("X_API_KEY")
    assert Stdio.secret?("RELEASE_COOKIE")
    refute Stdio.secret?("PATH")
  end

  # A release that leaves raxol_core out has no scrub to apply: spawning
  # must fail rather than hand the agent everything.
  test "the scrub fails closed when raxol_core's code is missing" do
    module = Raxol.Core.ChildEnv
    beam_dir = module |> :code.which() |> Path.dirname() |> String.to_charlist()

    :code.del_path(beam_dir)
    :code.purge(module)
    true = :code.delete(module)
    :code.purge(module)

    try do
      assert_raise RuntimeError, ~r/Raxol.Core.ChildEnv is not available/, fn ->
        Stdio.start_spawn("sh", ["-c", "true"], owner: self())
      end

      assert {:ok, _transport} =
               Stdio.start_spawn("sh", ["-c", "true"], owner: self(), scrub_env: false)
    after
      true = :code.add_patha(beam_dir)
      {:module, ^module} = Code.ensure_loaded(module)
    end
  end

  # Runs `sh` printing each of `names` (set to "v" in the node first) as the
  # child sees it, and returns that map.
  defp spawn_seen(names, opts) do
    for name <- names, do: System.put_env(name, "v")
    on_exit(fn -> for name <- names, do: System.delete_env(name) end)

    format = Enum.map_join(names, ",", &~s("#{&1}":"%s"))
    args = Enum.map_join(names, " ", &~s("${#{&1}-unset}"))
    script = "printf '{#{format}}\\n' #{args}"

    {:ok, _transport} = Stdio.start_spawn("sh", ["-c", script], [owner: self()] ++ opts)
    assert_receive {:acp_transport, _ref, {:message, seen}}, 2_000
    seen
  end
end
