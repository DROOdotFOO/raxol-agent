defmodule Raxol.Web3.Dial do
  @moduledoc """
  The pinned dial: connect to a vetted ADDRESS while the hostname carries identity.

  ADR-0033 section 7's third rule, "the checked address is the address dialled",
  which closes DNS rebinding between the check and the connect. `connect/3` takes
  `:inet` address tuples, never names; a binary where an address belongs is
  refused with `{:not_an_address, value}` rather than resolved.

  ## Identity

  Mint derives SNI, the certificate hostname check and the HTTP/1 `Host` header
  from the `:hostname` option. So `connect/3` refuses `:server_name_indication`,
  `:customize_hostname_check`, `verify` and `verify_fun` rather than merging
  them: setting any of them can weaken or disable verification.

  ## No pool

  One connection per request, deliberately. A pool keyed by a vetted IP would let
  every hostname behind that address (the normal case behind Cloudflare) share
  one pool and inherit the first identity that opened it. See ADR-0038 decision
  3. An address tuple also carries its family, so IPv6 pins work.

  ## No policy

  Nothing here checks the reject set; `Raxol.Core.Outbound` does, and
  `Raxol.Web3.HTTP` runs the two in order. That is also why tests can dial
  loopback directly.

  ## Mode

  Connections are opened `mode: :passive` (not overridable), because the bounded
  read is a synchronous `Mint.HTTP.recv/3` loop.
  """

  @default_port 443
  @default_timeout_ms 5_000

  # Each of these either replaces a value Mint derives from `:hostname`, or
  # weakens verification outright.
  #
  # `:partial_chain` and `:versions` are defence in depth rather than a fix:
  # neither is reachable through `Raxol.Web3.HTTP`, which refuses
  # `:transport_opts` outright. `:partial_chain` lets a caller declare an
  # intermediate trusted and so accept a chain that does not reach a root,
  # and `:versions` can put TLS 1.0 back on the wire. Both belong on the
  # same list as `:verify` for the same reason.
  @forbidden_transport_opts [
    :server_name_indication,
    :customize_hostname_check,
    :verify,
    :verify_fun,
    :partial_chain,
    :versions
  ]

  @type address :: :inet.ip_address()

  @type reason ::
          :no_addresses
          | {:not_an_address, term()}
          | {:forbidden_transport_opts, [atom()]}
          | {:dial_failed, [{address(), term()}]}
          | {:budget_exhausted, [{address(), term()}]}

  @doc """
  Connect to the first reachable address, presenting `hostname` as the identity.

  `addresses` is the vetted list from `Raxol.Core.Outbound.vet/2`, in
  resolution order. Each is tried in turn, which is the failover `:gen_tcp`
  performs when it is handed a name and which pinning would otherwise lose:
  the hosts this package targets answer with three addresses each. Every
  failure is collected, so `{:dial_failed, failures}` names what was attempted
  rather than only what failed last.

  Options:

    * `:port` - default `443`
    * `:timeout` - per-address connect timeout in milliseconds, default `5000`.
      Authoritative: a `:timeout` inside `:transport_opts` is overwritten with
      it, so the budget cannot be widened from two places at once.
    * `:budget_ms` - the total across every address, default `:infinity`.
      `:timeout` alone bounds one attempt, and a vetted list carries every A
      and AAAA answer the host gave, so a black-holed host costs
      `:timeout * length(addresses)` before the caller's read deadline has
      even started. With a budget, each attempt gets
      `min(:timeout, what is left)` and the rest of the list is abandoned as
      `{:budget_exhausted, failures}` when nothing is. `Raxol.Web3.HTTP`
      always passes one, computed from its own end-to-end deadline.
    * `:transport_opts` - passed to `:ssl`, minus the six keys above. A test
      supplies its own `:cacerts` here.

  """
  @spec connect([address()], String.t(), keyword()) ::
          {:ok, Mint.HTTP.t()} | {:error, reason()}
  def connect(addresses, hostname, opts \\ [])

  def connect([], hostname, _opts) when is_binary(hostname), do: {:error, :no_addresses}

  def connect(addresses, hostname, opts)
      when is_list(addresses) and is_binary(hostname) and is_list(opts) do
    with :ok <- check_addresses(addresses),
         {:ok, transport_opts} <- check_transport_opts(opts) do
      port = Keyword.get(opts, :port, @default_port)
      timeout = Keyword.get(opts, :timeout, @default_timeout_ms)

      connect_opts = [
        hostname: hostname,
        protocols: [:http1],
        mode: :passive,
        transport_opts: transport_opts
      ]

      try_each(addresses, port, connect_opts, timeout, deadline(opts), [])
    end
  end

  defp try_each([], _port, _opts, _timeout, _deadline, failures),
    do: {:error, {:dial_failed, Enum.reverse(failures)}}

  defp try_each([address | rest], port, opts, timeout, deadline, failures) do
    case attempt_timeout(timeout, deadline) do
      0 ->
        {:error, {:budget_exhausted, Enum.reverse(failures)}}

      attempt ->
        case Mint.HTTP.connect(:https, address, port, with_timeout(opts, attempt)) do
          {:ok, conn} ->
            {:ok, conn}

          {:error, reason} ->
            try_each(rest, port, opts, timeout, deadline, [{address, reason} | failures])
        end
    end
  end

  defp deadline(opts) do
    case Keyword.get(opts, :budget_ms, :infinity) do
      :infinity -> :infinity
      ms when is_integer(ms) and ms >= 0 -> now_ms() + ms
    end
  end

  defp attempt_timeout(timeout, :infinity), do: timeout
  defp attempt_timeout(timeout, deadline), do: min(timeout, max(deadline - now_ms(), 0))

  defp with_timeout(opts, timeout) do
    Keyword.update!(opts, :transport_opts, &Keyword.put(&1, :timeout, timeout))
  end

  defp now_ms, do: System.monotonic_time(:millisecond)

  # A name reaching this function is a caller that skipped the vet, so it fails
  # closed rather than being resolved here as a convenience. `:inet` address
  # tuples are the only accepted shape, and the size check is what separates
  # them from any other tuple.
  #
  # `Enum.reject/2` rather than `Enum.find/2`: `nil` is a perfectly good thing
  # for a caller to pass by mistake and it is also `find/2`'s not-found
  # sentinel, so the obvious version accepted `nil` as an address and handed it
  # to `Mint.HTTP.connect/4`, which resolved it and returned `:nxdomain`.
  defp check_addresses(addresses) do
    case Enum.reject(addresses, &address?/1) do
      [] -> :ok
      [other | _rest] -> {:error, {:not_an_address, other}}
    end
  end

  defp address?(address) when is_tuple(address) and tuple_size(address) in [4, 8] do
    address |> Tuple.to_list() |> Enum.all?(&(is_integer(&1) and &1 >= 0))
  end

  defp address?(_other), do: false

  defp check_transport_opts(opts) do
    transport_opts = Keyword.get(opts, :transport_opts, [])

    case Enum.filter(@forbidden_transport_opts, &Keyword.has_key?(transport_opts, &1)) do
      [] -> {:ok, transport_opts}
      forbidden -> {:error, {:forbidden_transport_opts, forbidden}}
    end
  end
end
