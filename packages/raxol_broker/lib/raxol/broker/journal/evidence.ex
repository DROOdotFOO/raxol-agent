defmodule Raxol.Broker.Journal.Evidence do
  @moduledoc """
  Writerless, allowlisted JSON evidence from a verified broker journal.

  This is recorded evidence, never live certification. Neither the journal's
  hash chain nor a recorded resolution proves transport provenance, complete
  cursor traversal, or the current broker state. Missing evidence remains
  `UNVERIFIED`. Identifiers use export-local sequential pseudonyms; raw
  responses, amounts, strategy names, prompts and other free text are omitted.
  """

  alias Raxol.Agent.Journal.FileStore
  alias Raxol.Broker.{Intent, Journal}
  alias Raxol.Broker.Journal.Groups

  @intent_kinds Enum.map(Intent.kinds(), &Atom.to_string/1)
  @unverified "UNVERIFIED"
  @states ~w(pending queued unconfirmed confirmed partially_filled filled rejected canceled cancelled failed expired approved auto_approved auto-approved declined pending_cancel)
  @outcomes ~w(placed pending_approval failed unknown deny absent approved declined expired)
  @stages ~w(intent review verdict approval placing order resolve fill)

  @doc "Read verified records without opening a writer or starting a client."
  @spec run(Path.t(), Date.t()) :: {:ok, map()} | {:error, term()}
  def run(path, %Date{} = date) do
    path = Path.expand(path)
    {base, session} = Journal.location(path)

    with true <- File.dir?(path) || {:error, :no_journal},
         :ok <- readable_anchor(path),
         :ok <- verified(FileStore.verify_session(session, base_dir: base)),
         {:ok, records} <- FileStore.read_records(session, base_dir: base) do
      {:ok, summarize(records, date)}
    end
  rescue
    _error in [File.Error] -> {:error, :unreadable_journal}
  end

  defp readable_anchor(path) do
    with {:ok, metadata} <- File.read(Path.join(path, "meta.json")),
         {:ok, %{"chain" => true}} <- Jason.decode(metadata),
         {:ok, anchor} <- File.read(Path.join(path, "HEAD")),
         {:ok, %{"offset" => offset, "tip_hash" => tip}} <- Jason.decode(anchor),
         true <- is_integer(offset) and offset >= 0 and is_binary(tip),
         {:ok, _entries} <- File.ls(Path.join(path, "journal")) do
      :ok
    else
      _invalid -> {:error, :unreadable_journal}
    end
  end

  defp verified(:ok), do: :ok
  defp verified({:broken, offset}), do: {:error, {:broken, offset}}
  defp verified({:error, _reason} = error), do: error

  defp summarize(records, date) do
    {groups, fills} = Groups.fold(records)
    day_fills = Enum.filter(fills, &on_day?(&1["at"], date))
    filled_ids = MapSet.new(Enum.flat_map(day_fills, &order_ids/1))

    groups =
      Enum.filter(groups, fn group ->
        Enum.any?(group.records, &on_day?(&1["at"], date)) or
          Enum.any?(group.records, fn record ->
            Enum.any?(order_ids(record), &MapSet.member?(filled_ids, &1))
          end)
      end)

    selected_ids =
      MapSet.new(Enum.flat_map(groups, &Enum.flat_map(&1.records, fn r -> order_ids(r) end)))

    fills =
      Enum.filter(fills, fn fill ->
        on_day?(fill["at"], date) or
          Enum.any?(order_ids(fill), &MapSet.member?(selected_ids, &1))
      end)

    report = %{
      "schema_version" => 1,
      "date" => Date.to_iso8601(date),
      "scope" => "UTC activity and linked recorded history",
      "journal_integrity" => "VERIFIED",
      "live_transport" => @unverified,
      "cursor_traversal" => @unverified,
      "current_broker_state" => @unverified,
      "result" => @unverified,
      "groups" => Enum.map(groups, &group_summary(&1, fills)),
      "fills" => Enum.map(fills, &fill_summary(&1, groups))
    }

    {report, _identifiers} = pseudonymize(report, %{})
    report
  end

  defp group_summary(group, fills) do
    ids = MapSet.new(Enum.flat_map(group.records, &order_ids/1))

    linked_fills =
      Enum.filter(fills, &Enum.any?(order_ids(&1), fn id -> MapSet.member?(ids, id) end))

    stages =
      Enum.map(group.records, & &1["type"]) ++ if(linked_fills == [], do: [], else: ["fill"])

    events = Enum.flat_map(group.records, &event/1)

    %{
      "group_id" => identifier("group", group.id),
      "stages" => Map.new(@stages, &{&1, if(&1 in stages, do: "RECORDED", else: @unverified)}),
      "events" => events,
      "final_recorded_outcome" => final_outcome(group.records),
      "final_recorded_state" => final_state(group.records),
      "current_state" => @unverified
    }
  end

  defp event(%{"type" => "intent"} = record) do
    intent = map(record["intent"])

    [
      base(record)
      |> Map.merge(%{
        "intent_id" => identifier("intent", intent["id"]),
        "intent_kind" => allowed(intent["kind"], @intent_kinds),
        "side" => allowed(intent["side"], ~w(buy sell)),
        "symbol_id" => identifier("symbol", intent["symbol"]),
        "order_id" => identifier("order", intent["order_id"]),
        "approval_id" => identifier("approval", map(intent["params"])["approval_id"]),
        "mode" => allowed(record["mode"], ~w(dry_run armed))
      })
    ]
  end

  defp event(%{"type" => "verdict"} = record) do
    [
      base(record)
      |> Map.merge(%{
        "phase" => allowed(record["phase"], ~w(pre_review post_review)),
        "action" => allowed(map(record["result"])["action"], ~w(allow ask deny))
      })
    ]
  end

  defp event(%{"type" => "review"} = record) do
    response = map(record["response"])

    [
      base(record)
      |> Map.merge(%{
        "customer_approval_required" => boolean(response["customer_approval_required"]),
        "identifiers" => response_identifiers(response)
      })
    ]
  end

  defp event(%{"type" => "approval"} = record) do
    [
      base(record)
      |> Map.merge(%{
        "decision" => allowed(record["decision"], ~w(approved declined)),
        "actor_id" => identifier("actor", record["by"])
      })
    ]
  end

  defp event(%{"type" => "placing"} = record), do: [base(record)]

  defp event(%{"type" => "order"} = record) do
    [
      base(record)
      |> Map.merge(%{
        "outcome" => allowed(record["status"], @outcomes),
        "state" => response_state(record["response"]),
        "identifiers" => response_identifiers(record["response"])
      })
    ]
  end

  defp event(%{"type" => "resolve"} = record) do
    detail = map(record["detail"])

    [
      base(record)
      |> Map.merge(%{
        "outcome" => allowed(record["resolution"], @outcomes),
        "state" => allowed(detail["state"], @states),
        "identifiers" => identifiers(detail),
        "cursor_traversal" => @unverified
      })
    ]
  end

  defp event(%{"type" => "close"} = record),
    do: [Map.put(base(record), "outcome", allowed(record["outcome"], @outcomes))]

  defp event(_record), do: []

  defp base(record), do: %{"stage" => record["type"], "at" => timestamp(record["at"])}

  defp fill_summary(record, groups) do
    fill = map(record["fill"])
    order_id = fill["order_id"]

    linked =
      Enum.filter(groups, fn group ->
        is_binary(order_id) and Enum.any?(group.records, &(order_id in order_ids(&1)))
      end)

    %{
      "at" => timestamp(record["at"]),
      "order_id" => identifier("order", order_id),
      "symbol_id" => identifier("symbol", fill["symbol"]),
      "side" => allowed(fill["side"], ~w(buy sell)),
      "group_ids" => Enum.map(linked, &identifier("group", &1.id)),
      "linkage" => if(linked == [], do: @unverified, else: "RECORDED_IDENTIFIER_MATCH"),
      "current_state" => @unverified
    }
  end

  defp final_outcome(records) do
    records
    |> Enum.reverse()
    |> Enum.find_value(@unverified, fn
      %{"type" => "resolve", "resolution" => value} -> allowed(value, @outcomes)
      %{"type" => "order", "status" => value} -> allowed(value, @outcomes)
      %{"type" => "close", "outcome" => value} -> allowed(value, @outcomes)
      %{"type" => "verdict", "result" => %{"action" => "deny"}} -> "deny"
      %{"type" => "approval", "decision" => "declined"} -> "declined"
      _record -> nil
    end)
  end

  defp final_state(records) do
    records
    |> Enum.reverse()
    |> Enum.find_value(@unverified, fn
      %{"type" => "resolve"} = record -> allowed(map(record["detail"])["state"], @states)
      %{"type" => "order"} = record -> response_state(record["response"])
      %{"type" => "close"} -> @unverified
      _record -> nil
    end)
  end

  defp order_ids(%{"type" => "fill"} = record),
    do: binary_list(map(record["fill"])["order_id"])

  defp order_ids(%{"type" => "resolve"} = record),
    do: binary_list(map(record["detail"])["order_id"])

  defp order_ids(%{"type" => "order"} = record) do
    record["response"] |> response_body() |> Map.get("order_id") |> binary_list()
  end

  defp order_ids(_record), do: []

  defp binary_list(value) when is_binary(value) and value != "", do: [value]
  defp binary_list(_value), do: []

  defp response_state(response), do: allowed(response_body(response)["state"], @states)
  defp response_identifiers(response), do: response |> response_body() |> identifiers()

  defp identifiers(body) do
    args = map(body["args"])

    %{
      "account_id" => identifier("account", body["account_number"] || args["account_number"]),
      "order_id" => identifier("order", body["order_id"]),
      "approval_id" => identifier("approval", body["approval_id"]),
      "ref_id" => identifier("ref", body["ref_id"] || args["ref_id"])
    }
  end

  defp response_body(%{"content" => content}) when is_list(content) do
    Enum.find_value(content, %{}, fn
      %{"type" => "text", "text" => text} when is_binary(text) ->
        case Jason.decode(text) do
          {:ok, %{"data" => %{} = data}} -> data
          {:ok, %{} = body} -> body
          _invalid -> nil
        end

      _block ->
        nil
    end)
  end

  defp response_body(_response), do: %{}

  defp identifier(type, value) when is_binary(value) and value != "",
    do: {:identifier, type, value}

  defp identifier(type, value) when is_integer(value),
    do: {:identifier, type, Integer.to_string(value)}

  defp identifier(_type, _value), do: nil

  defp pseudonymize({:identifier, type, value}, identifiers) do
    key = {type, value}

    case Map.fetch(identifiers, key) do
      {:ok, label} ->
        {label, identifiers}

      :error ->
        label = "#{type}-#{map_size(identifiers) + 1}"
        {label, Map.put(identifiers, key, label)}
    end
  end

  defp pseudonymize(map, identifiers) when is_map(map) do
    {pairs, identifiers} =
      map
      |> Enum.sort_by(&elem(&1, 0))
      |> Enum.map_reduce(identifiers, fn {key, value}, acc ->
        {value, acc} = pseudonymize(value, acc)
        {{key, value}, acc}
      end)

    {Map.new(pairs), identifiers}
  end

  defp pseudonymize(list, identifiers) when is_list(list),
    do: Enum.map_reduce(list, identifiers, &pseudonymize/2)

  defp pseudonymize(value, identifiers), do: {value, identifiers}

  defp map(value) when is_map(value), do: value
  defp map(_value), do: %{}
  defp allowed(value, values), do: if(value in values, do: value, else: @unverified)
  defp boolean(value) when is_boolean(value), do: value
  defp boolean(_value), do: @unverified

  defp timestamp(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_iso8601(at)
      _invalid -> @unverified
    end
  end

  defp timestamp(_value), do: @unverified

  defp on_day?(value, date) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, at, _offset} -> DateTime.to_date(at) == date
      _invalid -> false
    end
  end

  defp on_day?(_value, _date), do: false
end
