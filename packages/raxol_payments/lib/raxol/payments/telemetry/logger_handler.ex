defmodule Raxol.Payments.Telemetry.LoggerHandler do
  @moduledoc """
  Stock `:telemetry` handler that pretty-prints payment events to
  `Logger`. Useful as a starter template -- copy + tailor for Datadog,
  OpenTelemetry, Phoenix.LiveDashboard, etc.

  Handles the three events emitted by `Raxol.Payments.Telemetry`:

    * `[:raxol, :payments, :spend]`       -> `:info`
    * `[:raxol, :payments, :over_budget]` -> `:warning`
    * `[:raxol, :payments, :freeze]`      -> `:warning` (frozen) or `:info` (unfrozen)

  ## Usage

      # In your application start/2:
      Raxol.Payments.Telemetry.LoggerHandler.attach()

  Detach with `Raxol.Payments.Telemetry.LoggerHandler.detach/0`.

  ## Customization

  The default formatter renders one structured line per event. It does
  not print caller data: a nested metadata map shows only its keys, a URL
  only its origin, and other compound values only their kind; top-level
  strings and numbers print as given. A custom formatter gets the raw terms
  and owns that redaction. To override:

      Raxol.Payments.Telemetry.LoggerHandler.attach(handler_id: "my-pay",
        formatter: &MyApp.format_pay_event/3)

  `formatter/3` receives `(event_name, measurements, metadata)` and
  returns the string passed to `Logger`.
  """

  require Logger

  alias Raxol.Payments.Redact
  alias Raxol.Payments.Telemetry

  @default_handler_id "raxol-payments-logger"

  @type formatter :: (event_name :: [atom()], measurements :: map(), metadata :: map() ->
                        iodata())

  @doc """
  Attach the handler to every event emitted by `Raxol.Payments.Telemetry`.

  Returns `:ok` on success or `{:error, :already_exists}` if a handler
  with the same id is already attached.
  """
  @spec attach(keyword()) :: :ok | {:error, :already_exists}
  def attach(opts \\ []) do
    handler_id = Keyword.get(opts, :handler_id, @default_handler_id)
    formatter = Keyword.get(opts, :formatter, &__MODULE__.default_format/3)

    :telemetry.attach_many(
      handler_id,
      Map.keys(Telemetry.events()),
      &__MODULE__.handle_event/4,
      %{formatter: formatter}
    )
  end

  @doc "Detach the default handler. Pass `handler_id` to detach a custom one."
  @spec detach(String.t()) :: :ok | {:error, :not_found}
  def detach(handler_id \\ @default_handler_id),
    do: :telemetry.detach(handler_id)

  @doc false
  def handle_event(event, measurements, metadata, %{formatter: formatter}) do
    line = formatter.(event, measurements, metadata)

    case event do
      [:raxol, :payments, :spend] -> Logger.info(line)
      [:raxol, :payments, :over_budget] -> Logger.warning(line)
      [:raxol, :payments, :freeze] -> log_freeze(metadata, line)
      _ -> Logger.info(line)
    end
  end

  defp log_freeze(%{frozen?: true}, line), do: Logger.warning(line)
  defp log_freeze(_, line), do: Logger.info(line)

  @doc """
  Default formatter: one-line structured rendering with the event name
  followed by sorted key/value pairs.
  """
  @spec default_format([atom()], map(), map()) :: iodata()
  def default_format(event, measurements, metadata) do
    [
      format_event(event),
      ?\s,
      format_measurements(measurements),
      ?\s,
      format_metadata(metadata)
    ]
  end

  defp format_event([:raxol, :payments, kind]), do: ["payments.", Atom.to_string(kind)]
  defp format_event(other), do: inspect(other)

  defp format_measurements(measurements) when map_size(measurements) == 0, do: "{}"

  defp format_measurements(%{amount: %Decimal{} = amount} = m) do
    rest = m |> Map.delete(:amount) |> kv_pairs()
    ["amount=", Decimal.to_string(amount, :normal) | rest]
  end

  defp format_measurements(m), do: kv_pairs(m)

  defp format_metadata(meta) when map_size(meta) == 0, do: ""
  defp format_metadata(meta), do: kv_pairs(meta)

  defp kv_pairs(map) do
    map
    |> Enum.sort_by(fn {k, _} -> to_string(k) end)
    |> Enum.map(fn {k, v} -> [?\s, to_string(k), ?=, format_value(v)] end)
  end

  # Metadata can hold whatever a caller attached to a spend. Scalars render
  # as themselves; a string that parses as a URL is cut to its origin, a map
  # is rendered by its keys, a tuple element by element (one level), and any
  # other compound term by its kind.
  defp format_value(%Decimal{} = v), do: Decimal.to_string(v, :normal)
  defp format_value(%DateTime{} = v), do: DateTime.to_iso8601(v)
  defp format_value(%NaiveDateTime{} = v), do: NaiveDateTime.to_iso8601(v)
  defp format_value(%Date{} = v), do: Date.to_iso8601(v)
  defp format_value(%module{}), do: "#" <> inspect(module)
  defp format_value(v) when is_map(v), do: ["%{", v |> Map.keys() |> keys(), "}"]

  defp format_value(v) when is_tuple(v),
    do: ["{", v |> Tuple.to_list() |> Enum.map(&scalar/1) |> Enum.intersperse(","), "}"]

  defp format_value(v), do: scalar(v)

  defp scalar(v) when is_binary(v), do: if(Redact.url?(v), do: Redact.url(v), else: v)
  defp scalar(v) when is_atom(v), do: Atom.to_string(v)
  defp scalar(v) when is_integer(v) or is_float(v), do: to_string(v)
  defp scalar(v) when is_pid(v) or is_reference(v) or is_port(v), do: inspect(v)
  defp scalar(%{}), do: "#map"
  defp scalar(v) when is_list(v), do: "#list"
  defp scalar(v) when is_tuple(v), do: "#tuple"
  defp scalar(_v), do: "#term"

  defp keys(keys), do: keys |> Enum.map(&key_name/1) |> Enum.sort() |> Enum.join(",")

  defp key_name(k) when is_atom(k) or is_binary(k) or is_integer(k), do: to_string(k)
  defp key_name(_k), do: "?"
end
