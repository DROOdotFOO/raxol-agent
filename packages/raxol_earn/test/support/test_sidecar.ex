defmodule Raxol.Earn.TestSupport.TestSidecar do
  @moduledoc false
  # A signing sidecar that speaks the `Raxol.Earn.SignerSidecar.Envelope`
  # protocol, as a Plug. `:impostor` answers without the key (signs with
  # another one), `:unsigned` omits the response signature. The behaviour is
  # read from an Agent per request, so a test can swap it mid-run.
  @behaviour Plug

  alias Raxol.Earn.SignerSidecar.Envelope

  @signer_key "test-p256-authorization-key"

  @spec key() :: Envelope.key()
  def key, do: Envelope.derive_key(@signer_key)

  @spec signer_private_key() :: String.t()
  def signer_private_key, do: @signer_key

  @doc "Start the behaviour holder: `%{mode, address, routes, test_pid}`."
  @spec start(String.t(), map(), keyword()) :: pid()
  def start(address, routes \\ %{}, opts \\ []) do
    state = %{
      mode: Keyword.get(opts, :mode, :honest),
      address: address,
      routes: routes,
      test_pid: Keyword.get(opts, :test_pid, self())
    }

    {:ok, pid} = Agent.start_link(fn -> state end)

    pid
  end

  @spec set_mode(pid(), :honest | :impostor | :unsigned) :: :ok
  def set_mode(pid, mode), do: Agent.update(pid, &%{&1 | mode: mode})

  @doc "Serve `holder` on a real loopback port; returns the base URL."
  @spec listen(pid()) :: String.t()
  def listen(holder) do
    ref = make_ref()
    {:ok, _} = Plug.Cowboy.http(__MODULE__, holder, port: 0, ref: ref, ip: {127, 0, 0, 1})
    ExUnit.Callbacks.on_exit(fn -> Plug.Cowboy.shutdown(ref) end)
    "http://127.0.0.1:#{:ranch.get_port(ref)}"
  end

  @impl true
  def init(holder), do: holder

  @impl true
  def call(conn, holder) do
    state = Agent.get(holder, & &1)
    {:ok, raw, conn} = Plug.Conn.read_body(conn)
    request_sig = header(conn, "x-raxol-sig")
    conn = Plug.Conn.put_resp_content_type(conn, "application/json")

    if authentic?(conn, raw, request_sig) do
      {status, body} = route(conn, state, raw)
      payload = Jason.encode!(body)

      conn
      |> sign(state, request_sig, status, payload)
      |> Plug.Conn.send_resp(status, payload)
    else
      # Like the real sidecar: a refusal is never signed.
      Plug.Conn.send_resp(
        conn,
        401,
        Jason.encode!(%{error: "unauthorized", reason: "bad_signature"})
      )
    end
  end

  defp authentic?(conn, raw, request_sig) do
    ts = header(conn, "x-raxol-ts")
    nonce = header(conn, "x-raxol-nonce")
    request_sig == Envelope.request_sig(key(), conn.method, conn.request_path, raw, ts, nonce)
  end

  defp route(%{request_path: "/health"}, state, _raw),
    do: {200, %{ok: true, address: state.address}}

  defp route(%{request_path: path}, state, raw) do
    send(state.test_pid, {:sidecar, path, if(raw == "", do: %{}, else: Jason.decode!(raw))})
    Map.get(state.routes, path, {200, %{}})
  end

  defp sign(conn, %{mode: :unsigned}, _request_sig, _status, _payload), do: conn

  defp sign(conn, %{mode: mode, address: address}, request_sig, status, payload) do
    key = if mode == :impostor, do: Envelope.derive_key("another key"), else: key()

    Plug.Conn.put_resp_header(
      conn,
      "x-raxol-sig",
      Envelope.response_sig(key, request_sig, status, address, payload)
    )
  end

  defp header(conn, name), do: conn |> Plug.Conn.get_req_header(name) |> List.first("")
end
