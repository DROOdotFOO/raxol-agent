defmodule Raxol.Web3.MCP.ErrorTest do
  use ExUnit.Case, async: true

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
end
