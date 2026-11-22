defmodule Raxol.Payments.Protocols.Xochi.DepositSignerPin do
  @moduledoc false
  # The expected signer of a deposit-route `deposit_attestation`: only ever an
  # operator pin (`opts[:deposit_attestation_signer]`, else
  # `config :raxol_payments, :xochi_deposit_attestation_signer`). The
  # capability matrix is served by the same endpoint as the quote, so a signer
  # it publishes would let a compromised endpoint attest its own forged deposit
  # address; it is never consulted, in any deployment. `resolve/1` backs signer
  # resolution in `Raxol.Payments.Protocols.Xochi`, which delegates
  # `assert_pinned!/0,1` and documents them.

  alias Raxol.Payments.EIP712

  @type error :: :deposit_signer_unpinned | :invalid_deposit_signer_pin

  @spec resolve(keyword()) :: {:ok, String.t()} | {:error, error()}
  def resolve(opts) do
    case operator_pin(opts) do
      nil -> {:error, :deposit_signer_unpinned}
      pin -> if EIP712.address?(pin), do: {:ok, pin}, else: {:error, :invalid_deposit_signer_pin}
    end
  end

  @spec assert_pinned!() :: :ok
  def assert_pinned!, do: assert_pinned!(configured_pin())

  @spec assert_pinned!(term()) :: :ok
  def assert_pinned!(pin) do
    cond do
      unset(pin) == nil ->
        raise ArgumentError,
              "Xochi deposit-attestation signer is not pinned: every deposit route " <>
                "would be refused. Set config :raxol_payments, " <>
                ":xochi_deposit_attestation_signer to the canonical 0x signer address."

      not EIP712.address?(pin) ->
        raise ArgumentError,
              "Xochi deposit-attestation signer pin is not a valid 0x address " <>
                "(0x + 40 hex, with a correct EIP-55 checksum if mixed case)."

      true ->
        :ok
    end
  end

  defp operator_pin(opts), do: unset(opts[:deposit_attestation_signer]) || configured_pin()

  defp configured_pin,
    do: unset(Application.get_env(:raxol_payments, :xochi_deposit_attestation_signer))

  defp unset(nil), do: nil
  defp unset(""), do: nil
  defp unset(pin), do: pin
end
