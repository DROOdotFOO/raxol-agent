defmodule Raxol.AgentClientProtocol.Schema.Ext do
  @moduledoc """
  Extension types for ACP protocol extensibility.

  ACP reserves method names prefixed with `_` (e.g. `_myext/doThing`) for
  vendor/experimental extensions that aren't part of the core spec. Peers
  that don't understand an extension method still parse it uniformly:

    * `Ext.ExtRequest` — an arbitrary `_`-prefixed request (expects a reply).
    * `Ext.ExtResponse` — the reply to an `ExtRequest`. Its wire
      representation is *transparent*: the response body IS the wrapped
      `data` term, not `%{"data" => ...}` — see the module doc there.
    * `Ext.ExtNotification` — an arbitrary `_`-prefixed notification (no
      reply expected).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """

  @typedoc "Free-form vendor metadata carried alongside a typed payload."
  @type meta :: %{optional(String.t()) => term()} | nil

  @known_request_keys ["method", "params"]

  @doc false
  # Shared by ExtRequest/ExtNotification: split a raw wire map into its two
  # known fields plus a `_meta` bucket holding everything else, so unknown
  # wire fields round-trip through decode -> encode instead of being
  # silently dropped (forward-compat pass-through).
  @spec split_known(map(), [String.t()]) :: {term(), term(), map()}
  def split_known(map, known_keys) when is_map(map) do
    method = Map.get(map, "method")
    params = Map.get(map, "params")
    {method, params, Raxol.AgentClientProtocol.Schema.AgentTypes.extract_meta(map, known_keys)}
  end

  @doc false
  @spec known_request_keys() :: [String.t()]
  def known_request_keys, do: @known_request_keys
end

defmodule Raxol.AgentClientProtocol.Schema.Ext.ExtRequest do
  @moduledoc """
  An arbitrary `_`-prefixed extension request, not part of the core ACP
  spec. Carries the raw JSON-RPC `method` name and already-decoded `params`.
  """

  alias Raxol.AgentClientProtocol.Schema.Ext

  @type t :: %__MODULE__{
          method: String.t(),
          params: term(),
          _meta: Ext.meta()
        }

  @enforce_keys [:method, :params]
  defstruct method: nil, params: nil, _meta: %{}

  @doc "Build an ExtRequest from a method name and its params."
  @spec new(String.t(), term()) :: t()
  def new(method, params) when is_binary(method), do: %__MODULE__{method: method, params: params}

  @doc """
  Decode an ExtRequest from a raw wire map (`%{"method" => ..., "params" =>
  ...}`). Total: never raises, unknown fields fold into `_meta`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_ext_request}
  def from_map(%{"method" => method} = map) when is_binary(method) do
    {_method, params, meta} = Ext.split_known(map, Ext.known_request_keys())
    {:ok, %__MODULE__{method: method, params: params, _meta: meta}}
  end

  def from_map(_map), do: {:error, :invalid_ext_request}
end

defmodule Raxol.AgentClientProtocol.Schema.Ext.ExtNotification do
  @moduledoc """
  An arbitrary `_`-prefixed extension notification, not part of the core
  ACP spec. No reply is expected.
  """

  alias Raxol.AgentClientProtocol.Schema.Ext

  @type t :: %__MODULE__{
          method: String.t(),
          params: term(),
          _meta: Ext.meta()
        }

  @enforce_keys [:method, :params]
  defstruct method: nil, params: nil, _meta: %{}

  @doc "Build an ExtNotification from a method name and its params."
  @spec new(String.t(), term()) :: t()
  def new(method, params) when is_binary(method), do: %__MODULE__{method: method, params: params}

  @doc """
  Decode an ExtNotification from a raw wire map. Total: never raises,
  unknown fields fold into `_meta`.
  """
  @spec from_map(map()) :: {:ok, t()} | {:error, :invalid_ext_notification}
  def from_map(%{"method" => method} = map) when is_binary(method) do
    {_method, params, meta} = Ext.split_known(map, Ext.known_request_keys())
    {:ok, %__MODULE__{method: method, params: params, _meta: meta}}
  end

  def from_map(_map), do: {:error, :invalid_ext_notification}
end

defmodule Raxol.AgentClientProtocol.Schema.Ext.ExtResponse do
  @moduledoc """
  The reply to an `ExtRequest`.

  Unlike most ACP types, `ExtResponse`'s wire representation is
  *transparent*: the JSON-RPC result body IS the wrapped `data` term
  verbatim, not an envelope: its shape is defined by the extension.
  `empty/0` is the "no extension implemented" response.
  """

  @type t :: %__MODULE__{
          data: term()
        }

  defstruct data: nil

  @doc "Wrap an arbitrary term as an ExtResponse."
  @spec new(term()) :: t()
  def new(data), do: %__MODULE__{data: data}

  @doc """
  An `ExtResponse` with no data.
  """
  @spec empty() :: t()
  def empty, do: %__MODULE__{data: nil}

  @doc "The raw wire value for this response: just the wrapped `data`, unwrapped."
  @spec to_json(t()) :: term()
  def to_json(%__MODULE__{data: data}), do: data

  @doc """
  Wrap an already-decoded wire value as an ExtResponse. Total and infallible
  by construction — any term is a valid `data` payload.
  """
  @spec from_json(term()) :: {:ok, t()}
  def from_json(data), do: {:ok, %__MODULE__{data: data}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Ext.ExtRequest do
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtRequest

  def encode(%ExtRequest{method: method, params: params, _meta: meta}, opts) do
    (meta || %{})
    |> Map.merge(%{"method" => method, "params" => params})
    |> Jason.Encode.map(opts)
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Ext.ExtNotification do
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtNotification

  def encode(%ExtNotification{method: method, params: params, _meta: meta}, opts) do
    (meta || %{})
    |> Map.merge(%{"method" => method, "params" => params})
    |> Jason.Encode.map(opts)
  end
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.Ext.ExtResponse do
  alias Raxol.AgentClientProtocol.Schema.Ext.ExtResponse

  def encode(%ExtResponse{data: data}, opts) do
    Jason.Encode.value(data, opts)
  end
end
