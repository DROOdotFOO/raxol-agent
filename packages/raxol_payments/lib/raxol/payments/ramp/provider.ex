defmodule Raxol.Payments.Ramp.Provider do
  @moduledoc """
  Trusted ramp provider boundary from phase 1 plan section 8.

  Context contains runtime dependencies and the validated intent. Provider raw
  payloads and errors must never be returned. Command conflicts return
  `{:error, :session_conflict, latest_snapshot}` when the operation exists.
  """
  @type context :: map()
  @type capability :: struct()
  @type intent :: struct()
  @type offer_ref :: String.t()
  @type revision :: String.t()
  @type preview :: struct()
  @type operation_ref :: String.t()
  @type quote_ref :: String.t()
  @type command_context :: map()
  @type snapshot :: struct()
  @type public_action :: map()
  @type action_code :: String.t()

  @callback capabilities(context()) :: {:ok, [capability()]} | {:error, term()}
  @callback preview(intent(), offer_ref(), revision(), context()) ::
              {:ok, preview()} | {:error, term()}
  @callback approve(operation_ref(), quote_ref(), command_context(), context()) ::
              {:ok, snapshot()}
              | {:requires_user, public_action(), snapshot()}
              | {:error, term()}
              | {:error, :session_conflict, snapshot()}
  @callback status(operation_ref(), context()) :: {:ok, snapshot()} | {:error, term()}
  @callback recover(operation_ref(), action_code(), command_context(), context()) ::
              {:ok, snapshot()}
              | {:requires_user, public_action(), snapshot()}
              | {:error, term()}
              | {:error, :session_conflict, snapshot()}
end
