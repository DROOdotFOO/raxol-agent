defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras do
  @moduledoc """
  Param/result structs for the v1.19.0 methods `session/close`,
  `session/delete`, `logout`, `session/update` (the notification envelope) and
  `$/cancel_request`, taken from the pinned schema. They follow the
  `Schema.AgentTypes` decode conventions.

  `logout` has no request struct: its params carry only `_meta`, so its
  `MethodTable` row has `params: nil`.
  """

  alias Raxol.AgentClientProtocol.Rpc.RequestId
  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest do
  @moduledoc """
  Request parameters for `session/close`: closes an active session, best-
  effort cancelling any in-flight work first.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), _meta: map()}

  @enforce_keys [:session_id]
  defstruct session_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"sessionId" => r.session_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1) do
      {:ok, %__MODULE__{session_id: session_id, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_close_session_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionRequest

  def encode(%CloseSessionRequest{} = val, opts) do
    val |> CloseSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/close`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other), do: {:error, {:invalid_close_session_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CloseSessionResponse

  def encode(%CloseSessionResponse{} = val, opts) do
    val |> CloseSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest do
  @moduledoc """
  Request parameters for `session/delete`: deletes an existing session from
  `session/list`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["sessionId", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), _meta: map()}

  @enforce_keys [:session_id]
  defstruct session_id: nil, _meta: %{}

  @spec new(String.t()) :: t()
  def new(session_id), do: %__MODULE__{session_id: session_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"sessionId" => r.session_id}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1) do
      {:ok, %__MODULE__{session_id: session_id, _meta: AgentTypes.extract_meta(map, @known_keys)}}
    end
  end

  def from_json(other), do: {:error, {:invalid_delete_session_request, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionRequest

  def encode(%DeleteSessionRequest{} = val, opts) do
    val |> DeleteSessionRequest.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `session/delete`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other), do: {:error, {:invalid_delete_session_response, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.DeleteSessionResponse

  def encode(%DeleteSessionResponse{} = val, opts) do
    val |> DeleteSessionResponse.to_json() |> Jason.Encode.map(opts)
  end
end

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse do
  @moduledoc """
  The (empty, besides `_meta`) response to `logout`.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @type t :: %__MODULE__{_meta: map()}

  defstruct _meta: %{}

  @spec new() :: t()
  def new, do: %__MODULE__{}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r), do: AgentTypes.put_meta(%{}, r._meta)

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    {:ok, %__MODULE__{_meta: AgentTypes.extract_meta(map, ["_meta"])}}
  end

  def from_json(other), do: {:error, {:invalid_logout_response, other}}
end

defimpl Jason.Encoder, for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.LogoutResponse

  def encode(%LogoutResponse{} = val, opts) do
    val |> LogoutResponse.to_json() |> Jason.Encode.map(opts)
  end
end

# SessionNotification (session/update envelope)

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification do
  @moduledoc """
  The `session/update` notification envelope: `{sessionId, update, _meta}`,
  where `update` is the `Raxol.AgentClientProtocol.Schema.SessionUpdate`
  discriminated union.
  """

  alias Raxol.AgentClientProtocol.Schema.AgentTypes
  alias Raxol.AgentClientProtocol.Schema.SessionUpdate

  @known_keys ["sessionId", "update", "_meta"]

  @type t :: %__MODULE__{session_id: String.t(), update: SessionUpdate.t(), _meta: map()}

  @enforce_keys [:session_id, :update]
  defstruct session_id: nil, update: nil, _meta: %{}

  @spec new(String.t(), SessionUpdate.t()) :: t()
  def new(session_id, update), do: %__MODULE__{session_id: session_id, update: update}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    %{"sessionId" => r.session_id, "update" => SessionUpdate.to_json(r.update)}
    |> AgentTypes.put_meta(r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(map) when is_map(map) do
    with {:ok, session_id} <- AgentTypes.fetch(map, "sessionId", &is_binary/1),
         {:ok, raw_update} <- AgentTypes.fetch(map, "update"),
         {:ok, update} <- SessionUpdate.from_json(raw_update) do
      {:ok,
       %__MODULE__{
         session_id: session_id,
         update: update,
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    end
  end

  def from_json(other), do: {:error, {:invalid_session_notification, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.SessionNotification

  def encode(%SessionNotification{} = val, opts) do
    val |> SessionNotification.to_json() |> Jason.Encode.map(opts)
  end
end

# CancelRequestNotification ($/cancel_request)

defmodule Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification do
  @moduledoc """
  The protocol-level `$/cancel_request` notification: `{requestId, _meta}`,
  where `requestId` is a JSON-RPC request id (`null | integer | string`,
  see `Raxol.AgentClientProtocol.Rpc.RequestId`). Handled by the Connection before routing.
  """

  alias Raxol.AgentClientProtocol.Rpc.RequestId
  alias Raxol.AgentClientProtocol.Schema.AgentTypes

  @known_keys ["requestId", "_meta"]

  @type t :: %__MODULE__{request_id: RequestId.t(), _meta: map()}

  @enforce_keys [:request_id]
  defstruct request_id: nil, _meta: %{}

  @spec new(RequestId.t()) :: t()
  def new(request_id), do: %__MODULE__{request_id: request_id}

  @spec to_json(t()) :: map()
  def to_json(%__MODULE__{} = r) do
    AgentTypes.put_meta(%{"requestId" => RequestId.to_json(r.request_id)}, r._meta)
  end

  @spec from_json(term()) :: {:ok, t()} | {:error, term()}
  def from_json(%{"requestId" => id} = map) do
    if RequestId.valid?(id) do
      {:ok,
       %__MODULE__{
         request_id: RequestId.from_json(id),
         _meta: AgentTypes.extract_meta(map, @known_keys)
       }}
    else
      {:error, {:invalid_cancel_request_notification, map}}
    end
  end

  def from_json(other), do: {:error, {:invalid_cancel_request_notification, other}}
end

defimpl Jason.Encoder,
  for: Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification do
  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.CancelRequestNotification

  def encode(%CancelRequestNotification{} = val, opts) do
    val |> CancelRequestNotification.to_json() |> Jason.Encode.map(opts)
  end
end
