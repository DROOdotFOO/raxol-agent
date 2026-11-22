defmodule Raxol.Broker.RedactTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Redact

  describe "collapse/1" do
    test "keeps the tag and drops stack arguments" do
      spec = [headers: [{"authorization", "Bearer leak"}]]
      exit = {%FunctionClauseError{module: M, function: :f, arity: 1}, [{M, :f, [spec], []}]}

      assert Redact.collapse({:port_exited, exit}) == {:port_exited, FunctionClauseError}
      assert Redact.collapse({:connect_failed, {:http, 401}}) == {:connect_failed, {:http, 401}}
      assert Redact.collapse({:connect_failed, :nxdomain}) == {:connect_failed, :nxdomain}

      assert Redact.collapse({:connect_failed, {:initialization_failed, {:http, 401}}}) ==
               {:connect_failed, {:initialization_failed, {:http, 401}}}

      assert Redact.collapse({:connect_crashed, {:start, spec}}) == {:connect_crashed, :start}
      assert Redact.collapse({:connect_crashed, {"x", spec}}) == {:connect_crashed, :error}
      refute inspect(Redact.collapse({:port_exited, {:killed, [spec]}})) =~ "leak"
    end

    test "reduces a start_link error that carries the client spec" do
      spec = {:http, [headers: [{"authorization", "Bearer leak"}]]}
      refute inspect(Redact.collapse({:shutdown, {:failed_to_start_child, M, spec}})) =~ "leak"
    end
  end

  test "collapse/1 keeps a tagged status and drops its body" do
    assert Redact.collapse({:refresh_failed, {:token_rejected, 500, "Bearer leak"}}) ==
             {:refresh_failed, {:token_rejected, 500}}
  end

  test "collapse/1 is idempotent" do
    for reason <- [
          {:refresh_failed, {:token_rejected, 500, "Bearer leak"}},
          {:connect_failed, {:initialization_failed, {:http, 401}}},
          {:port_exited, {%RuntimeError{message: "x"}, []}},
          {:start, {"x", [headers: []]}}
        ] do
      once = Redact.collapse(reason)
      assert Redact.collapse(once) == once
    end
  end

  describe "shape/1" do
    test "keeps only a tuple's tag" do
      assert Redact.shape({:token, "Bearer leak"}) == "{:token, ...}"
      assert Redact.shape("Bearer leak") == "term"
      assert Redact.shape({%URI{host: "leak"}, 1}) == "{term, ...}"
    end
  end
end
