defmodule Mix.Tasks.RaxolEarn.Order.Signer do
  @moduledoc false
  # Signer backends for `mix raxol_earn.order --signer`: each returns the
  # provider adapter for on-chain calls, the buyer address, and the wallet
  # module that signs the Xochi intent.

  alias Mix.Tasks.RaxolEarn.Order.Errors
  alias Raxol.Agent.Secret
  alias Raxol.Earn.{HookClient, ProviderAdapter, SignerSidecar}

  # The managed SCA agent the `sca` and `privy` backends drive.
  # The nested wallets repeat it: their `use` options are read at compile time,
  # before this module's attributes exist to them.
  @account "0x468aeae798b3a6548ac2401d276f83afdc172283"
  @health_timeout_ms 5_000

  defmodule SessionKey do
    @moduledoc false
    # The ORDER_KEY session-key EOA.
    use Raxol.Payments.Wallets.Env, env_var: "ORDER_KEY"
  end

  defmodule ScaWallet do
    @moduledoc false
    # The managed agent as a deployed Modular Account v2: the session key signs
    # through the installed single-signer validation module.
    use Raxol.Earn.Wallet.SCA,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      signer: Mix.Tasks.RaxolEarn.Order.Signer.SessionKey,
      signer_entity_id: 0
  end

  defmodule Sma7702Wallet do
    @moduledoc false
    # The managed agent as an EIP-7702 Semi-Modular Account: its only authorized
    # signer is its own managed authority, reached through the Privy sidecar.
    use Raxol.Earn.Wallet.Sma7702,
      account_address: "0x468aeae798b3a6548ac2401d276f83afdc172283",
      chain_id: 8453,
      provider: {Mix.Tasks.RaxolEarn.Order.Signer, :signing_provider}
  end

  @type backend :: {ProviderAdapter.adapter(), String.t(), module()}

  # `privy` (default): Virtuals-delegated signing via the Node sidecar. An
  # ERC-20 paymaster fronts the gas and bills the buyer in USDC per UserOp.
  @spec build(String.t(), pos_integer(), String.t()) :: backend()
  def build("privy", from, rpc) do
    _ = fetch_env!("RAXOL_ACP_WALLET_ID")
    _ = fetch_env!("RAXOL_ACP_SIGNER_PRIVATE_KEY")
    address = fetch_env!("RAXOL_ACP_WALLET_ADDRESS")
    check_7702_account(String.downcase(address), Sma7702Wallet.address())
    start_sidecar!(address)

    {privy_adapter(address, %{from => rpc}), address, Sma7702Wallet}
  end

  # `sca`: direct ERC-4337, the session key signs UserOps for your own bundler
  # and paymaster (Alchemy serves both on one URL). The adapter only sends
  # sponsored UserOps, so there is no unsponsored fallback.
  def build("sca", from, rpc) do
    # Wrapped at the read, like the RPC URLs: it embeds the provider key.
    bundler = Secret.new(fetch_env!("ORDER_BUNDLER_URL"))
    policy = fetch_env!("ORDER_PAYMASTER_POLICY")

    provider =
      ProviderAdapter.SCA.new(
        wallet: ScaWallet,
        chains: %{from => rpc},
        wallet_opts: [
          bundler_url: bundler,
          paymaster_url: bundler,
          paymaster_policy_id: policy
        ]
      )

    {provider, ScaWallet.address(), ScaWallet}
  end

  # `eoa`: not a registered agent, so createJob works but messaging 404s.
  def build("eoa", from, rpc) do
    provider =
      ProviderAdapter.JSONRPC.new(
        chains: %{from => rpc},
        private_key: decode_key(fetch_env!("ORDER_KEY"))
      )

    {provider, SessionKey.address(), SessionKey}
  end

  def build(other, _from, _rpc),
    do: Mix.raise("unknown --signer #{inspect(other)} (want privy | sca | eoa)")

  # The adapter `Sma7702Wallet` signs through, rebuilt per signature from the
  # sidecar URL rather than held as process-global state, and verified first.
  @spec signing_provider() :: ProviderAdapter.adapter()
  def signing_provider, do: @account |> privy_adapter(%{}) |> verify_sidecar!()

  # Fails closed on the Privy backend: whoever answers at the adapter's own
  # sidecar URL must report the adapter's wallet, so a missing, foreign or
  # stale sidecar raises instead of signing or broadcasting. Other backends
  # sign locally and pass through.
  @spec verify_sidecar!(ProviderAdapter.adapter()) :: ProviderAdapter.adapter()
  def verify_sidecar!(provider) do
    case verify_sidecar(provider) do
      :ok -> provider
      {:error, {:sidecar_unhealthy, url, reason}} -> Mix.raise(Errors.sidecar(reason, url))
    end
  end

  # `/health` is unauthenticated and self-reported, and it is a separate request
  # from the write that follows: this stops a stale or foreign sidecar, not a
  # hostile process on the same host.
  @spec verify_sidecar(ProviderAdapter.adapter()) ::
          :ok | {:error, {:sidecar_unhealthy, String.t(), term()}}
  def verify_sidecar(%{
        adapter: ProviderAdapter.Privy,
        config: %{sidecar_url: url, address: address}
      }) do
    case SignerSidecar.await_health(url, @health_timeout_ms, address) do
      :ok -> :ok
      {:error, reason} -> {:error, {:sidecar_unhealthy, url, reason}}
    end
  end

  def verify_sidecar(_provider), do: :ok

  # The task's two writes. Each re-checks the sidecar first, as signing does,
  # and returns a failed check as an error so the caller can say what is
  # already on chain.
  @spec create_job(ProviderAdapter.adapter(), pos_integer(), String.t(), map()) ::
          {:ok, String.t()} | {:error, term()}
  def create_job(provider, chain_id, core, params) do
    with :ok <- verify_sidecar(provider),
         do: HookClient.create_job(provider, chain_id, core, params)
  end

  @spec send_calls(ProviderAdapter.adapter(), pos_integer(), [ProviderAdapter.call()]) ::
          {:ok, [String.t()]} | {:error, term()}
  def send_calls(provider, chain_id, calls) do
    with :ok <- verify_sidecar(provider),
         do: ProviderAdapter.send_calls(provider, chain_id, calls)
  end

  defp privy_adapter(address, chains),
    do:
      ProviderAdapter.Privy.new(
        sidecar_url: SignerSidecar.base_url([]),
        address: address,
        chains: chains
      )

  # The account is the verifyingContract of the replay-safe domain the wallet
  # signs over, so a different managed wallet would sign the wrong hash and
  # surface only as an opaque 401 after a sidecar round trip.
  defp check_7702_account(account, account), do: :ok

  defp check_7702_account(given, account) do
    Mix.raise(
      "RAXOL_ACP_WALLET_ADDRESS #{given} is not the 7702 account Sma7702Wallet " <>
        "signs for (#{account}); the intent would be signed over the wrong " <>
        "replay-safe hash"
    )
  end

  # A plain `start_link` cannot report a failed Node start: the linked exit
  # kills the task first. The trapping start turns it back into a reason.
  defp start_sidecar!(address) do
    case SignerSidecar.start_link_or_error(expect_address: address) do
      {:ok, pid} -> pid
      {:error, reason} -> Mix.raise(Errors.sidecar(reason))
    end
  end

  defp decode_key("0x" <> hex), do: Base.decode16!(hex, case: :mixed)
  defp decode_key(hex), do: Base.decode16!(hex, case: :mixed)

  defp fetch_env!(name) do
    case System.get_env(name) do
      nil -> Mix.raise("set #{name}")
      "" -> Mix.raise("set #{name}")
      v -> v
    end
  end
end
