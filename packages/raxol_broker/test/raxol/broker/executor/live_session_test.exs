defmodule Raxol.Broker.Executor.LiveSessionTest do
  @moduledoc """
  The executor's session built from the stored credential, against the Fake
  behind its bearer gate and the recorded token endpoint.
  """
  use ExUnit.Case, async: true

  alias Raxol.Agent.Auth.Credential
  alias Raxol.Broker.{CredentialStore, Executor, Intent, Journal, Session}
  alias Raxol.Broker.MCP.Fake
  alias Raxol.Broker.Policy.Context
  alias Raxol.Broker.Test.{AuthServer, Broker, Fixtures, MemoryKeys}

  @moduletag :capture_log

  setup do
    ctx = Broker.journal!()
    token = Fixtures.load("token_response")
    refreshed = Fixtures.load("refresh_response")
    auth = AuthServer.start()

    store = [
      path: Path.join(ctx.base, "robinhood.credential"),
      key_provider: {MemoryKeys, agent: MemoryKeys.start()}
    ]

    credential = %Credential{
      provider: :robinhood,
      issuer: "https://agent.robinhood.com/mcp/trading",
      client_id: Fixtures.load("registration_response")["client_id"],
      access_token: token["access_token"],
      refresh_token: token["refresh_token"],
      expires_at: DateTime.add(DateTime.utc_now(), 810_101, :second)
    }

    :ok = CredentialStore.put(credential, store)
    AuthServer.issue_refresh(auth, token["refresh_token"])

    Map.merge(ctx, %{
      token: token,
      refreshed: refreshed,
      auth: auth,
      store: store,
      fake: Fake.start(accept: [token["access_token"]], quotes: %{"AAPL" => "125"})
    })
  end

  defp executor!(ctx) do
    Broker.executor!(ctx.journal, ctx.fake,
      mode: :live,
      session: Fake.session(ctx.fake),
      credential: [store: ctx.store, auth: [http_fn: AuthServer.http_fn(ctx.auth)]]
    )
  end

  defp place!(executor, id) do
    {:ok, intent} =
      Intent.limit(:buy, "AAPL", Decimal.new("1"), Decimal.new("125"), provenance: :human, id: id)

    Executor.run(executor, intent, %Context{quotes: %{"AAPL" => Decimal.new("125")}})
  end

  test "the session carries the stored credential's bearer", ctx do
    executor = executor!(ctx)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    assert {:ok, %{status: :placed}} = place!(executor, "live-a")
    assert AuthServer.refresh_count(ctx.auth) == 0
  end

  test "a token refused at connect is refreshed, stored, and the session reconnects", ctx do
    Fake.accept(ctx.fake, [ctx.refreshed["access_token"]])
    executor = executor!(ctx)
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)

    assert AuthServer.refresh_count(ctx.auth) == 1
    assert {:ok, stored} = CredentialStore.fetch(ctx.store)
    assert stored.access_token == ctx.refreshed["access_token"]
    assert {:ok, %{status: :placed}} = place!(executor, "live-b")
  end

  test "a refused refresh disarms; a new sign-in reconnects, and orders wait for a fresh arm",
       ctx do
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    auth = AuthServer.start(refresh_status: 400)
    Fake.accept(ctx.fake, [ctx.refreshed["access_token"]])
    Fake.inject(ctx.fake, [{"initialize", :hold}])

    executor =
      start_supervised!(
        {Executor,
         journal: ctx.journal,
         session: Fake.session(ctx.fake),
         account_number: "FAKE-0001",
         policy: Broker.policy(),
         mode: :live,
         credential: [store: ctx.store, auth: [http_fn: AuthServer.http_fn(auth)]]}
      )

    :erlang.trace(executor, true, [:receive])
    Fake.release(ctx.fake)

    assert_receive {:trace, ^executor, :receive, {_ref, {:error, {:token_rejected, 400, _}}}},
                   5_000

    _ = :sys.get_state(executor)

    assert {:ok, :disarmed, %{"reason" => "reauth_required"}} = Journal.mode(ctx.journal)

    # Signing in again stores a new credential; the next refresh takes it over.
    signed_in = %Credential{
      provider: :robinhood,
      client_id: "c",
      access_token: "signed-in-again",
      refresh_token: "r2",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    :ok = CredentialStore.put(signed_in, ctx.store)
    Fake.accept(ctx.fake, ["signed-in-again"])
    send(executor, :refresh_due)
    assert :ok = Executor.await_port(executor, 5_000)

    assert place!(executor, "after-sign-in") == {:error, :not_armed}
    :ok = Journal.record_armed(%{"by" => "test"}, ctx.journal)
    assert {:ok, %{status: :placed}} = place!(executor, "after-arm")
  end

  test "a refresh takes over a newer credential another session stored", ctx do
    {:ok, held} = CredentialStore.fetch(ctx.store)

    newer = %Credential{
      provider: :robinhood,
      client_id: "c",
      access_token: "other-session-token",
      refresh_token: "r",
      expires_at: DateTime.add(DateTime.utc_now(), 3_600, :second)
    }

    :ok = CredentialStore.put(newer, ctx.store)
    auth = [http_fn: AuthServer.http_fn(ctx.auth)]

    assert {:ok, %Credential{access_token: "other-session-token"}} =
             Session.refresh(held, ctx.store, auth)

    assert AuthServer.refresh_count(ctx.auth) == 0
  end
end
