defmodule Raxol.Payments.Ramp.Peer.MakerIO do
  @moduledoc """
  Trusted maker/protocol boundary. Never log inputs, responses or exceptions.

  `prepare` revalidates fresh maker pricing, own-account seller setup, Base USDC,
  sender, allowance and transaction targets. It returns unsigned wallet material
  only; registration and credentials remain inside this implementation. It must
  not broadcast. `reconcile` verifies sender, chain, calldata, finality and the
  existing deposit/order against protocol data; unknown outcomes stay pending.
  The pending public action ref supplied to `reconcile` must be reconciled,
  including a pending withdrawal; an old deposit receipt cannot resolve it.
  A missing mapping must be rebuilt by operation reference, never by depositing.
  `unmatched` excludes active intents and fees. Confirmed fiat fills alone count
  as delivered. Implementations must bind operation refs to the original wallet.

  Runtime injection is `{module, handle}` under `:maker_io`. The default `LiveIO` implements public protocol/indexer reads and unsigned
  planning; deployments configure supervised resources and user-wallet setup.
  """
  @callback prepare(term(), String.t(), :create_deposit | :withdraw_unmatched, map(), map()) ::
              {:ok, map()} | {:error, atom()}
  @callback reconcile(term(), String.t(), map()) ::
              {:ok, map()} | {:error, atom()}
end

defmodule Raxol.Payments.Ramp.Peer.MakerWallet do
  @moduledoc """
  User-wallet boundary, injected as `:maker_wallet` (`{module, handle}`).

  `validate` independently checks the unsigned plan's chain, sender, token,
  escrow/spender, calldata, value, amount and expiry against the reviewed terms.
  No unlimited approval is allowed. `request` asks the user to approve every
  signature/transaction and registers submission with the trusted maker I/O by
  operation reference. It returns no signature, key or provider identifier.
  A request is single-use, including when its response is lost.
  """
  @callback validate(term(), map(), map()) :: :ok | {:error, atom()}
  @callback request(term(), String.t(), String.t(), map()) :: :ok | {:error, atom()}
end
