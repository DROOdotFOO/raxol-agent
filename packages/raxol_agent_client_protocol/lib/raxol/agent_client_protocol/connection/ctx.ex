defmodule Raxol.AgentClientProtocol.Connection.Ctx do
  @moduledoc """
  Per-dispatch handler context, built by `Connection` for every inbound request
  or notification and handed to the task running the handler callback.

  `handler_state` is read-only: handlers run as concurrent tasks, so per-session
  state belongs in `Session`. `reply_ref` is set for requests and `nil` for
  notifications. `rx_seq` is the inbound frame's monotone sequence number.
  `delivery_stamp` is the ordering key of a `session/update` dispatch (`nil`
  otherwise).
  """

  @enforce_keys [:conn, :role]
  defstruct conn: nil,
            role: :agent,
            caps: nil,
            handler_state: nil,
            reply_ref: nil,
            rx_seq: 0,
            delivery_stamp: nil,
            session_sup: nil,
            task_sup: nil

  @type t :: %__MODULE__{
          conn: pid(),
          role: :agent | :client,
          caps: term() | nil,
          handler_state: term(),
          reply_ref: reference() | nil,
          rx_seq: non_neg_integer(),
          delivery_stamp: Raxol.AgentClientProtocol.Delivery.t() | nil,
          session_sup: pid() | nil,
          task_sup: pid() | nil
        }
end
