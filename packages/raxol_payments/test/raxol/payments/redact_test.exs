defmodule Raxol.Payments.RedactTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Redact

  test "url/1 keeps scheme, host and a non-default port only" do
    assert Redact.url("https://u:pw@rpc.example/v2/sek?key=sek") == "https://rpc.example"
    assert Redact.url("http://127.0.0.1:8545/sek") == "http://127.0.0.1:8545"
    assert Redact.url("not a url sek") == "<url without a host>"
    assert Redact.url({:secret, "sek"}) == "<not a string>"
    assert Redact.url("HTTPS://RPC.Example/x") == "https://rpc.example"
    assert Redact.url("https://[::1]:8545/sek") == "https://[::1]:8545"
    assert Redact.url("https://host%0aInjected/x") == "<url with an invalid host>"
  end
end
