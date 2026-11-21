defmodule Raxol.Agent.ChildEnv do
  @moduledoc """
  The environment for a child process that runs code a model or a third party
  chose: `Raxol.Core.ChildEnv`'s scrub, widened.

  `Raxol.Core.ChildEnv` unsets a fixed list of six raxol variables (plus its
  configured `:extra_secrets`). Every other credential in the node's
  environment would still reach a directive's shell command or a benchmarked
  agent package, for a prompt-injected `printenv` to read. On top of that list,
  this module unsets, at spawn time:

    * every variable whose name looks like a credential (case-insensitive): a
      suffix of `_KEY`, `_KEY_ID`, `_APIKEY`, `_TOKEN`, `_PRIVKEY`,
      `_SECRET`, `_PASSWORD`, `_PASS`, `_PASSPHRASE`, `_MNEMONIC`,
      `_SEED_PHRASE`, `_CREDENTIALS`, `_DSN` or `_RPC`; an `RPC_` name
      segment (`RPC_BASE`, `BASE_RPC_URL`, `ORDER_RPC_8453`), since a provider
      RPC URL embeds its API key; `MNEMONIC`, `SEED_PHRASE`, `SSH_AUTH_SOCK`
      (agent forwarding is a push credential too); and `OP_SESSION_*`
      (1Password CLI sessions);
    * the explicit names in `secrets/0`: the provider key variables of
      `Raxol.Agent.Backend.Catalog` and the earn and order credentials whose
      names no pattern catches.

  So `GH_TOKEN`, `GITHUB_TOKEN`, `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY`,
  `AWS_SESSION_TOKEN` and `SSH_AUTH_SOCK` are unset too, on purpose: a prompt-injected
  command could otherwise push with, or spend on, the operator's account.

  ## Opting a credential back in

  Per command, name it in the directive's `env`; a name the caller gives is
  kept, and only that child gets it:

      Directive.shell("gh pr list", env: [{"GH_TOKEN", System.fetch_env!("GH_TOKEN")}])

  Node-wide, list it under `Raxol.Core.ChildEnv`'s `pass:`. That hands it to
  EVERY child this node spawns (directive shells, the earn bench's agent
  packages), so prefer the per-command form:

      config :raxol_core, Raxol.Core.ChildEnv, pass: ["GH_TOKEN"]

  The pattern is duplicated in `Raxol.AgentClientProtocol.Transport.Stdio`,
  which cannot depend on this package; `child_env_test.exs` checks that the
  two `credential_pattern/0`s are the same. That transport applies only the
  pattern: `secrets/0` and `pass:` reach an ACP agent only if its spawner
  passes them (`unset_env: Raxol.Agent.ChildEnv.secrets()`). MCP stdio
  servers are spawned by raxol_mcp with `Raxol.Core.ChildEnv` alone.

  This stops inheritance only. A process running as the same user can still
  read the node's launch environment (`/proc/<pid>/environ`, including the
  port helper's via `$PPID`); keeping a key from those means not putting it
  in the node's environment at all.
  """

  alias Raxol.Agent.Backend.Catalog

  @credential ~r/(_KEY|_KEY_ID|_APIKEY|_TOKEN|_PRIVKEY|_SECRET|_PASSWORD|_PASS|_PASSPHRASE|_MNEMONIC|_SEED_PHRASE|_CREDENTIALS|_DSN|_RPC)\z|(\A|_)RPC_|\A(MNEMONIC|SEED_PHRASE|SSH_AUTH_SOCK)\z|\AOP_SESSION_/i

  # Credentials no pattern matches: the ORDER_* URLs may embed provider keys,
  # PROTON_UID pairs with the Lumo tokens, and the sidecar URL reaches the
  # earn signing sidecar.
  @named ~w(
    ORDER_BUNDLER_URL
    ORDER_XOCHI_URL
    PROTON_UID
    RAXOL_ACP_SIDECAR_URL
  )

  @doc false
  @spec credential_pattern() :: Regex.t()
  def credential_pattern, do: @credential

  @doc """
  The explicit names unset besides the pattern matches, before the
  operator's `pass:` list is applied.
  """
  @spec secrets() :: [String.t()]
  def secrets do
    catalog = Enum.flat_map(Catalog.entries(), & &1.env_keys)
    Enum.uniq(catalog ++ @named ++ Raxol.Core.ChildEnv.secrets())
  end

  @doc "Whether `name` is treated as a credential in a child's environment."
  @spec secret?(String.t()) :: boolean()
  def secret?(name) when is_binary(name), do: name in secrets() or credential_name?(name)

  defp credential_name?(name), do: Regex.match?(@credential, name)

  @doc """
  A `Port.open/2` `:env` value: `env` followed by every credential variable it
  does not name, mapped to `false` (unset).
  """
  @spec port_env([{String.t() | charlist(), String.t() | charlist() | false}]) ::
          [{charlist(), charlist() | false}]
  def port_env(env \\ []) do
    base = Raxol.Core.ChildEnv.port_env(env)
    named = MapSet.new(base, fn {name, _value} -> name end)

    extra =
      for name <- unset_names(), name = String.to_charlist(name), name not in named do
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
    base = Raxol.Core.ChildEnv.cmd_env(env)
    named = MapSet.new(base, fn {name, _value} -> name end)
    base ++ for(name <- unset_names(), name not in named, do: {name, nil})
  end

  # Names set in the node now that are credentials, plus every explicit name
  # (set or not, so a variable exported after this call is still covered when
  # the child starts), minus the operator's `pass:` list.
  defp unset_names do
    explicit = secrets()
    present = System.get_env() |> Map.keys() |> Enum.filter(&credential_name?/1)
    pass = pass()

    (explicit ++ present)
    |> Enum.uniq()
    |> Enum.reject(&(&1 in pass))
  end

  # Read after `Raxol.Core.ChildEnv.port_env/1` or `cmd_env/1`, which raise
  # on an invalid config, so a malformed `pass:` never reaches here.
  defp pass do
    case Application.get_env(:raxol_core, Raxol.Core.ChildEnv, []) do
      config when is_list(config) -> config |> Keyword.get(:pass, []) |> List.wrap()
      _other -> []
    end
  end
end
