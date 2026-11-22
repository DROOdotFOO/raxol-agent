defmodule Raxol.Payments.Protocols.Xochi.DepositSignerPin do
  @moduledoc false
  # The expected signer of a deposit-route `deposit_attestation`. An operator
  # pin (`opts[:deposit_attestation_signer]`, else
  # `config :raxol_payments, :xochi_deposit_attestation_signer`) wins. The
  # capability matrix's signer comes from the same endpoint that serves the
  # quote, so a compromised endpoint could publish its own key and attest a
  # forged deposit address: that fallback is refused when the pin is required
  # (`config :raxol_payments, :require_deposit_signer_pin`, default
  # `Raxol.Payments.Deployment.production?/0`). `resolve/2` backs signer
  # resolution in `Raxol.Payments.Protocols.Xochi`, which delegates
  # `assert_pinned!/0,2` and documents them.

  require Logger

  alias Raxol.Payments.{Deployment, EIP712}

  @type error ::
          :deposit_signer_unpinned | :invalid_deposit_signer_pin | :deposit_signer_unavailable

  # Resolve the signer. `matrix_signer` is called only when no operator pin is
  # set and the pin is not required.
  @spec resolve(keyword(), (-> String.t() | nil)) :: {:ok, String.t()} | {:error, error()}
  def resolve(opts, matrix_signer) when is_function(matrix_signer, 0) do
    case operator_pin(opts) do
      nil -> fallback(required?(), matrix_signer)
      pin -> if EIP712.address?(pin), do: {:ok, pin}, else: {:error, :invalid_deposit_signer_pin}
    end
  end

  # Fail-open: no valid pin and the pin relaxed (only an explicit `false`
  # relaxes it, as in `required?/0`), so the matrix signer would be trusted.
  # Required with no pin is not fail-open: it boots, and every deposit route is
  # refused with `:deposit_signer_unpinned`.
  @spec fail_open?(term(), term()) :: boolean()
  def fail_open?(pin, require_pin?), do: not EIP712.address?(pin) and require_pin? == false

  @spec assert_pinned!() :: :ok
  def assert_pinned!, do: assert_pinned!(configured_pin(), required?())

  @spec assert_pinned!(term(), term()) :: :ok
  def assert_pinned!(pin, require_pin?) do
    cond do
      unset(pin) != nil and not EIP712.address?(pin) ->
        raise ArgumentError,
              "Xochi deposit-attestation signer pin is not a 0x + 40-hex address."

      fail_open?(pin, require_pin?) ->
        raise ArgumentError,
              "Xochi deposit-attestation signer is not pinned (fail-open): deposit " <>
                "routes would trust a signer published by the quote endpoint itself. " <>
                "Set config :raxol_payments, :xochi_deposit_attestation_signer to the " <>
                "canonical 0x signer address, or set :require_deposit_signer_pin to true."

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

  defp fallback(true, _matrix_signer), do: {:error, :deposit_signer_unpinned}

  defp fallback(false, matrix_signer) do
    signer = matrix_signer.()

    if EIP712.address?(signer) do
      Logger.warning(
        "Xochi deposit route trusts the capability matrix's attestation signer: " <>
          "no :xochi_deposit_attestation_signer is pinned and :require_deposit_signer_pin is false"
      )

      {:ok, signer}
    else
      {:error, :deposit_signer_unavailable}
    end
  end

  # Unset, a deployed release requires the pin. Only an explicit `false`
  # relaxes it; any other configured value requires it.
  defp required? do
    case Application.fetch_env(:raxol_payments, :require_deposit_signer_pin) do
      {:ok, false} -> false
      {:ok, _} -> true
      :error -> Deployment.production?()
    end
  end
end
