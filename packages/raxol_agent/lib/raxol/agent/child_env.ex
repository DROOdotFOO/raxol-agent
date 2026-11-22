defmodule Raxol.Agent.ChildEnv do
  @moduledoc """
  The environment for a child process that runs code a model or a third party
  chose: `Raxol.Core.ChildEnv`'s scrub plus this package's own names.

  `Raxol.Core.ChildEnv` does the matching: every variable whose name has a
  credential segment (`_KEY`, `_TOKEN`, `_SECRET`, `_PASSWORD`, `_MNEMONIC`,
  `_CREDENTIALS` and the rest), a database or broker URL, `RPC` anywhere but
  in `GRPC`, raxol's own secrets and `SSH_AUTH_SOCK`, minus its `pass:` list.
  On top of that, this module unsets:

    * the names in `secrets/0` that no pattern catches: the provider key
      variables of `Raxol.Agent.Backend.Catalog`, the ORDER_* URLs (which may
      embed provider keys), `PROTON_UID` (paired with the Lumo tokens) and
      the earn signing sidecar's URL;
    * the shapes Core denies neither by pattern nor by name: a `_PASS`,
      `_SEED_PHRASE` or `_DSN` suffix, a bare `SEED_PHRASE`, and
      `OP_SESSION_*` (1Password CLI sessions).

  Names are matched case-insensitively, as Core matches its own; `pass:`
  is exact.

  So `GH_TOKEN`, `GITHUB_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN` and `SSH_AUTH_SOCK` are unset too, on purpose: a
  prompt-injected command could otherwise push with, or spend on, the
  operator's account.

  ## Opting a credential back in

  Per command, name it in the directive's `env`; a name the caller gives is
  kept, and only that child gets it:

      Directive.shell("gh pr list", env: [{"GH_TOKEN", System.fetch_env!("GH_TOKEN")}])

  Node-wide, list it under `Raxol.Core.ChildEnv`'s `pass:`. That hands it to
  EVERY child this node spawns (directive shells, the earn bench's agent
  packages), so prefer the per-command form:

      config :raxol_core, Raxol.Core.ChildEnv, pass: ["GH_TOKEN"]

  The gap shapes are `Raxol.AgentClientProtocol.Transport.Stdio.credential_gaps/0`,
  which this module reuses. ACP's stdio transport applies Core's scrub plus
  those shapes, but not this module's named list, so an ACP agent still
  inherits the Catalog key variables, the ORDER_* URLs, `PROTON_UID` and the
  sidecar URL unless its spawner passes
  `unset_env: Raxol.Agent.ChildEnv.unset_names()`. MCP stdio servers are
  spawned by raxol_mcp with `Raxol.Core.ChildEnv` alone, so they still
  inherit gap-shaped variables (`SMTP_PASS`, `SENTRY_DSN`, `OP_SESSION_*`)
  until raxol_core covers them.

  Every function here reads `Raxol.Core.ChildEnv`'s config and raises
  `ArgumentError` when it is malformed (since raxol_core 2.9, an unknown or
  repeated key too).

  This stops inheritance only. A process running as the same user can still
  read the node's launch environment (`/proc/<pid>/environ`, including the
  port helper's via `$PPID`); keeping a key from those means not putting it
  in the node's environment at all.
  """

  alias Raxol.Agent.Backend.Catalog
  alias Raxol.AgentClientProtocol.Transport.Stdio
  alias Raxol.Core.ChildEnv, as: CoreEnv

  @named ~w(
    ORDER_BUNDLER_URL
    ORDER_XOCHI_URL
    PROTON_UID
    RAXOL_ACP_SIDECAR_URL
  )

  @doc """
  The names unset in every child whether or not the node has them: Core's
  set, the Catalog key variables and this package's own. Since 3.2 the
  operator's `pass:` names are left out, as Core leaves them out of its own.
  """
  @spec secrets() :: [String.t()]
  def secrets do
    pass = CoreEnv.pass()
    Enum.uniq(CoreEnv.secrets() ++ Enum.reject(own_named(), &(&1 in pass)))
  end

  @doc """
  Every name a child must not inherit: `secrets/0` plus each variable set in
  the node now that `secret?/1` denies. For a spawner that does not go
  through `port_env/1`, such as the ACP stdio transport's `:unset_env`.
  """
  @spec unset_names() :: [String.t()]
  def unset_names do
    present = System.get_env() |> Map.keys() |> Enum.filter(&secret?/1)
    Enum.uniq(secrets() ++ present)
  end

  @doc "Whether a child is denied `name`."
  @spec secret?(String.t()) :: boolean()
  def secret?(name) when is_binary(name) do
    CoreEnv.secret?(name) or (name not in CoreEnv.pass() and own?(name))
  end

  @spec own?(String.t()) :: boolean()
  defp own?(name),
    do: String.upcase(name) in own_named_upcase() or Regex.match?(Stdio.credential_gaps(), name)

  @spec own_named() :: [String.t()]
  defp own_named, do: Enum.flat_map(Catalog.entries(), & &1.env_keys) ++ @named

  @spec own_named_upcase() :: [String.t()]
  defp own_named_upcase, do: Enum.map(own_named(), &String.upcase/1)

  @doc """
  A `Port.open/2` `:env` value: `env` followed by every credential variable it
  does not name, mapped to `false` (unset).
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist() | false}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    base = CoreEnv.port_env(env)
    named = MapSet.new(base, fn {name, _value} -> name end)

    extra =
      for name <- own_unset(), name = String.to_charlist(name), name not in named do
        {name, false}
      end

    base ++ extra
  end

  @doc """
  A `System.cmd/3` `:env` value: `env` followed by every credential variable it
  does not name, mapped to `nil` (unset).
  """
  @spec cmd_env([{String.t(), String.t() | nil}]) :: [{String.t(), String.t() | nil}]
  def cmd_env(env \\ []) do
    base = CoreEnv.cmd_env(env)
    named = MapSet.new(base, fn {name, _value} -> name end)
    base ++ for(name <- own_unset(), name not in named, do: {name, nil})
  end

  # What Core leaves set that this module denies: its own names (set or not,
  # so one exported after this call is still covered when the child starts)
  # and the node's variables that are a gap shape or another case of an own
  # name, minus `pass:`.
  @spec own_unset() :: [String.t()]
  defp own_unset do
    pass = CoreEnv.pass()
    present = System.get_env() |> Map.keys() |> Enum.filter(&own?/1)

    (own_named() ++ present)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end
end
