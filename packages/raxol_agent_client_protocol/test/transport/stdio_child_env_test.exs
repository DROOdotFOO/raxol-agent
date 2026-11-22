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

    test "pass: and extra_secrets: apply to the child" do
      suffix = System.unique_integer([:positive])
      passed = "ACP_STDIO_#{suffix}_TOKEN"
      passed_gap = "ACP_STDIO_#{suffix}_PASS"
      extra = "ACP_STDIO_#{suffix}_WALLET"
      all = [passed, passed_gap, extra]

      Application.put_env(:raxol_core, Raxol.Core.ChildEnv,
        pass: [passed, passed_gap],
        extra_secrets: [extra]
      )

      for name <- all, do: System.put_env(name, "v")
      on_exit(fn -> for name <- all, do: System.delete_env(name) end)

      format = Enum.map_join(all, ",", &~s("#{&1}":"%s"))
      args = Enum.map_join(all, " ", &~s("${#{&1}-unset}"))
      script = "printf '{#{format}}\\n' #{args}"

      {:ok, _transport} = Stdio.start_spawn("sh", ["-c", script], owner: self())
      assert_receive {:acp_transport, _ref, {:message, seen}}, 2_000

      assert seen[passed] == "v"
      assert seen[passed_gap] == "v"
      assert seen[extra] == "unset"
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
end
