defmodule Raxol.Earn.SignerSidecar do
  @moduledoc """
  Supervises the Node signing sidecar (`priv/signer_sidecar/server.mjs`) as an OS
  process bound to the BEAM's lifetime, and gates solver boot on its health.

  In delegated-signing mode (`Raxol.Earn.ProviderAdapter.Privy`) the raxol_earn release
  holds no key; it signs/settles by calling this sidecar over `127.0.0.1`. The sidecar
  wraps `@virtuals-protocol/acp-node-v2`'s `PrivyAlchemyEvmProviderAdapter`. This
  GenServer:

    * opens a `Port` to `node server.mjs`, so the sidecar dies with the BEAM (the port
      closes stdin on shutdown, which the sidecar treats as a shutdown signal);
    * blocks `init/1` until the sidecar answers an authenticated `GET /health`
      (`Raxol.Earn.SignerSidecar.Envelope`) for the expected wallet, so the
      supervision tree is only "started" once signing is actually available;
    * relays the sidecar's stdout/stderr to `Logger` (its logs are the only signal on a
      node with no inbound port);
    * crashes (and is restarted by its supervisor) if the sidecar exits -- under the
      solver's `:rest_for_one`, that also restarts `Auth`/`Agent` downstream so they
      reconnect against a fresh signer.

  The P-256 authorization key and wallet identifiers are read from the environment by
  the sidecar itself (inherited from the BEAM's env). This GenServer reads the key
  only to derive the `Envelope` MAC key; it never stores or sends it.

  ## Options

  - `:base_url` -- sidecar URL (default from `RAXOL_ACP_SIDECAR_URL`, else
    `http://127.0.0.1:<port>`). Must name a loopback host unless `:allow_remote`
    is true or `RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1`.
  - `:port` -- sidecar listen port (default `RAXOL_ACP_SIGNER_PORT` or `4048`).
  - `:node_path` -- node executable (default: `System.find_executable("node")`).
  - `:script` -- server.mjs path (default: this app's `priv/signer_sidecar/server.mjs`).
  - `:health_timeout_ms` -- boot health-wait budget (default `20_000`).
  - `:expect_address` -- the wallet `GET /health` must report (default
    `RAXOL_ACP_WALLET_ADDRESS`). A listener answering for another wallet is
    rejected rather than adopted as the signer.
  - `:auth_key` -- the `Raxol.Earn.SignerSidecar.Envelope` key (default:
    derived from `RAXOL_ACP_SIGNER_PRIVATE_KEY`, which the sidecar also reads).
  """

  use GenServer
  require Logger

  alias Raxol.Earn.SignerSidecar.Envelope

  @default_port 4048
  # Generous margin: on a cold, cpu-constrained VM the node process must spawn and
  # `import` the acp-node-v2 SDK (~185 modules) before it answers /health.
  @default_health_timeout_ms 30_000

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))
  end

  @doc """
  Start the sidecar for a caller that does not trap exits, such as a Mix task.

  `start_link/1` cannot report a boot failure to such a caller: `init/1` exits,
  and the link delivers that exit signal before the `{:error, _}` return value is
  ever inspected, so the caller dies with an opaque `** (EXIT from ...)`. This
  traps exits for the duration of the start and hands the reason back. The link
  is left intact on success, so a sidecar that dies later still takes the caller
  with it.
  """
  @spec start_link_or_error(keyword()) :: {:ok, pid()} | {:error, term()}
  def start_link_or_error(opts \\ []) do
    trapping? = Process.flag(:trap_exit, true)

    try do
      opts |> start_link() |> settle()
    after
      Process.flag(:trap_exit, trapping?)
    end
  end

  # Already running: no child was spawned, so there is no exit signal to collect.
  defp settle({:error, {:already_started, pid}}), do: {:ok, pid}

  # `init_fail/3` acks the caller before the child exits, so the signal lands just
  # after start_link returns. Wait for it: leaving it queued would surface later as
  # a stray message, or vanish once the flag is restored.
  defp settle({:error, reason}) do
    receive do
      {:EXIT, _pid, _} -> :ok
    after
      1_000 -> :ok
    end

    {:error, reason}
  end

  # A sidecar that died in this window has already been converted to a message that
  # restoring the flag cannot turn back into a kill, so report it rather than lose it.
  defp settle({:ok, pid}) do
    receive do
      {:EXIT, ^pid, reason} -> {:error, reason}
    after
      0 -> {:ok, pid}
    end
  end

  @doc """
  The sidecar base URL for the given (or default) options. Raises
  `ArgumentError` for a non-loopback host unless remote sidecars are allowed.
  """
  @spec base_url(keyword()) :: String.t()
  def base_url(opts \\ []) do
    (Keyword.get(opts, :base_url) || System.get_env("RAXOL_ACP_SIDECAR_URL") ||
       "http://127.0.0.1:#{port(opts)}")
    |> check_url!(opts)
  end

  @doc """
  Return `url` without a trailing slash when its host is loopback, or when
  remote sidecars are allowed (`allow_remote: true` or
  `RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1`); raise `ArgumentError` otherwise, or when
  the URL carries a path (requests are signed over the sidecar's own paths).
  Sidecar traffic is authenticated, not encrypted.
  """
  @spec check_url!(String.t(), keyword()) :: String.t()
  def check_url!(url, opts \\ []) do
    url = String.trim_trailing(url, "/")
    %URI{host: host, path: path} = URI.parse(url)

    cond do
      path not in [nil, ""] ->
        raise ArgumentError,
              "signer sidecar URL #{inspect(url)} has a path (#{inspect(path)}); " <>
                "give scheme, host and port only"

      loopback?(host) or allow_remote?(opts) ->
        url

      true ->
        raise ArgumentError,
              "signer sidecar URL #{inspect(url)} is not loopback (host #{inspect(host)}). " <>
                "Its requests and responses are authenticated but not encrypted; set " <>
                "RAXOL_ACP_SIDECAR_ALLOW_REMOTE=1 to use it anyway."
    end
  end

  @doc "The `Envelope` key derived from `RAXOL_ACP_SIGNER_PRIVATE_KEY`, if it is set."
  @spec env_auth_key() :: {:ok, Envelope.key()} | :error
  def env_auth_key do
    case System.get_env("RAXOL_ACP_SIGNER_PRIVATE_KEY") do
      key when is_binary(key) and key != "" -> {:ok, Envelope.derive_key(key)}
      _ -> :error
    end
  end

  defp loopback?("localhost"), do: true

  defp loopback?(host) when is_binary(host) do
    case :inet.parse_address(String.to_charlist(String.trim(host, "[") |> String.trim("]"))) do
      {:ok, {127, _, _, _}} -> true
      {:ok, {0, 0, 0, 0, 0, 0, 0, 1}} -> true
      _ -> false
    end
  end

  defp loopback?(_host), do: false

  defp allow_remote?(opts),
    do:
      Keyword.get(opts, :allow_remote, false) or
        System.get_env("RAXOL_ACP_SIDECAR_ALLOW_REMOTE") == "1"

  @impl true
  def init(opts) do
    Process.flag(:trap_exit, true)

    node_path =
      Keyword.get(opts, :node_path) || System.find_executable("node") ||
        raise("node executable not found on PATH (required for the signing sidecar)")

    script = Keyword.get(opts, :script, default_script())
    File.exists?(script) || raise("signer sidecar script not found: #{script}")
    base_url = base_url(opts)

    # Resolved before node is spawned: without a key nothing could check it.
    case auth_key(opts) do
      {:ok, key} -> boot(opts, node_path, script, base_url, key)
      {:error, reason} -> {:stop, {:sidecar_unhealthy, reason}}
    end
  end

  defp boot(opts, node_path, script, base_url, key) do
    port =
      Port.open(
        {:spawn_executable, node_path},
        [
          :binary,
          :exit_status,
          :hide,
          {:args, [script]},
          {:env, [{~c"RAXOL_ACP_SIGNER_PORT", ~c"#{port(opts)}"}]},
          {:line, 4096}
        ]
      )

    state = %{port: port, base_url: base_url}

    case await_health(
           base_url,
           Keyword.get(opts, :health_timeout_ms, @default_health_timeout_ms),
           expect_address(opts),
           key
         ) do
      :ok ->
        Logger.info("signer sidecar healthy at #{base_url}")
        {:ok, state}

      {:error, reason} ->
        {:stop, {:sidecar_unhealthy, reason}}
    end
  end

  defp auth_key(opts) do
    case Keyword.fetch(opts, :auth_key) do
      {:ok, key} -> {:ok, key}
      :error -> with :error <- env_auth_key(), do: {:error, :no_signer_private_key}
    end
  end

  @impl true
  def handle_info({port, {:data, {_eol, line}}}, %{port: port} = state) do
    Logger.info("[signer] #{line}")
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, status}}, %{port: port} = state) do
    {:stop, {:sidecar_exited, status}, state}
  end

  def handle_info({:EXIT, port, reason}, %{port: port} = state) do
    {:stop, {:sidecar_port_closed, reason}, state}
  end

  def handle_info(_msg, state), do: {:noreply, state}

  @impl true
  def terminate(_reason, %{port: port}) do
    # Closing the port sends EOF on the sidecar's stdin, which it treats as a
    # shutdown signal -- so the node process does not outlive the BEAM.
    if is_port(port) and Port.info(port) != nil, do: Port.close(port)
    :ok
  end

  # -- Internals --

  defp port(opts) do
    Keyword.get(opts, :port) ||
      case System.get_env("RAXOL_ACP_SIGNER_PORT") do
        nil -> @default_port
        s -> String.to_integer(s)
      end
  end

  defp default_script do
    :raxol_earn
    |> Application.app_dir("priv/signer_sidecar/server.mjs")
  end

  # The sidecar reads this env itself, so it is also what the sidecar will report.
  defp expect_address(opts) do
    Keyword.get(opts, :expect_address) || System.get_env("RAXOL_ACP_WALLET_ADDRESS")
  end

  @typedoc """
  Whose wallet a response must be signed for: an address, or `:from_body` to
  take the one the response reports (the health check, which then compares it).
  """
  @type signer :: String.t() | :from_body

  @typedoc """
  How a signed sidecar call ended. `{:sidecar_refused, reason}` is an unsigned
  401: the sidecar's stated reason, which nothing proves came from it.
  """
  @type call_result ::
          {:ok, non_neg_integer(), term()}
          | {:error,
             :sidecar_unauthenticated
             | :sidecar_bad_body
             | {:sidecar_refused, String.t() | nil}
             | {:signer_unreachable, term()}}

  @doc """
  One authenticated request to the sidecar. The body is encoded here, so the
  request signature covers the exact bytes sent, and a response is accepted
  only if it is signed over that request signature for `signer`. Returns the
  status and the decoded body.
  """
  @spec call(String.t(), String.t(), String.t(), map() | nil, Envelope.key(), signer(), keyword()) ::
          call_result()
  def call(base_url, method, path, payload, key, signer, req_options \\ []) do
    body = if payload == nil, do: "", else: Jason.encode!(payload)
    {request_sig, auth} = Envelope.request_headers(key, method, path, body)

    opts =
      [
        method: method |> String.downcase() |> String.to_existing_atom(),
        url: base_url <> path,
        body: body,
        headers: [{"content-type", "application/json"} | auth],
        decode_body: false,
        # A redirect would resend the signed request past the loopback pin.
        redirect: false,
        retry: false
      ] ++ req_options

    case Req.request(opts) do
      {:ok, %Req.Response{} = resp} -> accept(resp, key, request_sig, signer)
      {:error, reason} -> {:error, {:signer_unreachable, reason}}
    end
  end

  defp accept(%Req.Response{status: status, body: raw} = resp, key, request_sig, signer) do
    case Req.Response.get_header(resp, "x-raxol-sig") do
      [] when status == 401 ->
        {:error, {:sidecar_refused, refusal_reason(raw)}}

      sigs ->
        with :ok <-
               Envelope.verify_response(
                 key,
                 request_sig,
                 signer_address(signer, raw),
                 status,
                 raw,
                 sigs
               ),
             {:ok, decoded} <- decode(raw) do
          {:ok, status, decoded}
        end
    end
  end

  defp refusal_reason(raw) do
    case Jason.decode(raw) do
      {:ok, %{"reason" => reason}} when is_binary(reason) -> reason
      _ -> nil
    end
  end

  # For `:from_body` the address is read before the signature is checked, and
  # the signature then covers it, so a forged address fails verification.
  defp signer_address(:from_body, raw) do
    case Jason.decode(raw) do
      {:ok, %{"address" => address}} when is_binary(address) -> address
      _ -> ""
    end
  end

  defp signer_address(address, _raw), do: address

  defp decode(""), do: {:ok, %{}}

  defp decode(raw) do
    case Jason.decode(raw) do
      {:ok, decoded} -> {:ok, decoded}
      {:error, _} -> {:error, :sidecar_bad_body}
    end
  end

  # Poll the authenticated GET /health until the sidecar answers as
  # `expect_address`, or the budget elapses. Public so the identity gate is
  # testable against a real loopback listener, without a node runtime.
  @doc false
  @spec await_health(String.t(), non_neg_integer(), String.t() | nil, Envelope.key()) ::
          :ok | {:error, term()}
  def await_health(base_url, timeout_ms, expect_address, key) do
    deadline = System.monotonic_time(:millisecond) + timeout_ms
    do_await_health(base_url, deadline, expect_address, key)
  end

  defp do_await_health(base_url, deadline, expect, key) do
    case call(base_url, "GET", "/health", nil, key, :from_body, receive_timeout: 2_000) do
      {:ok, 200, body} -> check_identity(body, expect)
      # None of these become a healthy signer by waiting.
      {:error, :sidecar_unauthenticated} -> {:error, :sidecar_unauthenticated}
      {:error, {:sidecar_refused, _reason} = refused} -> {:error, refused}
      _ -> retry_health(base_url, deadline, expect, key)
    end
  end

  # The response is authentic, so the reported wallet is the one this sidecar
  # signs for; it still has to be the configured one. A mismatch never becomes
  # a match by waiting, so it is returned rather than retried.
  defp check_identity(_body, nil), do: :ok

  defp check_identity(%{"address" => got}, want) when is_binary(got) do
    case String.downcase(got) == String.downcase(want) do
      true -> :ok
      false -> {:error, {:sidecar_wrong_wallet, got, want}}
    end
  end

  defp check_identity(_body, want), do: {:error, {:sidecar_wrong_wallet, nil, want}}

  defp retry_health(base_url, deadline, expect, key) do
    case System.monotonic_time(:millisecond) < deadline do
      true ->
        Process.sleep(250)
        do_await_health(base_url, deadline, expect, key)

      false ->
        {:error, :health_timeout}
    end
  end
end
