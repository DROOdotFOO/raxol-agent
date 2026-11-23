defmodule Raxol.Console.Inbound do
  @moduledoc """
  The authorized entry point for inbound chat events.

  A Console has no feed loop of its own; the deployment pumps adapter output
  (`normalize_event/1`) into `Raxol.Gateway.SessionRouter`. `route/3` makes the
  authorization decision and the routing in one call, so a feed cannot wire the
  second half and forget the first:

      Raxol.Telegram.UpdatePoller.start_link(
        conn: conn,
        on_update: fn raw ->
          with {:ok, route, event} <- Raxol.Telegram.GatewayAdapter.normalize_event(raw) do
            Raxol.Console.Inbound.route(MyConsole, route, event)
          end
        end
      )

  `MyConsole` is the `:name` the runtime booted under.

  `Raxol.Console.Boot` also gives the router an `:authorize` function over the
  same Pairing server, so calling `SessionRouter.route/3` directly gets the same
  decision; this module adds a denial without a router round trip, plus telemetry.

  ## Authorization posture

  `route/3` always consults `Pairing`. An open Console is a Pairing server seeded
  to allow the connected platforms, so there is one code path in both postures.
  Seeds are start options and survive a Pairing restart; runtime DM pairings do
  not. A `Pairing` that cannot answer denies. See
  `Raxol.Console.RuntimeConfig.build/2`.

  ## Admitting someone not on the allowlist

  There is no `/pair` chat command (a denial happens before a session exists).
  Pair out of band:

      pairing = Raxol.Console.Inbound.pairing_name(MyConsole)
      {:ok, code} = Raxol.Gateway.Pairing.request_code(pairing, "12345")
      # deliver `code` to that user however you already reach them
      {:ok, "12345"} = Raxol.Gateway.Pairing.confirm(pairing, code)

  A self-service lane belongs in the deployment's feed loop, using
  `authorized?/2`; the default for a denied sender is silence.

  ## Telemetry

    * `[:raxol_console, :inbound, :denied]` -- metadata `%{console, key, platform,
      user_id}`. Telemetry rather than a per-event log (the matching log is
      `debug`), since denied traffic volume is set by the sender.
  """

  require Logger

  alias Raxol.Gateway.{Pairing, Route, SessionRouter}

  @doc """
  Authorize `route` and, if allowed, deliver `event` to its session.

  Returns `SessionRouter.route/3`'s own result when allowed -- `:ok`, or
  `{:error, :max_sessions | :rate_limited}` -- and `{:error, :unauthorized}` when
  not. Note that `:ok` carries `route/3`'s meaning: the event was accepted for
  delivery, not that it was served.
  """
  @spec route(atom(), Route.t(), term()) :: :ok | {:error, term()}
  def route(base \\ Raxol.Console, %Route{} = route, event) do
    case authorize(base, route) do
      :allow ->
        SessionRouter.route(router_name(base), route, event)

      :deny ->
        deny(base, route)
        {:error, :unauthorized}
    end
  end

  @doc """
  Whether `route` would be authorized, without routing anything.

  For a feed that wants to answer an unpaired sender (with a pairing code, say)
  rather than drop them silently.
  """
  @spec authorized?(atom(), Route.t()) :: boolean()
  def authorized?(base \\ Raxol.Console, %Route{} = route),
    do: authorize(base, route) == :allow

  # The caller is the deployment's feed loop, pumping a batch it cannot replay.
  # An uncaught exit here -- Pairing crashed, or is inside its own restart --
  # would take that loop down mid-batch and lose or duplicate whatever it was
  # holding, which is a large price for a question we already know the safe
  # answer to. A gate that cannot answer denies.
  defp authorize(base, route) do
    Pairing.authorize(pairing_name(base), route)
  catch
    :exit, reason ->
      Logger.warning("#{base}: pairing server unreachable, denying: #{inspect(reason)}")
      :deny
  end

  @doc "The Pairing server name for a Console booted under `base`."
  @spec pairing_name(atom()) :: atom()
  def pairing_name(base \\ Raxol.Console), do: :"#{base}.pairing"

  @doc "The `SessionRouter` name for a Console booted under `base`."
  @spec router_name(atom()) :: atom()
  def router_name(base \\ Raxol.Console), do: :"#{base}.router"

  defp deny(base, route) do
    :telemetry.execute(
      [:raxol_console, :inbound, :denied],
      %{system_time: System.system_time()},
      %{
        console: base,
        key: Route.key(route),
        platform: route.platform,
        user_id: route.user_id
      }
    )

    # `debug`, not `info`: the rate is chosen by whoever is sending the denied
    # traffic, and this is the one path an unauthorized sender can reach at will
    # -- `Pairing` rate-limits `request_code/2` and locks out `confirm/2`, but a
    # denial costs nothing to provoke. At `info` a flood is unbounded log volume
    # carrying third-party chat and user ids. The telemetry event above is the
    # signal, and a handler can sample it.
    Logger.debug("#{base}: denied unauthorized #{route.platform} chat #{Route.key(route)}")
  end
end
