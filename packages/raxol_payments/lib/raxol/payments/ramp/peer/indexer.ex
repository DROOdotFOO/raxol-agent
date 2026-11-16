defmodule Raxol.Payments.Ramp.Peer.Indexer do
  @moduledoc "Public Peer GraphQL reader with shared Retry-After cooldown and no automatic retries."
  use GenServer
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts)

  def query(server, query, variables),
    do: GenServer.call(server, {:query, query, variables}, 15_000)

  @impl true
  def init(opts), do: {:ok, %{options: opts, blocked_until: 0}}
  @impl true
  def handle_call({:query, query, variables}, _, state) do
    now = Keyword.get(state.options, :now, fn -> System.system_time(:millisecond) end).()

    if now < state.blocked_until do
      {:reply, {:error, :rate_limited}, state}
    else
      {reply, blocked} = fetch(state.options, query, variables, now)
      {:reply, reply, %{state | blocked_until: blocked}}
    end
  end

  defp fetch(opts, query, variables, now) do
    request =
      Keyword.merge(Keyword.get(opts, :req_options, []),
        url: "https://indexer.zkp2p.xyz/v1/graphql",
        method: :post,
        json: %{query: query, variables: variables},
        retry: false,
        redirect: false,
        decode_body: false,
        receive_timeout: 10_000,
        connect_options: [timeout: 5_000]
      )

    case Req.request(request) do
      {:ok, %{status: 429} = response} ->
        {{:error, :rate_limited}, deadline(Req.Response.get_header(response, "retry-after"), now)}

      {:ok, %{status: 200, body: body}} when is_binary(body) and byte_size(body) <= 262_144 ->
        decode(body)

      _ ->
        {{:error, :indexer_unavailable}, 0}
    end
  rescue
    _ -> {{:error, :indexer_unavailable}, 0}
  catch
    _, _ -> {{:error, :indexer_unavailable}, 0}
  end

  defp decode(body) do
    case Jason.decode(body) do
      {:ok, %{"data" => data} = envelope} when is_map(data) ->
        if Map.has_key?(envelope, "errors"),
          do: {{:error, :indexer_unavailable}, 0},
          else: {{:ok, data}, 0}

      _ ->
        {{:error, :indexer_unavailable}, 0}
    end
  end

  defp deadline([value], now) when byte_size(value) <= 128 do
    case Integer.parse(value) do
      {seconds, ""} when seconds >= 0 ->
        now + max(1000, seconds * 1000)

      _ ->
        case Req.Utils.parse_http_date(value) do
          {:ok, date} -> max(now + 1000, DateTime.to_unix(date, :millisecond))
          _ -> now + 30_000
        end
    end
  end

  defp deadline(_, now), do: now + 30_000
end
