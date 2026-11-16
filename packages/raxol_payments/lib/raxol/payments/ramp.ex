defmodule Raxol.Payments.Ramp do
  @moduledoc """
  Validated Elixir binding for canonical `ramp/1` messages.

  Decode accepts JSON or maps with string keys. Encode revalidates structs and
  emits snake_case JSON. All errors are bounded codes; input is never returned.
  Amounts remain unsigned canonical atomic strings, including beyond 2^53.
  """
  alias Raxol.Payments.Ramp.{Coherence, Schema}

  @modules %{
    "offer" => __MODULE__.Offer,
    "intent" => __MODULE__.Intent,
    "preview" => __MODULE__.Preview,
    "snapshot" => __MODULE__.Snapshot,
    "command" => __MODULE__.Command,
    "error" => __MODULE__.Error
  }

  @spec atomic(term()) :: {:ok, String.t()} | {:error, :invalid_request}
  def atomic(value) when is_binary(value) do
    if Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value),
      do: {:ok, value},
      else: {:error, :invalid_request}
  end

  def atomic(_), do: {:error, :invalid_request}

  @spec decode(term()) :: {:ok, struct()} | {:error, atom()}
  def decode(json) when is_binary(json) and byte_size(json) <= 262_144 do
    case Jason.decode(json) do
      {:ok, value} -> decode(value)
      _ -> {:error, :invalid_request}
    end
  end

  def decode(value) when is_map(value) and not is_struct(value) do
    cond do
      not Schema.bounded?(value) ->
        {:error, :invalid_request}

      Map.has_key?(value, "contract_version") and value["contract_version"] != "ramp/1" ->
        {:error, :unsupported_version}

      true ->
        parse(value)
    end
  end

  def decode(_), do: {:error, :invalid_request}

  @doc "Canonical unsigned atomic-unit string; never accepts numeric JSON values."
  def atomic?(value) when is_binary(value), do: Regex.match?(~r/\A(0|[1-9][0-9]*)\z/, value)
  def atomic?(_), do: false

  @spec encode(struct()) :: {:ok, String.t()} | {:error, atom()}
  def encode(%module{} = value)
      when module in [
             __MODULE__.Offer,
             __MODULE__.Intent,
             __MODULE__.Preview,
             __MODULE__.Snapshot,
             __MODULE__.Command,
             __MODULE__.Error
           ] do
    with {:ok, clean} <- decode(to_wire(value)), do: Jason.encode(to_wire(clean))
  end

  def encode(_), do: {:error, :invalid_request}

  @doc "Returns the validated string-key wire map of a decoded message."
  def to_wire(%_{} = value) do
    value
    |> Map.from_struct()
    |> Enum.reject(fn {_, v} -> is_nil(v) end)
    |> Map.new(fn {k, v} -> {Atom.to_string(k), v} end)
  end

  defp parse(value) do
    with {:ok, clean} <- Schema.parse(value),
         true <- Coherence.valid?(clean) do
      module = Map.fetch!(@modules, clean["kind"])
      fields = Map.keys(module.__struct__()) -- [:__struct__]
      {:ok, struct!(module, Map.new(fields, &{&1, Map.get(clean, Atom.to_string(&1))}))}
    else
      _ -> {:error, :invalid_request}
    end
  end
end
