defmodule Raxol.Web3.MCP.ErrorTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.HTTP
  alias Raxol.Web3.MCP.Error
  alias Raxol.Web3.MCP.Tools
  alias Raxol.Web3.Serialize

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

  describe "lists the hints share with Raxol.Web3.Serialize" do
    test "the family hint names every non-EVM tag" do
      hint = Error.new({:unsupported_account_ref, :not_an_address}).hint

      for tag <- Serialize.tags(), tag != "evm" do
        assert hint =~ ~s("#{tag}:"), tag
      end
    end

    test "the block number hint names every block tag" do
      hint = Error.new({:invalid_argument, "number"}).hint

      for tag <- Serialize.block_tags(), do: assert(hint =~ tag, tag)
    end
  end

  describe "HTTP status hints" do
    # The hint's retry class is `HTTP.unhealthy_status?/1`'s, the policy the
    # router fails over on and the breaker counts, so the two cannot drift.
    test "a hint says a retry may work exactly when the status is unhealthy" do
      for status <- Enum.to_list(400..451) ++ Enum.to_list(500..511) ++ [599] do
        %Error{hint: hint} = Error.new({:http, status})

        assert hint =~ ~r/retry/i == HTTP.unhealthy_status?(status),
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

    test "401 and 403 are about this deployment, and only 403 says to retry" do
      for status <- [401, 403] do
        hint = Error.new({:http, status}).hint
        assert hint =~ "this deployment", "HTTP #{status}"
        assert hint =~ "Changing the arguments will not help.", "HTTP #{status}"
      end

      assert Error.new({:http, 403}).hint =~ "Retry later."
      refute Error.new({:http, 401}).hint =~ ~r/retry/i
    end
  end

  describe "rendering is total" do
    # `Raxol.Web3.Serialize.error/1` admits a nested map or any binary as a
    # datum, and a raise here becomes `callback_raised` and a breaker fault,
    # or, from inside `Inspect`, an `Inspect.Error` the server sends as-is.
    @interpolating ~w(missing_argument invalid_argument timeout rate_limited too_large http)a

    test "a nested datum on every interpolating code renders without its datum in the hint" do
      for code <- @interpolating, datum <- [{:chunk, 30_000}, {:retry_after, 5}] do
        error = Error.new({code, datum})

        assert is_binary(error.hint), "#{code} has no hint"
        refute error.hint =~ "%{", "#{code}: #{error.hint}"

        assert %{"code" => _code, "detail" => %{}, "hint" => hint} = Jason.decode!(inspect(error))
        assert hint == error.hint
      end
    end

    test "the two reported shapes no longer raise" do
      assert %Error{code: "timeout", hint: timeout} = Error.new({:timeout, {:chunk, 30_000}}, %{})
      assert timeout =~ "The source timed out."

      assert %Error{code: "rate_limited", hint: rate} =
               Error.new({:rate_limited, {:retry_after, 5}}, %{})

      assert rate =~ "Retry later."
    end

    test "a bare code has a hint with no empty slot in it" do
      assert Error.new(:rate_limited).hint ==
               "The source is rate limiting this client. Retry later."

      refute Error.new(:timeout).hint =~ "stage"
      refute Error.new(:too_large).hint =~ " -byte"
    end

    test "a non-UTF-8 datum renders as the server renders it, with none of its bytes" do
      bytes = <<0xFF, 0xFE, 0x41>>

      for reason <- [{:upstream_refused, bytes}, {:invalid_argument, bytes}, {:http, bytes}] do
        error = Error.new(reason)
        rendered = "Error: #{inspect(error)}"

        assert String.valid?(rendered)
        refute rendered =~ "Inspect.Error"
        refute rendered =~ ~r/stacktrace/i
        refute rendered =~ "255, 254"
        refute String.contains?(rendered, <<0xFF>>)

        assert "Error: " <> json = rendered
        assert %{"code" => code, "detail" => nil, "hint" => hint} = Jason.decode!(json)
        assert code == error.code
        assert hint == error.hint
        assert Jason.encode!(error) == json
      end
    end
  end
end
