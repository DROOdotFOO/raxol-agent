defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption do
  @moduledoc """
  A possible value for a `select`-kind session configuration option.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["value", "name", "description", "_meta"]

  @type t :: %__MODULE__{
          value: term(),
          name: String.t(),
          description: String.t() | nil,
          _meta: map()
        }

  @enforce_keys [:value, :name]
  defstruct value: nil, name: nil, description: nil, _meta: %{}

  @spec new(term(), String.t()) :: t()
  def new(value, name), do: %__MODULE__{value: value, name: name}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = o) do
    %{"value" => o.value, "name" => o.name}
    |> AgentTypes.maybe_put("description", o.description)
    |> AgentTypes.put_meta(o._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, value} <- AgentTypes.fetch(map, "value"),
         {:ok, name} <- AgentTypes.fetch(map, "name") do
      {:ok,
       %__MODULE__{
         value: value,
         name: name,
         description: Map.get(map, "description"),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_option, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectGroup do
  @moduledoc """
  A named group of `SessionConfigSelectOption`s.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption

  @known_keys ["group", "name", "options", "_meta"]

  @type t :: %__MODULE__{
          group: String.t(),
          name: String.t(),
          options: [SessionConfigSelectOption.t()],
          _meta: map()
        }

  @enforce_keys [:group, :name, :options]
  defstruct group: nil, name: nil, options: nil, _meta: %{}

  @spec new(String.t(), String.t(), [SessionConfigSelectOption.t()]) :: t()
  def new(group, name, options),
    do: %__MODULE__{group: group, name: name, options: options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = g) do
    %{
      "group" => g.group,
      "name" => g.name,
      "options" => Enum.map(g.options, &SessionConfigSelectOption.to_json/1)
    }
    |> AgentTypes.put_meta(g._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, group} <- AgentTypes.fetch(map, "group"),
         {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, raw_options} <- AgentTypes.fetch(map, "options"),
         {:ok, options} <-
           AgentTypes.decode_list(
             raw_options,
             &SessionConfigSelectOption.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         group: group,
         name: name,
         options: options,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_group, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOptions do
  @moduledoc """
  Possible values for a `select`-kind session configuration option: an
  untagged union of either a flat list of options (`{:ungrouped, [...]}`) or
  a list of groups (`{:grouped, [...]}`), distinguished on decode by whether
  the first list element has a `"group"` key.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigSelectGroup,
    SessionConfigSelectOption
  }

  @type t ::
          {:ungrouped, [SessionConfigSelectOption.t()]}
          | {:grouped, [SessionConfigSelectGroup.t()]}

  @spec to_json(t()) :: [map()]
  def to_json({:ungrouped, options}),
    do: Enum.map(options, &SessionConfigSelectOption.to_json/1)

  def to_json({:grouped, groups}),
    do: Enum.map(groups, &SessionConfigSelectGroup.to_json/1)

  @doc "Total: never raises. Non-list input returns `{:error, _}`."
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json([]), do: {:ok, {:ungrouped, []}}

  def from_json([first | _] = list) when is_list(list) and is_map(first) do
    if Map.has_key?(first, "group") do
      case AgentTypes.decode_list(list, &SessionConfigSelectGroup.from_json/1) do
        {:ok, groups} -> {:ok, {:grouped, groups}}
        error -> error
      end
    else
      case AgentTypes.decode_list(list, &SessionConfigSelectOption.from_json/1) do
        {:ok, options} -> {:ok, {:ungrouped, options}}
        error -> error
      end
    end
  end

  def from_json(other),
    do: {:error, {:invalid_session_config_select_options, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect do
  @moduledoc """
  A single-value selector (dropdown) session configuration option payload.

  Has no `_meta`: it is flattened into the parent `SessionConfigOption`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOptions

  @type t :: %__MODULE__{
          current_value: term(),
          options: SessionConfigSelectOptions.t()
        }

  @enforce_keys [:current_value, :options]
  defstruct current_value: nil, options: nil

  @spec new(term(), SessionConfigSelectOptions.t()) :: t()
  def new(current_value, options),
    do: %__MODULE__{current_value: current_value, options: options}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = s) do
    %{
      "currentValue" => s.current_value,
      "options" => SessionConfigSelectOptions.to_json(s.options)
    }
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, current_value} <- AgentTypes.fetch(map, "currentValue"),
         {:ok, raw_options} <- AgentTypes.fetch(map, "options"),
         {:ok, options} <- SessionConfigSelectOptions.from_json(raw_options) do
      {:ok, %__MODULE__{current_value: current_value, options: options}}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_config_select, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOptionCategory do
  @moduledoc """
  Semantic category for a session configuration option.
  """

  @type t :: :mode | :model | :thought_level | :other

  @spec to_json(t()) :: String.t()
  def to_json(:mode), do: "mode"
  def to_json(:model), do: "model"
  def to_json(:thought_level), do: "thought_level"
  def to_json(:other), do: "other"

  @doc """
  Unrecognized strings decode to `:other` (forward-compatible).
  """
  @spec from_json(term()) :: {:ok, t()}
  def from_json("mode"), do: {:ok, :mode}
  def from_json("model"), do: {:ok, :model}
  def from_json("thought_level"), do: {:ok, :thought_level}
  def from_json(_other), do: {:ok, :other}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigKind do
  @moduledoc """
  Type-specific session configuration option payload: a tagged union by the
  wire `"type"` field. Currently only `:select` is defined by the spec.
  """

  alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect

  @type t :: {:select, SessionConfigSelect.t()}

  @spec to_json(t()) :: map()
  def to_json({:select, select}),
    do: Map.put(SessionConfigSelect.to_json(select), "type", "select")

  @doc """
  A missing or unrecognized `"type"` returns `{:error, _}`.
  """
  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"type" => "select"} = map) do
    case SessionConfigSelect.from_json(map) do
      {:ok, select} -> {:ok, {:select, select}}
      error -> error
    end
  end

  def from_json(%{"type" => other}),
    do: {:error, {:unsupported_session_config_kind, other}}

  def from_json(map) when is_map(map), do: {:error, {:missing_field, "type"}}
  def from_json(other), do: {:error, {:invalid_session_config_kind, other}}
end

defmodule Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption do
  @moduledoc """
  A session configuration option selector and its current state. The
  `kind`-specific payload (currently only `select`) is flattened directly
  into this struct's top-level wire object alongside `id`/`name`/etc.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    SessionConfigKind,
    SessionConfigOptionCategory
  }

  # "type"/"currentValue"/"options" belong to the flattened `kind` payload.
  @known_keys [
    "id",
    "name",
    "description",
    "category",
    "type",
    "currentValue",
    "options",
    "_meta"
  ]

  @type t :: %__MODULE__{
          id: String.t(),
          name: String.t(),
          description: String.t() | nil,
          category: SessionConfigOptionCategory.t() | nil,
          kind: SessionConfigKind.t(),
          _meta: map()
        }

  @enforce_keys [:id, :name, :kind]
  defstruct id: nil,
            name: nil,
            description: nil,
            category: nil,
            kind: nil,
            _meta: %{}

  @spec new(String.t(), String.t(), SessionConfigKind.t()) :: t()
  def new(id, name, kind), do: %__MODULE__{id: id, name: name, kind: kind}

  @doc "Convenience: build a `select`-kind option directly."
  @spec select(String.t(), String.t(), term(), term()) :: t()
  def select(id, name, current_value, options) do
    alias Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect
    new(id, name, {:select, SessionConfigSelect.new(current_value, options)})
  end

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = o) do
    SessionConfigKind.to_json(o.kind)
    |> Map.merge(%{"id" => o.id, "name" => o.name})
    |> AgentTypes.maybe_put("description", o.description)
    |> AgentTypes.put_encoded("category", o.category, &SessionConfigOptionCategory.to_json/1)
    |> AgentTypes.put_meta(o._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, id} <- AgentTypes.fetch(map, "id"),
         {:ok, name} <- AgentTypes.fetch(map, "name"),
         {:ok, kind} <- SessionConfigKind.from_json(map),
         {:ok, category} <-
           AgentTypes.decode_optional(
             map,
             "category",
             &SessionConfigOptionCategory.from_json/1
           ) do
      {:ok,
       %__MODULE__{
         id: id,
         name: name,
         description: Map.get(map, "description"),
         category: category,
         kind: kind,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_config_option, other}}
end

defimpl Jason.Encoder,
  for: [
    Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectOption,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelectGroup,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigSelect,
    Raxol.AgentClientProtocol.Schema.Unstable.SessionConfigOption
  ] do
  def encode(%mod{} = val, opts), do: val |> mod.to_json() |> Jason.Encode.map(opts)
end
