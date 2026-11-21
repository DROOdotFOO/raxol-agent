defmodule Raxol.Agent.SecretTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Secret

  @key <<0xAB::256>>
  @hex Base.encode16(@key, case: :lower)

  describe "new/1 and reveal/1" do
    test "round-trips and is idempotent" do
      secret = Secret.new(@key)
      assert Secret.reveal(secret) == @key
      assert Secret.new(secret) == secret
    end

    test "a non-binary raises without echoing the value" do
      error = assert_raise ArgumentError, fn -> Secret.new(~c"sk-charlist") end
      refute Exception.message(error) =~ "sk-charlist"
    end

    test "wrap/1 passes nil through" do
      assert Secret.wrap(nil) == nil
      assert Secret.reveal(Secret.wrap("t")) == "t"
    end
  end

  describe "rendering" do
    test "inspect is redacted, also nested in a map" do
      assert inspect(Secret.new(@key)) == "#Raxol.Agent.Secret<redacted>"
      refute inspect(%{privkey: Secret.new(@key)}) =~ @hex
    end

    test "cannot be interpolated" do
      refute String.Chars.impl_for(Secret.new(@key))
    end
  end

  describe "with_revealed/2" do
    test "passes the function's result through" do
      assert Secret.with_revealed(Secret.new(@key), &{:ok, &1}) == {:ok, @key}

      assert Secret.with_revealed(Secret.new(@key), fn _ -> {:error, :nope} end) ==
               {:error, :nope}
    end

    test "turns a raise, throw or exit into a fixed error" do
      secret = Secret.new(@key)
      crashed = {:error, :secret_operation_crashed}
      assert Secret.with_revealed(secret, fn _ -> raise "boom #{@hex}" end) == crashed
      assert Secret.with_revealed(secret, fn _ -> throw(:x) end) == crashed
      assert Secret.with_revealed(secret, fn _ -> exit(:x) end) == crashed
    end
  end

  describe "redact_status/2" do
    test "replaces the named state keys and keeps nil" do
      status = %{state: %{token: "t", refresh: nil, other: 1}, reason: :normal}

      assert Secret.redact_status(status, [:token, :refresh, :absent]) ==
               %{state: %{token: :redacted, refresh: nil, other: 1}, reason: :normal}
    end

    test "empties the sys debug log" do
      status = %{state: %{token: "t"}, log: [{:in, {:call, "t"}}]}
      assert %{log: [], state: %{token: :redacted}} = Secret.redact_status(status, [:token])
    end

    test "failure: true reduces the reason and the last message" do
      stack = [{M, :f, [[api_key: "sk-leak"]], []}]
      exit = {%FunctionClauseError{module: M, function: :f, arity: 1}, stack}
      status = %{state: %{}, reason: exit, message: {:"$gen_cast", {:directive, "sk-leak"}}}

      redacted = Secret.redact_status(status, [], failure: true)
      assert redacted.reason == FunctionClauseError
      assert redacted.message == :"$gen_cast"
      refute inspect(redacted) =~ "sk-leak"
      assert Secret.redact_status(status, []).reason == exit
    end

    test "leaves a status without a map state alone" do
      assert Secret.redact_status(%{state: :idle}, [:token]) == %{state: :idle}
      assert Secret.redact_status(%{}, [:token]) == %{}
    end
  end
end
