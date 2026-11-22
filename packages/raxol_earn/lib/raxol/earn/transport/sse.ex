defmodule Raxol.Earn.Transport.SSE do
  @moduledoc """
  Real `Raxol.Earn.Transport` against the Virtuals ACP Server-Sent
  Events stream at `{server_url}/chats/stream`.

  ## Architecture

  `connect/2` spawns a `Task` that opens an HTTP GET to the SSE
  endpoint via `Req` with a streaming `:into` callback. The callback
  parses each completed SSE frame and forwards it to the configured
  owner pid as `{:transport, entry_map}`.

  The Task is kept in an ETS table held in the transport's config so
  `disconnect/1` can kill it.

  ## SSE frame format

  Standard EventSource. Lines separated by `\\n`; an empty line ends
  the event. Recognised fields:

  - `data:` -- accumulated as the event body
  - `event:` -- the SSE event type (the v2 server uses `entry`)
  - `id:` -- ignored

  Anything else is ignored (no `retry:` handling -- we reconnect
  externally if the stream drops).

  ## Construction

      transport =
        Raxol.Earn.Transport.SSE.new(
          auth: my_auth_pid,
          server_url: "https://api-dev.acp.virtuals.io",
          supported_chain_ids: [8453]
        )

  Then in your agent:

      Raxol.Earn.Transport.connect(transport, %{
        owner: self(),
        chain_ids: [8453],
        wallet_address: "0x..."
      })
  """

  @behaviour Raxol.Earn.Transport

  alias Raxol.Earn.Auth
  alias Raxol.Earn.Transport.SSE.Parser

  require Logger

  @max_sse_buffer_bytes 1_048_576

  @doc """
  Build a transport.

  ## Required

  - `:auth` -- `pid()` or name of a `Raxol.Earn.Auth` process.
  - `:server_url` -- e.g. `https://api-dev.acp.virtuals.io`.

  ## Optional

  - `:supported_chain_ids` -- defaults to `[8453]`. Sent as the
    `x-supported-chains` header.
  - `:req_options` -- extra options threaded into Req (for testing).
  - `:max_sse_buffer_bytes` -- the most bytes of one event held while waiting
    for its boundary (default 1 MiB, as in `Raxol.Agent.Backend.HTTP`). An
    event that outgrows it is dropped with one warning and a
    `[:raxol, :earn, :transport, :sse_dropped]` telemetry event, and the stream
    carries on, so it is not replayed by a reconnect. A dropped event is not
    recovered; alert on the telemetry. An event that arrives whole in
    one chunk is not held and is not limited. A non-positive-integer value
    raises `ArgumentError`.
  """
  @spec new(keyword()) :: Raxol.Earn.Transport.t()
  def new(opts) do
    table = :ets.new(:raxol_earn_transport_sse, [:set, :public])
    :ets.insert(table, {:stream_task, nil})

    config = %{
      auth: Keyword.fetch!(opts, :auth),
      server_url: opts |> Keyword.fetch!(:server_url) |> String.trim_trailing("/"),
      supported_chain_ids: Keyword.get(opts, :supported_chain_ids, [8453]),
      req_options: Keyword.get(opts, :req_options, []),
      max_sse_buffer_bytes: max_sse_buffer_bytes(opts),
      table: table
    }

    %{adapter: __MODULE__, config: config}
  end

  @impl Raxol.Earn.Transport
  def connect(%{config: cfg}, %{owner: owner}) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/chats/stream"

        headers = [
          {"authorization", "Bearer " <> token},
          {"accept", "text/event-stream"},
          {"x-supported-chains", Jason.encode!(cfg.supported_chain_ids)}
        ]

        task =
          Task.async(fn ->
            stream_loop(owner, url, headers, cfg)
          end)

        :ets.insert(cfg.table, {:stream_task, task})
        :ok

      err ->
        err
    end
  end

  @impl Raxol.Earn.Transport
  def disconnect(%{config: cfg}) do
    case :ets.lookup(cfg.table, :stream_task) do
      [{:stream_task, nil}] ->
        :ok

      [{:stream_task, %Task{} = task}] ->
        Task.shutdown(task, :brutal_kill)
        :ets.insert(cfg.table, {:stream_task, nil})
        :ok
    end
  end

  @impl Raxol.Earn.Transport
  def get_history(%{config: cfg}, {chain_id, job_id}) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/jobs/#{chain_id}/#{job_id}"

        case Req.get(url: url, headers: [{"authorization", "Bearer " <> token}]) do
          {:ok, %Req.Response{status: 200, body: %{"data" => %{"entries" => entries}}}}
          when is_list(entries) ->
            {:ok, entries}

          {:ok, %Req.Response{status: 200, body: _}} ->
            {:ok, []}

          {:ok, %Req.Response{status: 404}} ->
            {:ok, []}

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_status, status, body}}

          err ->
            err
        end

      err ->
        err
    end
  end

  @impl Raxol.Earn.Transport
  def post_message(%{config: cfg}, {chain_id, job_id}, content, content_type) do
    case Auth.token(cfg.auth) do
      {:ok, token} ->
        url = cfg.server_url <> "/chats/#{chain_id}/#{job_id}/message"

        body = %{"content" => content, "contentType" => content_type}

        case Req.post(url: url, headers: [{"authorization", "Bearer " <> token}], json: body) do
          {:ok, %Req.Response{status: status}} when status in 200..299 ->
            :ok

          {:ok, %Req.Response{status: status, body: body}} ->
            {:error, {:http_status, status, body}}

          err ->
            err
        end

      err ->
        err
    end
  end

  @impl Raxol.Earn.Transport
  def send_message(transport, key, content, content_type) do
    # The v2 SDK distinguishes "stream send" from "REST post"; for our
    # purposes both go through post_message/4 and the stream picks up the
    # echoed entry via SSE. So we delegate.
    post_message(transport, key, content, content_type)
  end

  # A stream that ends cleanly counts as healthy only if it delivered an entry
  # or stayed open this long; anything shorter is reported as an error so the
  # Agent backs off instead of re-dialling a server that closes at once.
  @healthy_stream_ms 30_000

  defp stream_loop(owner, url, headers, cfg) do
    started = System.monotonic_time(:millisecond)

    opts =
      [
        url: url,
        method: :get,
        headers: headers,
        # An idle provider sees no events for long stretches, and the default
        # receive_timeout would drop a healthy connection. 10 min is far beyond
        # any server keepalive; a real drop surfaces as a transport error and
        # the Agent reconnects. Retries are the Agent's job, not Req's.
        receive_timeout: 600_000,
        retry: false,
        into: fn
          {:data, data}, {req, %Req.Response{status: 200} = resp} ->
            {:cont, {req, feed(owner, resp, data, cfg.max_sse_buffer_bytes)}}

          # An error page is not an event stream: never parse it.
          {:data, _data}, {req, resp} ->
            {:halt, {req, resp}}
        end
      ] ++ cfg.req_options

    # Req blocks until the stream closes. The task's result is the reason it
    # ended; the owning Agent reconnects either way. Reasons are reduced to
    # terms that cannot carry the bearer header.
    try do
      opts |> Req.request() |> stream_result(System.monotonic_time(:millisecond) - started)
    catch
      _kind, _reason -> {:error, :stream_crashed}
    end
  end

  defp stream_result({:ok, %Req.Response{status: 200} = resp}, elapsed_ms),
    do: clean_close(Req.Response.get_private(resp, :sse_entries, 0), elapsed_ms)

  defp stream_result({:ok, %Req.Response{status: status}}, _elapsed_ms),
    do: {:error, {:http_status, status}}

  defp stream_result({:error, %Req.TransportError{reason: reason}}, _elapsed_ms),
    do: {:error, {:transport, reason}}

  defp stream_result({:error, %{__struct__: module}}, _elapsed_ms),
    do: {:error, {:request_failed, module}}

  defp clean_close(entries, elapsed_ms) when entries > 0 or elapsed_ms >= @healthy_stream_ms,
    do: :ok

  defp clean_close(_entries, _elapsed_ms), do: {:error, :closed_early}

  # The parser state rides in the response's private map, the accumulator Req
  # threads through every `:into` call.
  defp feed(owner, resp, data, max_bytes) do
    {entries, dropped, state} =
      resp |> Req.Response.get_private(:sse_state, Parser.new()) |> Parser.feed(data, max_bytes)

    Enum.each(entries, &send(owner, {:transport, &1}))

    if dropped > 0 do
      Logger.warning(
        "ACP SSE: dropped #{dropped} event(s) larger than #{max_bytes} bytes; stream kept open"
      )

      :telemetry.execute([:raxol, :earn, :transport, :sse_dropped], %{count: dropped}, %{
        max_bytes: max_bytes
      })
    end

    resp
    |> Req.Response.put_private(:sse_state, state)
    |> Req.Response.update_private(:sse_entries, length(entries), &(&1 + length(entries)))
  end

  defp max_sse_buffer_bytes(opts) do
    case Keyword.get(opts, :max_sse_buffer_bytes, @max_sse_buffer_bytes) do
      n when is_integer(n) and n > 0 ->
        n

      other ->
        raise ArgumentError,
              ":max_sse_buffer_bytes must be a positive integer, got: #{inspect(other)}"
    end
  end
end
