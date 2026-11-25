defmodule Raxol.Earn.Transport.SSE.Parser do
  @moduledoc """
  Pure SSE wire-format parser used by `Raxol.Earn.Transport.SSE`.

  Pure: `feed/3` takes and returns the stream state (`new/0`), and the
  transport threads it between chunks.
  """

  @doc """
  Split a chunk of SSE bytes into complete frames + a remainder.

  Frames are separated by `\\n\\n`. The trailing fragment (if any) is
  returned as the second element so the caller can prepend it to the
  next chunk.

      iex> Raxol.Earn.Transport.SSE.Parser.split_frames("data: 1\\n\\ndata: 2\\n\\n")
      {["data: 1", "data: 2"], ""}

      iex> Raxol.Earn.Transport.SSE.Parser.split_frames("data: a\\n\\ndata: b")
      {["data: a"], "data: b"}
  """
  @spec split_frames(binary()) :: {[binary()], binary()}
  def split_frames(text) when is_binary(text) do
    parts = String.split(text, "\n\n")

    case parts do
      [] -> {[], ""}
      [partial] -> {[], partial}
      list -> {Enum.drop(list, -1), List.last(list)}
    end
  end

  @typedoc """
  Stream state between chunks: the unterminated tail, and whether the parser
  is discarding an event that outgrew the limit.
  """
  @type state :: %{tail: binary(), skipping?: boolean(), cr_pending?: boolean()}

  @spec new() :: state()
  def new, do: %{tail: "", skipping?: false, cr_pending?: false}

  @doc """
  Feed one chunk. Returns the entries it completes, in order, how many events
  it dropped for exceeding `max_bytes`, and the next state. Frames without
  data or with invalid JSON are skipped.

  CR and CRLF line endings are folded to LF. A CR that ends a chunk counts as
  a line end at once, and an LF opening the next chunk is then dropped as the
  second half of a CRLF. An event whose unterminated
  part grows past `max_bytes` is discarded through its boundary and the stream
  carries on with the next one. Only the seam between the tail and the new
  chunk is searched for a boundary, so a long tail is not rescanned per chunk.
  """
  @spec feed(state(), binary(), pos_integer()) :: {[map()], non_neg_integer(), state()}
  def feed(state, chunk, max_bytes) when is_binary(chunk) do
    text = if state.cr_pending?, do: drop_leading_lf(chunk), else: chunk
    {entries, dropped, next} = advance(state, fold_line_endings(text), max_bytes)
    {entries, dropped, Map.put(next, :cr_pending?, cr_pending?(chunk, state.cr_pending?))}
  end

  defp drop_leading_lf("\n" <> rest), do: rest
  defp drop_leading_lf(chunk), do: chunk

  # An empty chunk leaves a pending CR pending.
  defp cr_pending?("", pending?), do: pending?
  defp cr_pending?(chunk, _pending?), do: String.ends_with?(chunk, "\r")

  defp advance(%{skipping?: true, tail: tail}, chunk, max_bytes) do
    seam = tail <> chunk

    case :binary.match(seam, "\n\n") do
      {pos, 2} ->
        advance(
          %{tail: "", skipping?: false},
          binary_part(seam, pos + 2, byte_size(seam) - pos - 2),
          max_bytes
        )

      :nomatch ->
        {[], 0, %{tail: last_byte(seam), skipping?: true}}
    end
  end

  defp advance(%{tail: tail}, chunk, max_bytes) do
    {entries, rest} =
      if boundary_at_seam?(tail, chunk) do
        {frames, rest} = split_frames(tail <> chunk)
        {for(frame <- frames, {:ok, entry} <- [parse_frame(frame)], do: entry), rest}
      else
        {[], tail <> chunk}
      end

    if byte_size(rest) > max_bytes,
      do: {entries, 1, %{tail: last_byte(rest), skipping?: true}},
      else: {entries, 0, %{tail: rest, skipping?: false}}
  end

  defp fold_line_endings(text),
    do: text |> String.replace("\r\n", "\n") |> String.replace("\r", "\n")

  defp last_byte(""), do: ""
  defp last_byte(bin), do: binary_part(bin, byte_size(bin) - 1, 1)

  defp boundary_at_seam?(tail, chunk),
    do: :binary.match(last_byte(tail) <> chunk, "\n\n") != :nomatch

  @doc """
  Parse a single SSE frame's data field into a JSON map.

  - `data:` lines (with or without leading space) are concatenated.
  - `event:` / `id:` / other field lines are ignored.
  - The accumulated `data` is parsed as JSON; the value must be an
    object.
  """
  @spec parse_frame(binary()) :: {:ok, map()} | {:error, :no_data | :invalid_json}
  def parse_frame(frame) when is_binary(frame) do
    data =
      frame
      |> String.split("\n")
      |> Enum.flat_map(&extract_data_line/1)
      |> Enum.join("\n")

    case data do
      "" ->
        {:error, :no_data}

      json ->
        case Jason.decode(json) do
          {:ok, value} when is_map(value) -> {:ok, normalize(value)}
          _ -> {:error, :invalid_json}
        end
    end
  end

  defp extract_data_line("data: " <> rest), do: [rest]
  defp extract_data_line("data:" <> rest), do: [String.trim_leading(rest, " ")]
  defp extract_data_line(_), do: []

  @doc """
  Normalize the wire shape of an ACP SSE entry into the shape the Agent +
  SolverAgent consume. The Virtuals server sends system events as
  `%{"kind" => "system", "event" => %{"type" => "job.created", "provider" => ...,
  "onChainJobId" => ...}}`, but our dispatch matches `"event" => "job.created"`
  (a string) and reads top-level `jobId`/`provider`. So for system entries we hoist
  the nested event map's fields to the top level and replace `event` with its type
  string. Message entries already carry top-level `content`/`contentType`/`from`.
  Both get `jobId` lifted from `onChainJobId`. This is the single boundary where the
  wire shape meets our code (the gate drives the provider in-process and never hits
  this path, which is why the mismatch went unseen until a real marketplace job).

  Also reused when replaying `get_history/2` entries (raw server JSON) so the
  SolverAgent reattach path reads them through the same shape as the live stream.
  """
  @spec normalize(map()) :: map()
  def normalize(%{"kind" => "system", "event" => %{"type" => type} = ev} = entry) do
    entry
    |> Map.merge(ev)
    |> Map.put("event", type)
    |> Map.put("jobId", job_id(entry, ev))
  end

  def normalize(%{} = entry) do
    Map.put(entry, "jobId", job_id(entry, entry["event"]))
  end

  defp job_id(entry, ev) do
    entry["jobId"] || entry["job_id"] || entry["onChainJobId"] ||
      map_get(ev, "onChainJobId") || map_get(ev, "jobId")
  end

  defp map_get(%{} = m, k), do: m[k]
  defp map_get(_, _), do: nil
end
