defmodule Raxol.Earn.ProviderAdapter.PrivyTest do
  use ExUnit.Case, async: true

  alias Raxol.Earn.ProviderAdapter.Privy
  alias Raxol.Earn.TestSupport.TestSidecar

  @addr "0x" <> String.duplicate("ab", 20)

  # An in-process signing sidecar speaking the authenticated protocol, mounted
  # as a Req plug: no Node process, no network.
  defp sidecar(test_pid, responses, mode \\ :honest) do
    holder = TestSidecar.start(@addr, responses, mode: mode, test_pid: test_pid)

    {adapter(req_options: [plug: {TestSidecar, holder}, retry: false]), holder}
    |> elem(0)
  end

  defp adapter(opts) do
    Privy.new(
      Keyword.merge(
        [
          sidecar_url: "http://127.0.0.1:4048/",
          address: @addr,
          chains: %{8453 => "https://mainnet.base.org"},
          auth_key: TestSidecar.key()
        ],
        opts
      )
    )
  end

  describe "new/1" do
    test "trims a trailing slash from the sidecar url and defaults the timeout" do
      adapter = adapter(chains: %{8453 => "u"})

      assert adapter.config.sidecar_url == "http://127.0.0.1:4048"
      assert adapter.config.req_options[:receive_timeout] == 60_000
    end

    test "exposes the managed wallet address and the sorted supported chains" do
      adapter = adapter(chains: %{42_161 => "a", 8453 => "b"})

      assert Privy.get_address(adapter) == @addr
      assert Privy.supported_chain_ids(adapter) == [8453, 42_161]
    end
  end

  describe "sign_message/3" do
    test "posts to /sign-message and decodes the hex signature to raw bytes" do
      sig_hex = String.duplicate("ab", 65)
      adapter = sidecar(self(), %{"/sign-message" => {200, %{"signature" => "0x" <> sig_hex}}})

      assert {:ok, raw} = Privy.sign_message(adapter, 8453, "hello")
      assert raw == Base.decode16!(sig_hex, case: :mixed)
      assert_receive {:sidecar, "/sign-message", %{"chainId" => 8453, "message" => "hello"}}
    end
  end

  describe "sign_typed_data/3" do
    test "normalizes tuple type-fields to objects and decodes the signature" do
      typed = %{
        domain: %{"name" => "Xochi"},
        types: %{"XochiIntent" => [{"intentId", "string"}, {"amount", "uint256"}]},
        message: %{"intentId" => "xi_1"}
      }

      sig_hex = String.duplicate("cd", 65)
      adapter = sidecar(self(), %{"/sign-typed-data" => {200, %{"signature" => "0x" <> sig_hex}}})

      assert {:ok, raw} = Privy.sign_typed_data(adapter, 8453, typed)
      assert raw == Base.decode16!(sig_hex, case: :mixed)

      assert_receive {:sidecar, "/sign-typed-data", body}

      assert body["typedData"]["types"]["XochiIntent"] == [
               %{"name" => "intentId", "type" => "string"},
               %{"name" => "amount", "type" => "uint256"}
             ]
    end
  end

  describe "send_calls/3" do
    test "hex-encodes data, stringifies value, and returns the tx hashes" do
      adapter = sidecar(self(), %{"/send-calls" => {200, %{"txHashes" => ["0xabc"]}}})
      calls = [%{to: "0xdead", data: <<1, 2, 3>>, value: 1000}]

      assert {:ok, ["0xabc"]} = Privy.send_calls(adapter, 8453, calls)
      assert_receive {:sidecar, "/send-calls", %{"calls" => [call]}}
      assert call["to"] == "0xdead"
      assert call["data"] == "0x010203"
      assert call["value"] == "1000"
    end

    test "defaults empty data and zero value" do
      adapter = sidecar(self(), %{"/send-calls" => {200, %{"txHashes" => []}}})
      assert {:ok, []} = Privy.send_calls(adapter, 8453, [%{to: "0xfeed"}])

      assert_receive {:sidecar, "/send-calls", %{"calls" => [call]}}
      assert call["data"] == "0x"
      assert call["value"] == "0"
    end
  end

  describe "sidecar error mapping" do
    test "a 409 approval_required surfaces the approval id + url" do
      adapter =
        sidecar(self(), %{
          "/sign-message" =>
            {409,
             %{
               "error" => "approval_required",
               "approvalId" => "ap_1",
               "approvalUrl" => "https://approve.example/ap_1"
             }}
        })

      assert {:error, {:approval_required, "ap_1", "https://approve.example/ap_1"}} =
               Privy.sign_message(adapter, 8453, "x")
    end

    test "a non-200 surfaces {:signer, status, detail}" do
      adapter = sidecar(self(), %{"/sign-message" => {500, %{"detail" => "boom"}}})
      assert {:error, {:signer, 500, "boom"}} = Privy.sign_message(adapter, 8453, "x")
    end
  end

  describe "authentication" do
    test "a sidecar without the key is refused, whatever it answers" do
      adapter = sidecar(self(), %{"/send-calls" => {200, %{"txHashes" => ["0xabc"]}}}, :impostor)
      assert {:error, :sidecar_unauthenticated} = Privy.send_calls(adapter, 8453, [%{to: "0x1"}])
    end

    test "an unsigned response is refused" do
      adapter = sidecar(self(), %{"/sign-message" => {200, %{"signature" => "0x00"}}}, :unsigned)
      assert {:error, :sidecar_unauthenticated} = Privy.sign_message(adapter, 8453, "x")
    end

    test "a response signed for another wallet is refused" do
      holder = TestSidecar.start("0x" <> String.duplicate("99", 20), %{})
      adapter = adapter(req_options: [plug: {TestSidecar, holder}, retry: false])

      assert {:error, :sidecar_unauthenticated} = Privy.sign_message(adapter, 8453, "x")
    end

    test "requests carry a signature the sidecar checks" do
      adapter = adapter(auth_key: :crypto.strong_rand_bytes(32))
      holder = TestSidecar.start(@addr, %{})
      adapter = put_in(adapter.config.req_options, plug: {TestSidecar, holder}, retry: false)

      # Wrong key: the sidecar refuses with an unsigned 401, reported as an
      # unverified refusal rather than an answer.
      assert {:error, {:sidecar_refused, "bad_signature"}} =
               Privy.sign_message(adapter, 8453, "x")

      refute_received {:sidecar, _, _}
    end
  end

  describe "new/1 sidecar url" do
    test "refuses a non-loopback host" do
      assert_raise ArgumentError, ~r/not loopback/, fn ->
        adapter(sidecar_url: "http://signer.example:4048")
      end
    end

    test "accepts a non-loopback host only when explicitly allowed" do
      assert adapter(sidecar_url: "http://signer.example:4048", allow_remote: true).config.sidecar_url ==
               "http://signer.example:4048"
    end

    test "accepts IPv6 loopback and localhost" do
      assert adapter(sidecar_url: "http://[::1]:4048").config.sidecar_url == "http://[::1]:4048"

      assert adapter(sidecar_url: "http://localhost:4048").config.sidecar_url ==
               "http://localhost:4048"
    end
  end

  describe "read callbacks" do
    test "reject an unsupported chain before any network call" do
      adapter = adapter(chains: %{8453 => "u"})

      assert {:error, {:unsupported_chain, 10}} =
               Privy.get_transaction_receipt(adapter, 10, "0xh")
    end
  end
end
