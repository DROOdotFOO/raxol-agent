defmodule Raxol.Earn.SignerSidecarTest do
  # async: false -- these exercise process-global env vars.
  use ExUnit.Case, async: false

  alias Raxol.Earn.SignerSidecar
  alias Raxol.Earn.TestSupport.TestSidecar

  # init/1 opens a Node Port, so the boot tests below stop at the pre-Port checks;
  # the health gate is exercised against a real loopback listener instead.

  @wallet "0x468AEAE798B3a6548ac2401d276f83afdc172283"

  setup do
    vars = ~w(RAXOL_ACP_SIDECAR_URL RAXOL_ACP_SIGNER_PORT RAXOL_ACP_SIDECAR_ALLOW_REMOTE)
    prior = Map.new(vars, &{&1, System.get_env(&1)})
    Enum.each(vars, &System.delete_env/1)

    on_exit(fn -> Enum.each(prior, fn {k, v} -> restore(k, v) end) end)

    :ok
  end

  defp restore(key, nil), do: System.delete_env(key)
  defp restore(key, val), do: System.put_env(key, val)

  describe "base_url/1" do
    test "defaults to loopback on the default port" do
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:4048"
    end

    test "honors an explicit :port" do
      assert SignerSidecar.base_url(port: 5000) == "http://127.0.0.1:5000"
    end

    test "an explicit :base_url wins over the default" do
      assert SignerSidecar.base_url(base_url: "http://127.0.0.2:9000") == "http://127.0.0.2:9000"
    end

    test "falls back to RAXOL_ACP_SIDECAR_URL when no :base_url is given" do
      System.put_env("RAXOL_ACP_SIDECAR_URL", "http://localhost:1234")
      assert SignerSidecar.base_url([]) == "http://localhost:1234"
      # An explicit :base_url still overrides the env.
      assert SignerSidecar.base_url(base_url: "http://[::1]:5") == "http://[::1]:5"
    end

    test "refuses a non-loopback host, from the env or an option" do
      System.put_env("RAXOL_ACP_SIDECAR_URL", "http://10.0.0.5:4048")
      assert_raise ArgumentError, ~r/not loopback/, fn -> SignerSidecar.base_url([]) end

      for url <- ["http://signer.example", "http://0.0.0.0:4048", "http://127.0.0.1.evil.example"] do
        assert_raise ArgumentError, ~r/not loopback/, fn ->
          SignerSidecar.base_url(base_url: url)
        end
      end
    end

    test "trims a trailing slash and refuses a URL with a path" do
      assert SignerSidecar.base_url(base_url: "http://127.0.0.1:4048/") == "http://127.0.0.1:4048"

      assert_raise ArgumentError, ~r/has a path/, fn ->
        SignerSidecar.base_url(base_url: "http://127.0.0.1:4048/signer")
      end
    end

    test "allows a remote host only when asked to" do
      assert SignerSidecar.base_url(base_url: "http://signer.example", allow_remote: true) ==
               "http://signer.example"

      System.put_env("RAXOL_ACP_SIDECAR_ALLOW_REMOTE", "1")
      assert SignerSidecar.base_url(base_url: "http://signer.example") == "http://signer.example"
    end

    test "the default url uses RAXOL_ACP_SIGNER_PORT" do
      System.put_env("RAXOL_ACP_SIGNER_PORT", "7000")
      assert SignerSidecar.base_url([]) == "http://127.0.0.1:7000"
      # An explicit :port still wins over the env.
      assert SignerSidecar.base_url(port: 8001) == "http://127.0.0.1:8001"
    end
  end

  describe "init/1 with a bad sidecar URL" do
    test "refuses before spawning node, naming the URL problem" do
      assert {:error, {:sidecar_unhealthy, {:bad_sidecar_url, message}}} =
               SignerSidecar.start_link_or_error(
                 name: nil,
                 base_url: "http://signer.example:4048",
                 # Never run: the URL is refused before anything is spawned.
                 node_path: "/nonexistent/node"
               )

      assert message =~ "not loopback"
    end
  end

  describe "start_link_or_error/1" do
    test "start_link/1 kills a caller that does not trap exits" do
      {_pid, ref} = spawn_monitor(fn -> SignerSidecar.start_link(boot_failure_opts()) end)

      assert_receive {:DOWN, ^ref, :process, _pid, reason}, 5_000
      assert reason != :normal
    end

    test "the same failure comes back as a reason, leaving the caller alive" do
      parent = self()

      {pid, ref} =
        spawn_monitor(fn ->
          send(parent, {:result, SignerSidecar.start_link_or_error(boot_failure_opts())})
          Process.sleep(:infinity)
        end)

      assert_receive {:result, {:error, reason}}, 5_000
      refute_receive {:DOWN, ^ref, :process, ^pid, _}, 200
      assert inspect(reason) =~ "signer sidecar script not found"

      Process.exit(pid, :kill)
    end
  end

  describe "await_health/4" do
    test "the sidecar's own wallet passes, whatever the checksum casing" do
      url = TestSidecar.start(String.downcase(@wallet)) |> TestSidecar.listen()
      assert SignerSidecar.await_health(url, 2_000, @wallet, TestSidecar.key()) == :ok
    end

    test "no expected address accepts any authentic sidecar" do
      url = TestSidecar.start(@wallet) |> TestSidecar.listen()
      assert SignerSidecar.await_health(url, 2_000, nil, TestSidecar.key()) == :ok
    end

    test "an authentic sidecar answering for another wallet is rejected, not adopted" do
      other = "0x939ead944b5d28b86d91af1961812d3bbc46cac1"
      url = TestSidecar.start(other) |> TestSidecar.listen()

      assert SignerSidecar.await_health(url, 2_000, @wallet, TestSidecar.key()) ==
               {:error, {:sidecar_wrong_wallet, other, @wallet}}
    end

    test "a listener without the key is refused at once, even reporting the right wallet" do
      for mode <- [:impostor, :unsigned] do
        url = TestSidecar.start(@wallet, %{}, mode: mode) |> TestSidecar.listen()
        started = System.monotonic_time(:millisecond)

        assert SignerSidecar.await_health(url, 2_000, @wallet, TestSidecar.key()) ==
                 {:error, :sidecar_unauthenticated}

        assert System.monotonic_time(:millisecond) - started < 1_000
      end
    end

    test "nothing listening times out" do
      assert SignerSidecar.await_health(health_free_url(), 300, @wallet, TestSidecar.key()) ==
               {:error, :health_timeout}
    end
  end

  # Bind then release a port, so the url is well-formed and reliably unserved.
  defp health_free_url do
    {:ok, listen} = :gen_tcp.listen(0, ip: {127, 0, 0, 1})
    {:ok, port} = :inet.port(listen)
    :ok = :gen_tcp.close(listen)
    "http://127.0.0.1:#{port}"
  end

  # Fails in init/1 before the Node Port is opened, so no node runtime is needed.
  defp boot_failure_opts, do: [name: nil, script: "/nonexistent/signer_sidecar/server.mjs"]
end
