defmodule Raxol.Web3.Backend.Canton.Scan do
  @moduledoc false
  # Internal to `Raxol.Web3.Backend.Canton`.
  #
  # The Splice Scan v0 outbound path for `Raxol.Web3.Backend.Canton`: the
  # probed endpoint table, GET and POST through `Raxol.Web3.HTTP`, and the two
  # reference reads every party-scoped read depends on, the synchronizer
  # migration id from `/dso` and the ACS snapshot it is taken against.
  #
  # The cache key fragment is the endpoint's own path and parameters, never an
  # assembled URI, so a credential in the Scan URL cannot reach a cache key.

  import Raxol.Web3.Backend.Decode, only: [int: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Cache
  alias Raxol.Web3.Backend.Decode
  alias Raxol.Web3.Backend.PathSegment
  alias Raxol.Web3.HTTP
  alias Raxol.Web3.Scope

  @typedoc "The fields of a Canton handle this module reads."
  @type state :: %{
          required(:scan_url) => String.t(),
          required(:http_opts) => keyword(),
          required(:cache?) => boolean(),
          required(:migration_id) => non_neg_integer() | nil,
          optional(atom()) => term()
        }

  @type snapshot :: %{String.t() => term()}

  # Every path probed 2026-09-14 against api.cantonnodes.com, all 200 keyless.
  # Data, not behaviour: the method is part of the row because two of the five
  # are POSTs whose parameters travel in a body rather than a query string.
  @paths %{
    round_of_latest_data: {:get, "/round-of-latest-data"},
    dso: {:get, "/dso"},
    acs_snapshot: {:get, "/state/acs/snapshot-timestamp"},
    instance_names: {:get, "/splice-instance-names"},
    holdings_summary: {:post, "/holdings/summary"},
    holdings_state: {:post, "/holdings/state"}
  }

  # The refill is a guess, the capacity is derived. See "Rate limits and chain
  # reference" in `Raxol.Web3.Backend.Canton`.
  @rate_limit [capacity: 4, refill_per_second: 0.2]

  @content_type {"content-type", "application/json"}

  # The probed endpoint table, as `{method, path}`.
  @doc false
  @spec paths() :: %{atom() => {:get | :post, String.t()}}
  def paths, do: @paths

  # The Scan source's scope: cache keys and cursors are bound to it.
  @doc false
  @spec scope(state()) :: Scope.t()
  def scope(state), do: Scope.of(state.scan_url, state.http_opts)

  # The token-bucket seed for both Canton upstreams.
  @doc false
  @spec rate_limit() :: keyword()
  def rate_limit, do: @rate_limit

  # GET a table endpoint. `class` names the cache class, or `nil` for a request
  # that must not be cached. The key fragment is built from the endpoint's own path and its own
  # parameters, never from an assembled URI, which is what keeps a credential
  # out of a cache key structurally rather than by review.
  @doc false
  @spec get(state(), atom(), map(), Raxol.Web3.TTL.class() | nil) ::
          {:ok, map()} | {:error, Backend.error()}
  def get(state, endpoint, query \\ %{}, class \\ nil) do
    {:get, path} = Map.fetch!(@paths, endpoint)

    state
    |> url(path, query)
    |> HTTP.get(scan_opts(state, path, query, class))
    |> Decode.json_object()
  end

  # POST a JSON request to a table endpoint.
  @doc false
  @spec post(state(), atom(), map(), Raxol.Web3.TTL.class() | nil) ::
          {:ok, map()} | {:error, Backend.error()}
  def post(state, endpoint, request, class) do
    {:post, path} = Map.fetch!(@paths, endpoint)

    opts =
      state
      |> scan_opts(path, request, class)
      |> Backend.put_header(@content_type)

    state
    |> url(path, %{})
    |> HTTP.post(Jason.encode!(request), opts)
    |> Decode.json_object()
  end

  # A path parameter rather than a table row, so it composes the path itself.
  # The id reaches here from a caller, so it goes through
  # `Raxol.Web3.Backend.PathSegment.encode/2`, whose allowlist admits no `/`,
  # `?`, `#`, `.` or `%`, so it can neither walk off `/updates/` nor become a
  # dot segment a resolving proxy would turn into the API root with the
  # credential attached.
  @doc false
  @spec get_update(state(), String.t()) :: {:ok, map()} | {:error, Backend.error()}
  def get_update(state, update_id) do
    with {:ok, segment} <- PathSegment.encode(update_id, "update_id") do
      state
      |> url("/updates/#{segment}", %{})
      |> HTTP.get(scan_opts(state, "/updates", %{"id" => update_id}, :transaction))
      |> Decode.json_object()
    end
  end

  defp scan_opts(state, path, fragment, class) do
    state.http_opts
    |> Keyword.put_new(:rate_limit, @rate_limit)
    |> Cache.opts(scope(state), state.cache?, {path, fragment}, class)
  end

  defp url(state, path, query) when map_size(query) == 0, do: state.scan_url <> path

  defp url(state, path, query) do
    "#{state.scan_url}#{path}?#{URI.encode_query(query)}"
  end

  # `:catalog` rather than `:chain_stats`: this body is governance and topology
  # reference data, it changes on a vote rather than on a round, and it is the
  # only place the current synchronizer migration id is published. 72 KB an hour
  # buys both `chain_info/1` and the migration id every party-scoped read needs.
  # The `/dso` body, `:catalog` cached.
  @doc false
  @spec dso(state()) :: {:ok, map()} | {:error, Backend.error()}
  def dso(state), do: get(state, :dso, %{}, :catalog)

  # Every super-validator declares a migration id for its sequencer, nested
  # inside a Daml-encoded map whose shape differs per node, so the highest id
  # published anywhere in the body is taken rather than one path walked. The
  # current migration is by definition the highest any node has moved to.
  # Measured 2026-09-14: every id in the body is "4".
  #
  # A pinned id short-circuits the read rather than overriding it afterwards,
  # so reading a historical migration deliberately costs no 72 KB fetch.
  # The pinned migration id, or the highest one `/dso` publishes.
  @doc false
  @spec resolve_migration(state()) :: {:ok, non_neg_integer()} | {:error, Backend.error()}
  def resolve_migration(%{migration_id: id}) when is_integer(id), do: {:ok, id}

  def resolve_migration(state) do
    with {:ok, body} <- dso(state) do
      body |> collect_migration_ids() |> Enum.max(fn -> nil end) |> highest_migration()
    end
  end

  defp highest_migration(nil), do: {:error, {:decode_failed, :migration_id}}
  defp highest_migration(id) when is_integer(id), do: {:ok, id}

  defp collect_migration_ids(%{} = map) do
    own = map |> Map.get("migrationId") |> int() |> List.wrap()
    own ++ Enum.flat_map(Map.values(map), &collect_migration_ids/1)
  end

  defp collect_migration_ids(list) when is_list(list) do
    Enum.flat_map(list, &collect_migration_ids/1)
  end

  defp collect_migration_ids(_scalar), do: []

  # Both party-scoped reads are as-of a snapshot, so the snapshot has to be
  # resolved first: a migration id from the DSO body and the latest snapshot
  # record time at or before now. `before` is truncated to the hour so the cache
  # key is stable for one, which is safe because snapshots land daily (measured
  # 2026-09-14: midnight for migration 4, noon for migration 0) and `before` is
  # inclusive.
  # The latest ACS snapshot at or before this hour, as request parameters.
  @doc false
  @spec snapshot(state()) :: {:ok, snapshot()} | {:error, Backend.error()}
  def snapshot(state) do
    with {:ok, migration} <- resolve_migration(state),
         query = %{"before" => hour_boundary(), "migration_id" => migration},
         {:ok, body} <- get(state, :acs_snapshot, query, :catalog),
         {:ok, record_time} <- fetch_record_time(body) do
      {:ok, %{"migration_id" => migration, "record_time" => record_time}}
    end
  end

  defp fetch_record_time(%{"record_time" => record_time}) when is_binary(record_time) do
    {:ok, record_time}
  end

  defp fetch_record_time(_body), do: {:error, {:decode_failed, :acs_snapshot}}

  defp hour_boundary do
    DateTime.utc_now()
    |> DateTime.truncate(:second)
    |> Map.merge(%{minute: 0, second: 0})
    |> DateTime.to_iso8601()
  end
end
