defmodule Raxol.Web3.MCP.ErrorTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.HTTP
  alias Raxol.Web3.MCP.Error
  alias Raxol.Web3.MCP.Tools

  test "its inspect form is its JSON, which is the text Raxol.MCP.Server sends" do
    error = Error.new({:upstream_refused, :not_found})

    assert Jason.decode!(inspect(error)) == %{
             "code" => "upstream_refused",
             "detail" => "not_found",
             "hint" => "The source has no such record."
           }

    assert Jason.encode!(error) == inspect(error)
  end

  test "a nested datum stays nested" do
    error = Error.new({:invalid_cursor, {:unknown_endpoint, :address_logs}})

    assert %{"detail" => %{"code" => "unknown_endpoint", "detail" => "address_logs"}} =
             Jason.decode!(inspect(error))
  end

  test "it is still read by fault?/1 as the plain map was" do
    refute Tools.fault?(Error.new({:upstream_refused, :not_found}))
    assert Tools.fault?(Error.new({:upstream_refused, :auth}))
    refute Tools.fault?(Error.new({:http, 404}))
    assert Tools.fault?(Error.new({:http, 503}))
    refute Tools.fault?(Error.new(:no_backend))
    assert Tools.fault?(Error.new({:timeout, :chunk}))
  end

  describe "HTTP status hints" do
    # The hint's retry class is `HTTP.unhealthy_status?/1`'s, the policy the
    # router fails over on and the breaker counts, so the two cannot drift.
    test "a hint says a retry may work exactly when the status is unhealthy" do
      for status <- Enum.to_list(400..451) ++ Enum.to_list(500..511) ++ [599] do
        %Error{hint: hint} = Error.new({:http, status})

        assert hint =~ "retry" == HTTP.unhealthy_status?(status),
               "HTTP #{status}: #{hint}"
      end
    end

    test "only a status about the request says to check the arguments" do
      for status <- [400, 405, 409, 413, 415, 422] do
        assert Error.new({:http, status}).hint =~ "Check the arguments", "HTTP #{status}"
      end

      for status <- [401, 403, 404, 408, 429, 500, 503] do
        refute Error.new({:http, status}).hint =~ "Check the arguments", "HTTP #{status}"
      end
    end

    test "401 and 403 are the source refusing this deployment" do
      for status <- [401, 403] do
        hint = Error.new({:http, status}).hint
        assert hint =~ "refused this deployment", "HTTP #{status}"
        assert hint =~ "will not help", "HTTP #{status}"
      end
    end
  end
end
