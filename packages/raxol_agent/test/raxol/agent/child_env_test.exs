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

  test "secret?/1 covers Core's shapes, in any case" do
    for name <- ~w(DATABASE_URL REDIS_URL PGPASSWORD API_KEYS SECRET_KEY_BASE RELEASE_COOKIE
                   SMTP_PASS SENTRY_DSN WALLET_SEED_PHRASE SEED_PHRASE OP_SESSION_abc
                   smtp_pass x_dsn seed_phrase op_session_x proton_uid Order_Bundler_Url),
        do: assert(ChildEnv.secret?(name), name)
  end

  # raxol_core 2.9.1's pattern, pinned (in ACP's `stdio_test.exs` too): a
  # release that changes it fails here, before it can narrow what shells
  # inherit.
  test "Core's credential pattern is the 2.9.1 one" do
    core = Raxol.Core.ChildEnv.credential_pattern()

    # Whitespace is insignificant in an `x` regex.
    assert String.replace(Regex.source(core), ~r/\s+/, "") ==
             ~S"(\A|_)(APIKEYS?|KEYS?|PRIVKEY|PRIVATEKEY|TOKENS?|SECRETS?|CLIENTSECRET|AUTHTOKEN|AUTHKEY" <>
               ~S"|APITOKEN|ACCESSTOKEN|CREDENTIALS?|DSN|PAT|CONNECTION_STRING|PASSWORD|PASSWD" <>
               ~S"|PASSPHRASE|PASS|MNEMONICS?|SEEDPHRASE|SEED_PHRASE|(WALLET|MASTER|HD|TOTP)_SEED)" <>
               ~S"(_|\d|\z)" <>
               ~S"|(\A|_)PK\d*\z|_PWD(_|\d|\z)|WEBHOOK|\AOP_SESSION_|(\A|_)(BW|LPASS)_SESSION(_|\z)" <>
               ~S"|(\A|_)(DATABASE|POSTGRES|POSTGRESQL|MYSQL|MARIADB|MSSQL|REDIS|REDISCLOUD|REDISTOGO" <>
               ~S"|VALKEY|MEMCACHED|MONGO|MONGODB|AMQP|AMQPS|CLOUDAMQP|RABBITMQ|ELASTICSEARCH" <>
               ~S"|OPENSEARCH|CLICKHOUSE|COUCHDB|MONGOHQ|MONGOLAB)(_\w+)?_UR[LI]" <>
               ~S"|(\A|_)(DB|PG|BROKER|SMTP|MAIL|EMAIL)_UR[LI]|(\A|_)PG\w*PASSWORD|(?<!G)RPC"

    assert Enum.sort(Regex.opts(core)) == [:caseless, :extended]
  end

  # Before raxol_core 2.9.1 this module added these shapes on top of Core.
  # Every name they matched must still be denied by Core alone.
  test "every name the removed gap pattern covered is still denied" do
    removed_gaps = ~r/(_PASS|_SEED_PHRASE|_DSN)\z|\ASEED_PHRASE\z|\AOP_SESSION_/i

    names =
      for prefix <- ["X_", "MY_APP_", "A1_", "x_", "my_app_"],
          stem <- ~w(PASS SEED_PHRASE DSN WALLET_SEED_PHRASE SMTP_PASS SENTRY_DSN),
          name = prefix <> stem,
          variant <- [name, String.downcase(name)],
          do: variant

    names =
      names ++
        ~w(SEED_PHRASE seed_phrase Seed_Phrase OP_SESSION_ OP_SESSION_me op_session_x
           OP_SESSION_my_team_1 Op_Session_abc)

    covered = Enum.filter(names, &Regex.match?(removed_gaps, &1))
    assert length(covered) == length(names)

    for name <- covered do
      assert Raxol.Core.ChildEnv.secret?(name), name
      assert ChildEnv.secret?(name), name
    end
  end

  # `Raxol.AgentClientProtocol.Transport.Stdio` applies Core's scrub too, so
  # this mostly guards against the two diverging in how they apply `pass:` or
  # case. The concrete-name test above is the one independent of the regex.
  test "every name the ACP stdio transport denies is denied here" do
    corpus =
      for prefix <- ["", "X_", "MY_APP_", "x_"],
          suffix <-
            ~w(KEY KEY_ID KEYS APIKEY TOKEN TOKENS PRIVKEY SECRET PASSWORD PASSWD PASS
               PASSPHRASE MNEMONIC SEED_PHRASE CREDENTIALS DSN RPC DATABASE_URL REDIS_URI),
          name = prefix <> "A_" <> suffix,
          variant <- [name, String.downcase(name)],
          do: variant

    extra =
      ~w(RPC_BASE BASE_RPC_URL X_RPC_Y MNEMONIC SEED_PHRASE SSH_AUTH_SOCK OP_SESSION_me
         PGPASSWORD SECRET_KEY_BASE RELEASE_COOKIE TOKEN mnemonic seed_phrase ssh_auth_sock
         op_session_me rpc_base release_cookie)

    denied = Enum.filter(corpus ++ extra, &Raxol.AgentClientProtocol.Transport.Stdio.secret?/1)
    assert length(denied) == length(corpus ++ extra)

    for name <- denied, do: assert(ChildEnv.secret?(name), name)
  end

  test "names the ACP stdio transport unsets are denied here too" do
    names =
      ~w(CHILD_ENV_ACP_API_KEY CHILD_ENV_ACP_KEY_ID CHILD_ENV_ACP_TOKEN CHILD_ENV_ACP_PRIVKEY
         CHILD_ENV_ACP_SECRET CHILD_ENV_ACP_PASSWORD CHILD_ENV_ACP_PASSPHRASE
         CHILD_ENV_ACP_MNEMONIC CHILD_ENV_ACP_CREDENTIALS RPC_CHILD_ENV_ACP CHILD_ENV_ACP_RPC_URL
         child_env_acp_token CHILD_ENV_ACP_PASS CHILD_ENV_ACP_DSN CHILD_ENV_ACP_SEED_PHRASE
         OP_SESSION_child_env_acp CHILD_ENV_ACP_PLAIN)

    for name <- names, do: System.put_env(name, "v")
    on_exit(fn -> for name <- names, do: System.delete_env(name) end)

    format = Enum.map_join(names, ",", &~s("#{&1}":"%s"))
    args = Enum.map_join(names, " ", &~s("${#{&1}-unset}"))
    script = "printf '{#{format}}\\n' #{args}"

    {:ok, _transport} =
      Raxol.AgentClientProtocol.Transport.Stdio.start_spawn("sh", ["-c", script], owner: self())

    assert_receive {:acp_transport, _ref, {:message, seen}}, 2_000

    for name <- names -- ["CHILD_ENV_ACP_PLAIN"] do
      assert seen[name] == "unset", name
      assert ChildEnv.secret?(name), name
    end

    assert seen["CHILD_ENV_ACP_PLAIN"] == "v"
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

  test "unset_names/0 lists the named set and the denied variables set now" do
    names = ChildEnv.unset_names()
    assert "PROTON_UID" in names
    assert "CHILD_ENV_TEST_API_KEY" in names
    refute "CHILD_ENV_TEST_PLAIN" in names
  end

  test "a gap-shaped variable set in the node is unset" do
    System.put_env("CHILD_ENV_TEST_DSN", "v")
    on_exit(fn -> System.delete_env("CHILD_ENV_TEST_DSN") end)

    assert {~c"CHILD_ENV_TEST_DSN", false} in ChildEnv.port_env()
    assert {"CHILD_ENV_TEST_DSN", nil} in ChildEnv.cmd_env()
  end

  test "the core pass: list lets a name through" do
    previous = Application.get_env(:raxol_core, Raxol.Core.ChildEnv)

    Application.put_env(:raxol_core, Raxol.Core.ChildEnv,
      pass: ["CHILD_ENV_TEST_API_KEY", "PROTON_UID", "SENTRY_DSN"]
    )

    on_exit(fn ->
      if previous,
        do: Application.put_env(:raxol_core, Raxol.Core.ChildEnv, previous),
        else: Application.delete_env(:raxol_core, Raxol.Core.ChildEnv)
    end)

    env = ChildEnv.port_env()
    refute {~c"CHILD_ENV_TEST_API_KEY", false} in env
    refute {~c"PROTON_UID", false} in env
    refute "PROTON_UID" in ChildEnv.secrets()
    refute ChildEnv.secret?("SENTRY_DSN")
    refute ChildEnv.secret?("CHILD_ENV_TEST_API_KEY")
  end

  test "a malformed core config raises rather than scrubbing less" do
    previous = Application.get_env(:raxol_core, Raxol.Core.ChildEnv)
    Application.put_env(:raxol_core, Raxol.Core.ChildEnv, pas: ["X"])

    on_exit(fn ->
      if previous,
        do: Application.put_env(:raxol_core, Raxol.Core.ChildEnv, previous),
        else: Application.delete_env(:raxol_core, Raxol.Core.ChildEnv)
    end)

    assert_raise ArgumentError, fn -> ChildEnv.port_env() end
    assert_raise ArgumentError, fn -> ChildEnv.secret?("X") end
  end
end
