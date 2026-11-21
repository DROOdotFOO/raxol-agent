defmodule Raxol.Payments.Relay.Client do
  @moduledoc """
  Client for Riddler's Relay API: the Tron cross-chain rail.

  Relay settles transfers where one leg is Tron. It is deposit-address based, so
  the client never signs anything: it requests a quote (which returns a
  Riddler-managed deposit address), the user sends funds to that address, and the
  client polls status until terminal. Riddler is the single solver behind it.

  ## Endpoints

  - `get_quote/2` -- POST /relay/quote
  - `execute/2` -- POST /relay/execute
  - `get_status/2` -- GET /relay/status/:transfer_id

  ## Configuration

      config = %{base_url: "https://riddler.example.com", auth_token: "token"}

  `auth_token` may be a `Raxol.Agent.Secret`; it is revealed only when the
  request header is set. A `nil` token sends no `authorization` header.
  """

  alias Raxol.Agent.Secret
  alias Raxol.Payments.Redact
  alias Raxol.Payments.Relay.Schemas.{QuoteRequest, QuoteResponse, ExecuteRequest, StatusResponse}
  alias Raxol.Payments.Xochi.Client, as: XochiClient

  @type config :: %{
          :base_url => String.t(),
          :auth_token => String.t() | Secret.t() | nil,
          optional(:req_options) => keyword()
        }

  @type error :: {:error, {:http, integer(), term()}} | {:error, term()}

  @doc "Request a Tron cross-chain quote with a deposit address."
  @spec get_quote(config(), QuoteRequest.t()) :: {:ok, QuoteResponse.t()} | error()
  def get_quote(config, %QuoteRequest{} = request) do
    with :ok <- QuoteRequest.validate(request) do
      config
      |> build_req()
      |> Req.post(url: "/relay/quote", json: QuoteRequest.to_json(request))
      |> handle_response(&QuoteResponse.from_json/1)
    end
  end

  @doc "Start execution of a quoted transfer. Returns the initial status."
  @spec execute(config(), ExecuteRequest.t()) :: {:ok, StatusResponse.t()} | error()
  def execute(config, %ExecuteRequest{} = request) do
    config
    |> build_req()
    |> Req.post(url: "/relay/execute", json: ExecuteRequest.to_json(request))
    |> handle_response(&StatusResponse.from_json/1)
  end

  @doc "Get transfer status by id."
  @spec get_status(config(), String.t()) :: {:ok, StatusResponse.t()} | error()
  def get_status(config, transfer_id) do
    config
    |> build_req()
    |> Req.get(url: "/relay/status/#{transfer_id}")
    |> handle_response(&StatusResponse.from_json/1)
  end

  # -- Private --

  defp build_req(config) do
    validate_base_url!(config.base_url)

    [
      base_url: config.base_url,
      headers: auth_headers(Map.get(config, :auth_token)),
      receive_timeout: 30_000
    ]
    |> Keyword.merge(Map.get(config, :req_options, []))
    |> Req.new()
  end

  defp auth_headers(nil), do: []
  defp auth_headers(%Secret{} = token), do: auth_headers(Secret.reveal(token))

  defp auth_headers(token) when is_binary(token) or is_list(token),
    do: [{"authorization", "Bearer #{token}"}]

  # The host is parsed, not prefix-matched: `http://localhost@evil.example`
  # starts with `http://localhost` and is a plaintext request to evil.example.
  defp validate_base_url!(url) when is_binary(url) do
    case XochiClient.validate_config(%{base_url: url}) do
      :ok -> :ok
      {:error, _} -> refuse_base_url!(url)
    end
  end

  defp validate_base_url!(url), do: refuse_base_url!(url)

  defp refuse_base_url!(url) do
    raise ArgumentError,
          "Relay client requires HTTPS base_url, got: #{Redact.url(url)}"
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, transform)
       when status in 200..299 do
    {:ok, transform.(body)}
  end

  defp handle_response({:ok, %Req.Response{status: status, body: body}}, _transform) do
    {:error, {:http, status, body}}
  end

  defp handle_response({:error, reason}, _transform) do
    {:error, reason}
  end
end
