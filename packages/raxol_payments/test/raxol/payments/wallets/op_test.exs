defmodule Raxol.Payments.Wallets.OpTest do
  use ExUnit.Case, async: true

  alias Raxol.Agent.Secret
  alias Raxol.Payments.Wallets.Op

  test ":sys.get_status shows no key bytes" do
    key = :crypto.strong_rand_bytes(32)
    {:ok, pid} = start_supervised({Op, op_ref: "op://Vault/Item/credential"})
    :sys.replace_state(pid, &%{&1 | privkey: Secret.new(key)})

    {:status, _pid, _mod, [_pdict, _sys, _parent, _dbg, misc]} = :sys.get_status(pid)
    assert inspect(misc, structs: false) =~ "privkey: :redacted"
    assert :binary.match(:erlang.term_to_binary(misc), key) == :nomatch
  end
end
