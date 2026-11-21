defmodule Raxol.Agent.Secret do
  @moduledoc """
  An opaque wrapper around a credential (a private key, a bearer token, an
  RPC URL that embeds an API key) that renders as `#Raxol.Agent.Secret<redacted>`
  under `Inspect`, and so in logs, crash reports and `:sys.get_status`.

  The bytes come back only through `reveal/1`, or `with_revealed/2` where the
  revealed value is handed to code that may raise (a signing NIF puts its
  arguments in the stacktrace). There is no `String.Chars` implementation, so
  interpolating a secret raises instead of printing it.

  This covers accidental disclosure, not memory: the bytes are not zeroed, and
  `inspect(secret, structs: false)` or Erlang's `~p` print the raw struct.
  A process that holds a secret in a plain field must also implement
  `format_status/1` with `redact_status/2`, which replaces the named state
  fields before OTP formats them.

  It lives in raxol_agent because that is the lowest package that
  raxol_payments, raxol_earn and raxol_broker all depend on; raxol_web3 and
  raxol_agent_client_protocol cannot reach it and redact with derived
  `Inspect` instead.

      secret = Raxol.Agent.Secret.new(private_key_bytes)
      inspect(secret)                                     #=> "#Raxol.Agent.Secret<redacted>"
      Raxol.Agent.Secret.reveal(secret) == private_key_bytes  #=> true
  """

  @enforce_keys [:bytes]
  defstruct [:bytes]

  @type t :: %__MODULE__{bytes: binary()}

  @redacted :redacted

  @doc "Wrap a binary. An already wrapped secret is returned unchanged."
  @spec new(binary() | t()) :: t()
  def new(%__MODULE__{} = secret), do: secret
  def new(bytes) when is_binary(bytes), do: %__MODULE__{bytes: bytes}

  def new(_other) do
    raise ArgumentError, "Raxol.Agent.Secret.new/1 expects a binary"
  end

  @doc "Wrap a binary, passing `nil` through, for optional credentials."
  @spec wrap(binary() | t() | nil) :: t() | nil
  def wrap(nil), do: nil
  def wrap(value), do: new(value)

  @doc "The wrapped bytes."
  @spec reveal(t()) :: binary()
  def reveal(%__MODULE__{bytes: bytes}), do: bytes

  @doc """
  Reveal the bytes only to `fun`. A raise, throw or exit inside it becomes
  `{:error, :secret_operation_crashed}`, so the revealed value never reaches a
  stacktrace or crash report. `fun`'s own return value passes through.
  """
  @spec with_revealed(t(), (binary() -> result)) ::
          result | {:error, :secret_operation_crashed}
        when result: term()
  def with_revealed(%__MODULE__{bytes: bytes}, fun) when is_function(fun, 1) do
    fun.(bytes)
  rescue
    _exception -> {:error, :secret_operation_crashed}
  catch
    _kind, _reason -> {:error, :secret_operation_crashed}
  end

  @doc """
  A `c:GenServer.format_status/1` body: replaces each of `keys` in the status
  `:state` (a map or struct) with `:redacted`, and empties the `:log` of sys
  debug events, which holds raw messages. `nil` fields stay `nil`, so a dump
  still shows whether a credential was set.

      @impl GenServer
      def format_status(status), do: Raxol.Agent.Secret.redact_status(status, [:token])

  With `failure: true` it also reduces the `:reason` to an atom or exception
  module and the last `:message` to its leading atom: a crash inside code
  that was handed a secret carries it in the stacktrace's arguments.
  """
  @spec redact_status(map(), [atom()], keyword()) :: map()
  def redact_status(status, keys, opts \\ [])

  def redact_status(status, keys, opts) when is_map(status) and is_list(keys) do
    status = if Keyword.get(opts, :failure, false), do: redact_failure(status), else: status

    status =
      case status do
        %{state: state} when is_map(state) -> %{status | state: redact(state, keys)}
        _other -> status
      end

    case status do
      %{log: [_ | _]} -> %{status | log: []}
      _other -> status
    end
  end

  defp redact_failure(status) do
    Map.new(status, fn
      {:reason, reason} -> {:reason, failure_reason(reason)}
      {:message, message} -> {:message, message_tag(message)}
      other -> other
    end)
  end

  defp failure_reason(reason) when is_atom(reason), do: reason
  defp failure_reason(%{__exception__: true, __struct__: module}), do: module
  defp failure_reason({%{__exception__: true, __struct__: module}, _stack}), do: module
  defp failure_reason({reason, stack}) when is_atom(reason) and is_list(stack), do: reason
  defp failure_reason({tag, _detail}) when is_atom(tag), do: tag
  defp failure_reason(_reason), do: :error

  defp message_tag(message) when is_atom(message), do: message

  defp message_tag(message) when is_tuple(message) and is_atom(elem(message, 0)),
    do: elem(message, 0)

  defp message_tag(_message), do: :term

  @doc "Replace each of `keys` present in `map` with `:redacted` (`nil` kept)."
  @spec redact(map(), [atom()]) :: map()
  def redact(map, keys) when is_map(map) and is_list(keys) do
    Enum.reduce(keys, map, fn key, acc ->
      case acc do
        %{^key => nil} -> acc
        %{^key => _value} -> Map.put(acc, key, @redacted)
        _absent -> acc
      end
    end)
  end

  defimpl Inspect do
    def inspect(_secret, _opts), do: "#Raxol.Agent.Secret<redacted>"
  end
end
