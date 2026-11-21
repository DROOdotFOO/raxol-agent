defmodule Raxol.Agent.ChildEnvTest do
  # Mutates the node's environment.
  use ExUnit.Case, async: false

  alias Raxol.Agent.ChildEnv

  @vars ~w(CHILD_ENV_TEST_API_KEY CHILD_ENV_TEST_TOKEN CHILD_ENV_TEST_PRIVATE_KEY
           CHILD_ENV_TEST_SECRET CHILD_ENV_TEST_RPC_URL CHILD_ENV_TEST_RPC_8453
           CHILD_ENV_TEST_PLAIN)

  setup do
    for name <- @vars, do: System.put_env(name, "v")
    on_exit(fn -> for name <- @vars, do: System.delete_env(name) end)
  end

  test "secret?/1 matches the credential patterns and the explicit names" do
    for name <- @vars -- ["CHILD_ENV_TEST_PLAIN"], do: assert(ChildEnv.secret?(name), name)
    refute ChildEnv.secret?("CHILD_ENV_TEST_PLAIN")
    refute ChildEnv.secret?("PATH")

    for name <-
          ~w(ANTHROPIC_API_KEY PROTON_ACCESS_TOKEN PROTON_UID ORDER_KEY RAXOL_WALLET_KEY
             AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY GH_TOKEN RPC_ETH RPC_BASE RPC_ROBINHOOD
             BASE_RPC_URL ORDER_RPC_8453 my_api_key WALLET_MNEMONIC MAINNET_RPC
             ALCHEMY_APIKEY DB_PASS SENTRY_DSN SSH_AUTH_SOCK OP_SESSION_my MNEMONIC),
        do: assert(ChildEnv.secret?(name), name)

    for name <- ~w(PATH HOME GRPC_TRACE KEYBOARD TOKENIZERS_PARALLELISM),
        do: refute(ChildEnv.secret?(name), name)
  end

  # `Raxol.AgentClientProtocol.Transport.Stdio` carries its own copy of the
  # credential pattern: the two must be the same regex, and a variable it
  # lets through must be one this module lets through too.
  test "the ACP stdio transport's credential pattern is this module's" do
    acp = Raxol.AgentClientProtocol.Transport.Stdio.credential_pattern()
    ours = ChildEnv.credential_pattern()
    assert Regex.source(acp) == Regex.source(ours)
    assert Regex.opts(acp) == Regex.opts(ours)
  end

  test "the ACP stdio transport scrubs the same credential names" do
    names =
      ~w(CHILD_ENV_ACP_API_KEY CHILD_ENV_ACP_KEY_ID CHILD_ENV_ACP_TOKEN CHILD_ENV_ACP_PRIVKEY
         CHILD_ENV_ACP_SECRET CHILD_ENV_ACP_PASSWORD CHILD_ENV_ACP_PASSPHRASE
         CHILD_ENV_ACP_MNEMONIC CHILD_ENV_ACP_CREDENTIALS RPC_CHILD_ENV_ACP CHILD_ENV_ACP_RPC_URL
         child_env_acp_token CHILD_ENV_ACP_PLAIN)

    for name <- names, do: System.put_env(name, "v")
    on_exit(fn -> for name <- names, do: System.delete_env(name) end)

    format = Enum.map_join(names, ",", &~s("#{&1}":"%s"))
    args = Enum.map_join(names, " ", &~s("${#{&1}-unset}"))
    script = "printf '{#{format}}\\n' #{args}"

    {:ok, _transport} =
      Raxol.AgentClientProtocol.Transport.Stdio.start_spawn("sh", ["-c", script], owner: self())

    assert_receive {:acp_transport, _ref, {:message, seen}}, 2_000

    for name <- names do
      assert seen[name] == if(ChildEnv.secret?(name), do: "unset", else: "v"), name
    end
  end

  test "port_env/1 unsets credentials the caller did not name" do
    env = ChildEnv.port_env([{"CHILD_ENV_TEST_TOKEN", "given"}])
    unset = for {name, false} <- env, do: to_string(name)

    assert {~c"CHILD_ENV_TEST_TOKEN", ~c"given"} in env
    assert "CHILD_ENV_TEST_API_KEY" in unset
    assert "CHILD_ENV_TEST_RPC_8453" in unset
    assert "ANTHROPIC_API_KEY" in unset
    assert "RAXOL_WALLET_KEY" in unset
    refute "CHILD_ENV_TEST_TOKEN" in unset
    refute "CHILD_ENV_TEST_PLAIN" in unset
    assert length(env) == length(Enum.uniq_by(env, &elem(&1, 0)))
  end

  test "cmd_env/1 uses nil as the unset marker" do
    env = ChildEnv.cmd_env([])
    assert {"CHILD_ENV_TEST_SECRET", nil} in env
    refute List.keymember?(env, "CHILD_ENV_TEST_PLAIN", 0)
  end

  test "a spawned shell cannot read a scrubbed variable" do
    port =
      Port.open({:spawn_executable, "/bin/sh"}, [
        :binary,
        :exit_status,
        args: ["-c", ~s(printf '%s,%s' "${CHILD_ENV_TEST_API_KEY-unset}" "$CHILD_ENV_TEST_PLAIN")],
        env: ChildEnv.port_env()
      ])

    assert_receive {^port, {:data, "unset,v"}}, 2_000
  end

  test "the core pass: list lets a name through" do
    previous = Application.get_env(:raxol_core, Raxol.Core.ChildEnv)
    Application.put_env(:raxol_core, Raxol.Core.ChildEnv, pass: ["CHILD_ENV_TEST_API_KEY"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:raxol_core, Raxol.Core.ChildEnv, previous),
        else: Application.delete_env(:raxol_core, Raxol.Core.ChildEnv)
    end)

    refute {~c"CHILD_ENV_TEST_API_KEY", false} in ChildEnv.port_env()
  end
end
