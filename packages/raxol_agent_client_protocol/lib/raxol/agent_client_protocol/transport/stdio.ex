defmodule Raxol.AgentClientProtocol.Transport.Stdio do
  @moduledoc """
  Newline-delimited JSON (NDJSON) over a stdio pipe — either our OWN
  process's real stdin/stdout (`:self` mode, when this BEAM process IS the
  ACP agent/client speaking on its own stdio), or a spawned peer command's
  stdio (`:spawn` mode, when we launch and speak to a subprocess).

  One `GenServer` owns BOTH directions of the pipe:

    * **Read** — raw bytes arrive from the OS pipe as `Port` `:data`
      messages (`:spawn` mode) or as lines read from the `user` device
      (`:self` mode) and are fed through
      `Raxol.AgentClientProtocol.Transport.Framer` (byte-splitting only:
      buffers partial data, yields complete NDJSON lines, tolerates
      CRLF, caps a frame's size). A complete line nested deeper than the
      depth limit is refused without being parsed; any other line is then
      `Jason.decode/1`'d *tolerantly*: a line that isn't valid JSON, that
      decodes to something other than a JSON object, that is nested too
      deeply, or that the framer itself rejected as oversized, is delivered
      to the owner as
      `{:acp_transport, ref, {:decode_error, reason, raw_line}}` rather
      than crashing the transport or dropping the frame silently. A
      well-formed object is delivered as
      `{:acp_transport, ref, {:message, map}}`. Lines are processed (and
      therefore delivered) strictly in arrival order. Blank lines are
      skipped by the framer without generating a decode error — a
      trailing newline at EOF is common and not itself malformed input.

    * **Write** — `send_message/2` `Jason.encode!/1`s the message, appends
      `"\n"`, and writes through THIS GenServer's own mailbox
      (`GenServer.call/2`). This is deliberate single-writer discipline:
      every caller's write is serialized through one process, so two
      concurrent `send_message/2` calls can never interleave their bytes
      on the wire and corrupt a frame — NDJSON has no length prefix, so a
      torn write (line A's bytes and line B's bytes interleaved before
      either `"\n"` lands) is unrecoverable, unlike a length-framed
      protocol. Never write to the underlying port through any path other
      than this module.

  ## Limits

    * `:max_frame_bytes` (default 16 MiB): a frame longer than this is
      refused as `{:decode_error, {:frame_too_large, size}, ""}` and the
      framer resyncs at the next newline. Raise it if prompts carry large
      base64 resources; lower it for a peer you do not trust. In `:spawn`
      mode this also bounds the memory an unterminated line can take. In
      `:self` mode it does not: the `user` device hands this module whole
      lines only, so a line is held by the device until its newline (or
      end of input) arrives, and only then measured.
    * `:max_json_depth` (default 256): a frame whose arrays and objects
      nest deeper than this is refused as
      `{:decode_error, {:too_deep, max_json_depth}, raw_line}` before it is
      decoded. The check scans the line once and skips string contents.

  ## stdout is protocol-pure

  In `:self` mode, this process's real stdout carries the wire protocol.
  Nothing else may ever write to it — an errant `IO.puts/1`, a stray
  `Logger` line landing on the `:user` group leader, or any other
  application output would land mid-frame on a peer that is line-buffered
  reading JSON. This module logs unexpected messages via `Logger.debug/1`,
  which is safe **only if** the host application's Logger is configured to
  a device other than `:user`/stdout (e.g.
  `config :logger, :default_handler, config: [type: :standard_error]`, or
  an equivalent `:standard_error` console backend). Configuring that is the
  host application's responsibility, not this module's — get it wrong and
  every log line is a corrupted ACP frame on the wire.

  ## Modes

    * `start_self/1` — read and write the `user` device, which is the
      BEAM's own stdin and stdout. A `{:fd, 0, 1}` port is not used: under
      `-noshell` the `user` device already reads fd 0, so a second reader
      loses whatever arrived before it opened (a client's `initialize`).
      Only meaningful when this process's real stdio is dedicated to the
      ACP wire protocol and nothing else writes to stdout. Boot forms that
      satisfy this, with stdio piped by the peer: a compiled release; `mix
      run` of an already compiled project (compile first in a separate
      step: Mix prints compile output on stdout); an `elixir` script that
      sends `Mix.install/2`'s output to stderr and blocks until its
      connection ends, as the package README's quickstart agent does. In
      every form the default log handler must write to stderr (see
      "stdout is protocol-pure"). Not for an interactive `iex` session. Both
      devices are switched to `encoding: :latin1`, which moves bytes
      unchanged: the wire is UTF-8 whatever the locale, and a byte that is
      not UTF-8 reaches the JSON decoder as it was sent. A `unicode` device
      would transcode by the locale's rules, and falls back to latin1 for
      good at the first invalid byte it reads.
    * `start_spawn/3` — launch a peer executable via
      `Port.open({:spawn_executable, ...}, ...)` and speak to *its*
      stdin/stdout. The peer's exit is delivered to the owner as
      `{:closed, {:exit_status, code}}`.

  ## Ownership

  Mirrors `Raxol.AgentClientProtocol.Transport.Paired`: a freshly created
  handle has no owner (`nil`) — inbound messages are held until
  `set_owner/2` adopts it and then delivered in arrival order, so a
  supervisor can create the transport before the `Connection` process
  that will own it exists.
  """

  use GenServer
  require Logger

  alias Raxol.AgentClientProtocol.Transport.Framer
  alias Raxol.Core.ChildEnv, as: CoreEnv

  @behaviour Raxol.AgentClientProtocol.Transport

  @default_max_json_depth 256

  @type t :: %__MODULE__{pid: pid()}
  defstruct [:pid]

  @typep mode :: :self | :spawn

  @typep server_state :: %{
           owner: pid() | nil,
           port: port() | nil,
           reader: pid() | nil,
           output: IO.device() | nil,
           mode: mode(),
           framer: Framer.t(),
           max_json_depth: pos_integer(),
           closed: boolean(),
           pending: [term()]
         }

  # -- Construction --------------------------------------------------------

  @doc """
  Serve the BEAM's own stdin/stdout as the transport. See the moduledoc's
  "Modes" section for when this is (and is not) safe to call.

  `opts`:

    * `:owner` — pid to receive inbound `{:acp_transport, ...}` messages;
      defaults to `nil` (adopt later via `set_owner/2`).
    * `:input`, `:output` — the IO devices read and written (default
      `:user` for both). Each is sent `:io.setopts(device, encoding:
      :latin1)`; a device that has no options (`{:error, :enotsup}`) is
      used as it is.
    * `:max_frame_bytes`, `:max_json_depth` — see "Limits".
  """
  @spec start_self(keyword()) :: {:ok, t()}
  def start_self(opts \\ []) do
    owner = Keyword.get(opts, :owner)
    devices = {Keyword.get(opts, :input, :user), Keyword.get(opts, :output, :user)}
    {:ok, pid} = GenServer.start_link(__MODULE__, {:self, devices, owner, limits(opts)})
    {:ok, %__MODULE__{pid: pid}}
  end

  @doc """
  Spawn `cmd` (resolved via `System.find_executable/1`, so a bare name is
  looked up on `$PATH` and an absolute/relative path containing a slash is
  used as-is) with `args`, and speak NDJSON over its stdin/stdout.

  `opts`:

    * `:owner` — pid to receive inbound messages; defaults to `nil`.
    * `:cd` — working directory for the child process.
    * `:env` — list of `{name, value}` environment overrides, passed
      to `Port.open/2`'s `:env` option ahead of the scrub below. A name is a
      string or charlist; a value is a string, a charlist, or `false` to
      unset. Anything else (`nil`, an integer) raises `ArgumentError`.
    * `:scrub_env` — `false` to skip the credential scrub; default `true`.
      Any other value raises `ArgumentError`, so a missing setting passed
      through as `nil` cannot turn the scrub off.
    * `:unset_env` — more variable names (strings) to unset in the child.
    * `:pass` — names (strings, exact case) the scrub lets through to this
      child after all. The only allowlist this transport honours; see below.
    * `:max_frame_bytes`, `:max_json_depth` — see "Limits".

  The child inherits the node's environment plus `:env`, minus what
  `Raxol.Core.ChildEnv` denies, the scrub raxol's directive shells and MCP
  stdio servers get:

    * every variable whose name looks like a credential (case-insensitive):
      a `_`-separated segment such as `KEY`, `KEYS`, `APIKEY`, `TOKEN`,
      `SECRET`, `PASSWORD`, `PASSPHRASE`, `MNEMONIC` or `CREDENTIALS`
      anywhere in the name; a database or broker URL (`DATABASE_URL`,
      `REDIS_URL`, ...); `PGPASSWORD`; `RPC` anywhere but in `GRPC`;
    * raxol_core's named set (`SECRET_KEY_BASE`, `RELEASE_COOKIE`,
      `SSH_AUTH_SOCK`, raxol's own keys) and the operator's
      `config :raxol_core, Raxol.Core.ChildEnv, extra_secrets:`, set or not;
    * and, on top of Core, `credential_gaps/0`: a `_PASS`, `_SEED_PHRASE` or
      `_DSN` suffix, `SEED_PHRASE`, and `OP_SESSION_*`, which raxol_core 2.9's
      pattern misses;

  minus this call's `:pass`.

  **Core's `pass:` list is not honoured here.** The operator's
  `config :raxol_core, Raxol.Core.ChildEnv, pass:` lets names through to
  directive shells and MCP servers the operator runs; a spawned ACP agent is
  third-party code, so every name on that list is unset in it too (set or
  not, credential-shaped or not), unless this call's `:pass` names it.

  Precedence, highest first: a name given in `:env` is set as given; a name
  in `:unset_env` is unset; a name in `:pass` is inherited; otherwise the
  scrub decides. See `Raxol.Core.ChildEnv` for what no pattern catches.

  An agent is third-party code. To hand it one of those credentials (an
  agent that reads its own provider key, say), name it in `:env`, or pass
  `scrub_env: false` to inherit everything (`:unset_env` is then ignored). A
  process running as the same user can still read the node's own launch
  environment (`/proc/<pid>/environ`); the scrub only stops inheritance.

  The environment is built in the calling process, before the transport
  starts, so these raise from this call and no agent is spawned:

    * `ArgumentError` for a malformed `Raxol.Core.ChildEnv` config (an
      unknown or repeated key, a name that is not a string) or a malformed
      `:env`, `:scrub_env`, `:unset_env` or `:pass`;
    * `RuntimeError` when `Raxol.Core.ChildEnv` cannot be loaded: a release
      that leaves raxol_core out (see the README's "Releases" note). The
      scrub fails closed; `scrub_env: false` does not need raxol_core.

  Returns `{:error, :executable_not_found}` if `cmd` cannot be resolved.
  """
  @spec start_spawn(String.t(), [String.t()], keyword()) ::
          {:ok, t()} | {:error, :executable_not_found}
  def start_spawn(cmd, args \\ [], opts \\ []) when is_binary(cmd) and is_list(args) do
    case System.find_executable(cmd) do
      nil ->
        {:error, :executable_not_found}

      path ->
        owner = Keyword.get(opts, :owner)
        init_arg = {:spawn, path, args, build_spawn_opts(opts), owner, limits(opts)}
        {:ok, pid} = GenServer.start_link(__MODULE__, init_arg)
        {:ok, %__MODULE__{pid: pid}}
    end
  end

  @doc """
  Set (or replace) the owner process for a handle — mirrors
  `Raxol.AgentClientProtocol.Transport.Paired.set_owner/2`.
  """
  @spec set_owner(t(), pid()) :: :ok
  def set_owner(%__MODULE__{pid: pid}, owner) when is_pid(owner) do
    GenServer.call(pid, {:set_owner, owner})
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec send_message(t(), map()) :: {:ok, t()} | {:error, term()}
  def send_message(%__MODULE__{pid: pid} = state, message) when is_map(message) do
    case GenServer.call(pid, {:send, message}) do
      :ok -> {:ok, state}
      {:error, _reason} = error -> error
    end
  catch
    :exit, reason -> {:error, {:transport_down, reason}}
  end

  @impl Raxol.AgentClientProtocol.Transport
  @spec close(t()) :: :ok
  def close(%__MODULE__{pid: pid}) do
    if Process.alive?(pid) do
      GenServer.call(pid, :close)
    else
      :ok
    end
  catch
    :exit, _reason -> :ok
  end

  # -- GenServer callbacks --------------------------------------------------

  @impl GenServer
  @spec init(
          {:self, {IO.device(), IO.device()}, pid() | nil, keyword()}
          | {:spawn, String.t(), [String.t()], keyword(), pid() | nil, keyword()}
        ) :: {:ok, server_state()}
  def init({:self, {input, output}, owner, limits}) do
    :ok = byte_transparent(input)
    :ok = byte_transparent(output)
    transport = self()
    reader = spawn_link(fn -> read_lines(input, transport) end)
    {:ok, %{new_state(:self, owner, limits) | reader: reader, output: output}}
  end

  def init({:spawn, path, args, spawn_opts, owner, limits}) do
    port_opts = [:binary, :exit_status, args: args] ++ spawn_opts
    port = Port.open({:spawn_executable, String.to_charlist(path)}, port_opts)
    {:ok, %{new_state(:spawn, owner, limits) | port: port}}
  end

  # Validated in the caller's process, so a bad option raises there rather
  # than crashing the transport's start.
  @spec limits(keyword()) :: keyword()
  defp limits(opts) do
    framer_opts = Keyword.take(opts, [:max_frame_bytes])
    # Framer.new/1 raises ArgumentError on a bad :max_frame_bytes.
    _ = Framer.new(framer_opts)
    depth = Keyword.get(opts, :max_json_depth, @default_max_json_depth)

    if not (is_integer(depth) and depth > 0) do
      raise ArgumentError, "max_json_depth must be a positive integer, got: #{inspect(depth)}"
    end

    [max_json_depth: depth] ++ framer_opts
  end

  defp new_state(mode, owner, limits) do
    %{
      owner: owner,
      port: nil,
      reader: nil,
      output: nil,
      mode: mode,
      framer: Framer.new(Keyword.take(limits, [:max_frame_bytes])),
      max_json_depth: Keyword.fetch!(limits, :max_json_depth),
      closed: false,
      pending: []
    }
  end

  # Read and written with `IO.binread/2` and `IO.binwrite/2`, a latin1
  # device passes every byte through.
  defp byte_transparent(device) do
    case :io.setopts(device, encoding: :latin1) do
      :ok -> :ok
      {:error, :enotsup} -> :ok
    end
  end

  # One line per message, so the transport's mailbox orders them. Linked:
  # it ends with the transport, and a read blocked on the device ends when
  # `close/1` kills it.
  defp read_lines(input, transport) do
    case IO.binread(input, :line) do
      :eof ->
        send(transport, {:stdin, self(), :eof})

      {:error, _reason} ->
        send(transport, {:stdin, self(), :eof})

      line ->
        send(transport, {:stdin, self(), {:data, IO.iodata_to_binary(line)}})
        read_lines(input, transport)
    end
  end

  # Built in the caller (see `start_spawn/3`): a malformed config or option,
  # or a missing raxol_core, raises there instead of crashing the transport.
  @spec build_spawn_opts(keyword()) :: keyword()
  defp build_spawn_opts(opts) do
    env = opts |> Keyword.get(:env, []) |> validate_env!()

    env =
      case Keyword.get(opts, :scrub_env, true) do
        true ->
          unset = names!(opts, :unset_env)
          scrubbed_env(env, unset, names!(opts, :pass))

        false ->
          env

        other ->
          raise ArgumentError, ":scrub_env must be true or false, got: #{inspect(other)}"
      end

    Keyword.take(opts, [:cd]) ++ [env: env]
  end

  @spec names!(keyword(), :unset_env | :pass) :: [String.t()]
  defp names!(opts, key) do
    case Keyword.get(opts, key, []) do
      names when is_list(names) ->
        Enum.map(names, fn
          name when is_binary(name) ->
            name

          name ->
            raise ArgumentError,
                  "#{inspect(key)} must be a list of strings, got an entry of shape #{type(name)}"
        end)

      other ->
        raise ArgumentError, "#{inspect(key)} must be a list of strings, got: #{type(other)}"
    end
  end

  # The same `{name, value}` shapes on both paths, as charlists for
  # `Port.open/2`, which would crash the transport on a `nil` or an integer.
  @spec validate_env!(term()) :: [{charlist(), charlist() | false}]
  defp validate_env!(env) when is_list(env) do
    Enum.each(env, fn
      {name, value}
      when (is_binary(name) or is_list(name)) and
             (is_binary(value) or is_list(value) or value == false) ->
        :ok

      entry ->
        raise ArgumentError,
              ":env entries must be {name, value | false} with string or charlist " <>
                "names and values, got an entry of shape #{entry_shape(entry)}"
    end)

    Enum.map(env, fn {name, value} -> {to_charlist(name), charlist_or_false(value)} end)
  end

  defp validate_env!(env),
    do: raise(ArgumentError, ":env must be a list, got: #{entry_shape(env)}")

  @spec charlist_or_false(String.t() | charlist() | false) :: charlist() | false
  defp charlist_or_false(false), do: false
  defp charlist_or_false(value), do: to_charlist(value)

  # The type of a rejected entry, never its contents, which may be a key.
  @spec entry_shape(term()) :: String.t()
  defp entry_shape({name, value}), do: "{#{type(name)}, #{type(value)}}"
  defp entry_shape(term), do: type(term)

  @spec type(term()) :: String.t()
  defp type(term) when is_binary(term), do: "string"
  defp type(term) when is_list(term), do: "list"
  defp type(term) when is_atom(term), do: inspect(term)
  defp type(term) when is_integer(term), do: "integer"
  defp type(term) when is_tuple(term), do: "tuple"
  defp type(_term), do: "other"

  # Core's pattern is pinned in `stdio_test.exs`: the gap list is right only
  # for it, so a raxol_core release that changes it fails this package's
  # build before it can narrow what agents inherit. raxol_core 2.9.1 adds
  # these shapes to its own pattern; the list stays until this package
  # requires it.
  @gaps ~r/(_PASS|_SEED_PHRASE|_DSN)\z|\ASEED_PHRASE\z|\AOP_SESSION_/i

  @doc """
  The names this transport scrubs on top of `Raxol.Core.ChildEnv`
  (case-insensitive): a `_PASS`, `_SEED_PHRASE` or `_DSN` suffix,
  `SEED_PHRASE` and `OP_SESSION_*`, which raxol_core 2.9's credential
  pattern misses. `Raxol.Agent.ChildEnv` applies the same list to directive
  shells, so there is one copy of it.
  """
  @spec credential_gaps() :: Regex.t()
  def credential_gaps, do: @gaps

  @doc """
  Whether a spawned agent is denied `name`: `Raxol.Core.ChildEnv` denies it
  (its pattern or named set), it is on Core's `pass:` list (which this
  transport does not honour), or it has a `credential_gaps/0` shape, and it
  is not in `opts[:pass]`. A spawn's `:env` and `:unset_env` are not
  consulted. Raises like `start_spawn/3` on a malformed config or a missing
  raxol_core.
  """
  @spec secret?(String.t(), keyword()) :: boolean()
  def secret?(name, opts \\ []) when is_binary(name) and is_list(opts) do
    core!()
    denied?(name, core_pass_upcase(), names!(opts, :pass))
  end

  # Core matches its named set case-insensitively but `pass:` exactly, so
  # `pass: ["SSH_AUTH_SOCK"]` makes Core let `ssh_auth_sock` through as well.
  # Matching Core's `pass:` case-insensitively here denies every such variant.
  @spec denied?(String.t(), [String.t()], [String.t()]) :: boolean()
  defp denied?(name, core_pass_upcase, pass) do
    name not in pass and
      (String.upcase(name) in core_pass_upcase or CoreEnv.secret?(name) or
         Regex.match?(@gaps, name))
  end

  @spec core_pass_upcase() :: [String.t()]
  defp core_pass_upcase, do: Enum.map(CoreEnv.pass(), &String.upcase/1)

  # The caller's `env`, then, unset (`false`): `unset` and every name a child
  # is denied, set or not for Core's named set and `pass:` list, otherwise if
  # the node has it; minus `pass`, and minus whatever `env` names.
  @spec scrubbed_env(list(), [String.t()], [String.t()]) :: [{charlist(), charlist() | false}]
  defp scrubbed_env(env, unset, pass) do
    core!()
    core_pass = CoreEnv.pass()
    core_pass_upcase = Enum.map(core_pass, &String.upcase/1)
    given = MapSet.new(env, fn {name, _value} -> to_string(name) end)
    present = System.get_env() |> Map.keys() |> Enum.filter(&denied?(&1, core_pass_upcase, pass))
    named = Enum.reject(CoreEnv.secrets() ++ core_pass, &(&1 in pass))

    removed =
      for name <- Enum.uniq(unset ++ named ++ present),
          name not in given,
          do: {String.to_charlist(name), false}

    env ++ removed
  end

  # Fail closed: without raxol_core's code (a release that leaves it out),
  # there is no scrub to apply, and spawning unscrubbed is not an option.
  @spec core!() :: :ok
  defp core! do
    if Code.ensure_loaded?(CoreEnv) do
      :ok
    else
      raise "Raxol.Core.ChildEnv is not available, so a spawned agent's environment " <>
              "cannot be scrubbed. A release must ship raxol_core: add " <>
              "`applications: [raxol_core: :load]` to it (see the " <>
              "raxol_agent_client_protocol README), or pass scrub_env: false."
    end
  end

  @impl GenServer
  def handle_call({:set_owner, owner}, _from, state) when is_pid(owner) do
    # Flush frames that arrived before adoption, in arrival order, so a peer
    # that wrote (e.g. an editor's `initialize`) before the supervisor set an
    # owner is not silently dropped. `pending` is prepend-built, so reverse.
    state.pending
    |> Enum.reverse()
    |> Enum.each(&send(owner, {:acp_transport, self(), &1}))

    {:reply, :ok, %{state | owner: owner, pending: []}}
  end

  def handle_call({:send, _message}, _from, %{closed: true} = state) do
    {:reply, {:error, :closed}, state}
  end

  def handle_call({:send, message}, _from, state) do
    line = Jason.encode!(message) <> "\n"

    case write(state, line) do
      :ok -> {:reply, :ok, state}
      :closed -> {:reply, {:error, :closed}, %{state | closed: true}}
    end
  end

  def handle_call(:close, _from, %{closed: true} = state) do
    {:reply, :ok, state}
  end

  def handle_call(:close, _from, state) do
    close_source(state)
    {:reply, :ok, %{state | closed: true}}
  end

  @impl GenServer
  def handle_info({port, {:data, data}}, %{port: port, closed: false} = state) do
    {:noreply, push(state, data)}
  end

  def handle_info({port, {:data, _data}}, %{port: port, closed: true} = state) do
    # Already closed locally (or the peer already signalled exit); drop
    # further inbound bytes rather than deliver past the closed boundary.
    {:noreply, state}
  end

  # Read from the `user` device in `:self` mode.
  def handle_info({:stdin, reader, {:data, data}}, %{reader: reader, closed: false} = state) do
    {:noreply, push(state, data)}
  end

  # `:self` mode is half-closable: end of input says the peer will send
  # nothing more, not that it has stopped reading. A peer that pipes its
  # requests and closes stdin still gets its replies, so the write side
  # stays open until `close/1` or a failed write.
  def handle_info({:stdin, reader, :eof}, %{reader: reader, closed: false} = state) do
    {:noreply, emit(state, {:closed, :eof})}
  end

  def handle_info({:stdin, _reader, _event}, state), do: {:noreply, state}

  def handle_info({port, :eof}, %{port: port, closed: false} = state) do
    state = emit(state, {:closed, :eof})
    {:noreply, %{state | closed: true}}
  end

  def handle_info({port, :eof}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info({port, {:exit_status, code}}, %{port: port, closed: false} = state) do
    state = emit(state, {:closed, {:exit_status, code}})
    {:noreply, %{state | closed: true}}
  end

  def handle_info({port, {:exit_status, _code}}, %{port: port} = state) do
    {:noreply, state}
  end

  def handle_info(msg, state) do
    Logger.debug("Raxol.AgentClientProtocol.Transport.Stdio: unexpected message #{inspect(msg)}")

    {:noreply, state}
  end

  # -- Framing ---------------------------------------------------------------

  @spec push(server_state(), binary()) :: server_state()
  defp push(state, data) do
    {frames, framer} = Framer.push(state.framer, data)

    Enum.reduce(frames, %{state | framer: framer}, fn frame, acc ->
      emit(acc, frame_payload(frame, acc.max_json_depth))
    end)
  end

  # A `Framer.push/2` result is either a complete NDJSON line (still raw
  # text -- decode it) or an oversized-frame error the framer already
  # detected and resynced past (no raw bytes to hand back -- the framer
  # deliberately does not retain them, see its moduledoc).
  # The `{:acp_transport, ...}` payload for one framer result, without
  # touching the owner: `emit/2` decides delivery vs buffering.
  @spec frame_payload(Framer.frame_or_error(), pos_integer()) ::
          {:message, map()} | {:decode_error, term(), binary()}
  defp frame_payload({:error, {:frame_too_large, _size} = reason}, _max_depth) do
    {:decode_error, reason, ""}
  end

  defp frame_payload(line, max_depth) when is_binary(line) do
    if nested_deeper?(line, max_depth) do
      {:decode_error, {:too_deep, max_depth}, line}
    else
      case Jason.decode(line) do
        {:ok, map} when is_map(map) -> {:message, map}
        {:ok, other} -> {:decode_error, {:not_an_object, other}, line}
        {:error, reason} -> {:decode_error, reason, line}
      end
    end
  end

  # One pass over the line, jumping between the bytes that matter: outside a
  # string `[`, `{`, `]`, `}` and `"`; inside one `"` and `\\` (an escape
  # skips the byte after it). Malformed JSON is left to the decoder; this
  # only answers whether some point nests deeper than `limit`.
  @spec nested_deeper?(binary(), pos_integer()) :: boolean()
  defp nested_deeper?(line, limit) do
    patterns = %{
      structural: :binary.compile_pattern(["[", "{", "]", "}", "\""]),
      in_string: :binary.compile_pattern(["\"", "\\"])
    }

    scan_depth(line, 0, 0, limit, patterns)
  end

  defp scan_depth(line, pos, depth, limit, patterns) do
    case :binary.match(line, patterns.structural, scope: {pos, byte_size(line) - pos}) do
      :nomatch ->
        false

      {at, 1} ->
        case :binary.at(line, at) do
          ?" -> scan_string(line, at + 1, depth, limit, patterns)
          open when open in [?[, ?{] and depth >= limit -> true
          open when open in [?[, ?{] -> scan_depth(line, at + 1, depth + 1, limit, patterns)
          _close -> scan_depth(line, at + 1, max(depth - 1, 0), limit, patterns)
        end
    end
  end

  defp scan_string(line, pos, depth, limit, patterns) do
    case :binary.match(line, patterns.in_string, scope: {pos, byte_size(line) - pos}) do
      :nomatch ->
        false

      {at, 1} ->
        if :binary.at(line, at) == ?\\,
          do: scan_string(line, min(at + 2, byte_size(line)), depth, limit, patterns),
          else: scan_depth(line, at + 1, depth, limit, patterns)
    end
  end

  # Send a payload to the owner, or buffer it (prepend, O(1)) when no owner
  # has adopted the transport yet; `set_owner` flushes the buffer in order.
  @spec emit(server_state(), term()) :: server_state()
  defp emit(%{owner: nil} = state, payload) do
    %{state | pending: [payload | state.pending]}
  end

  defp emit(%{owner: owner} = state, payload) do
    send(owner, {:acp_transport, self(), payload})
    state
  end

  # A device that is gone raises; before Elixir 1.20 it answered
  # `{:error, reason}`, which the match turns into a raise.
  @spec write(server_state(), String.t()) :: :ok | :closed
  defp write(%{mode: :self, output: output}, line) do
    :ok = IO.binwrite(output, line)
  rescue
    _error in [ArgumentError, ErlangError, MatchError] -> :closed
  end

  defp write(%{port: port}, line) do
    Port.command(port, line)
    :ok
  rescue
    ArgumentError -> :closed
  end

  @spec close_source(server_state()) :: :ok
  defp close_source(%{mode: :self, reader: reader}) do
    Process.unlink(reader)
    Process.exit(reader, :kill)
    :ok
  end

  defp close_source(%{port: port}) do
    Port.close(port)
    :ok
  rescue
    ArgumentError -> :ok
  end
end
