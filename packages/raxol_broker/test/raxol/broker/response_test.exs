defmodule Raxol.Broker.ResponseTest do
  use ExUnit.Case, async: true

  alias Raxol.Broker.Response

  defp result(body),
    do: {:ok, %{is_error: false, content: [%{"type" => "text", "text" => Jason.encode!(body)}]}}

  test "a page's cursor is read from the body or from Robinhood's envelope" do
    assert {:ok, [1], "c2"} =
             Response.page(result(%{"orders" => [1], "next" => "c2"}), ["orders"])

    enveloped = %{"data" => %{"orders" => [1]}, "next" => "c3", "guide" => "..."}
    assert {:ok, [1], "c3"} = Response.page(result(enveloped), ["orders"])

    assert {:ok, [], nil} = Response.page(result(%{"data" => %{"orders" => []}}), ["orders"])
  end

  test "a body without the listed key is unreadable, never an empty listing" do
    assert Response.page(result(%{"data" => %{"other" => []}}), ["orders"]) ==
             {:error, :unreadable_listing}

    assert Response.page(result(%{"orders" => nil}), ["orders"]) == {:error, :unreadable_listing}
    assert Response.page({:error, :timeout}, ["orders"]) == {:error, :timeout}
  end
end
