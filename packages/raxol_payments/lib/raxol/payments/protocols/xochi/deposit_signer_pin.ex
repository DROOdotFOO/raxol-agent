defmodule Raxol.Payments.Protocols.Xochi.DepositSignerPin do
  @moduledoc false
  # The expected signer of a deposit-route `deposit_attestation`. An operator
  # pin (`opts[:deposit_attestation_signer]`, else
  # `config :raxol_payments, :xochi_deposit_attestation_signer`) wins. The
  # capability matrix's signer comes from the same endpoint that serves the
  # quote, so a compromised endpoint could publish its own key and attest a
  # forged deposit address: that fallback is refused when the pin is required
  # (`config :raxol_payments, :require_deposit_signer_pin`, default
  # `Raxol.Payments.Deployment.production?/0`). Public entry points are
  # delegated from `Raxol.Payments.Protocols.Xochi`, which documents them.

  alias Raxol.Payments.Deployment

  @address_re ~r/\A0[xX][0-9a-fA-F]{40}\z/

  @type error ::
          :deposit_signer_unpinned | :invalid_deposit_signer_pin | :deposit_signer_unavailable

  @doc """
  Resolve the signer. `matrix_signer` is called only when no operator pin is
  set and the pin is not required.
  """
  @spec resolve(keyword(), (-> String.t() | nil)) :: {:ok, String.t()} | {:error, error()}
  def resolve(opts, matrix_signer) when is_function(matrix_signer, 0) do
    case operator_pin(opts) do
      nil -> fallback(required?(), matrix_signer)
      pin -> validate_pin(pin)
    end
  end

  # Fail-open: no valid pin and the pin not required, so the matrix signer
  # (the quote endpoint's own claim) would be trusted.
  @spec fail_open?(term(), boolean()) :: boolean()
  def fail_open?(pin, require_pin?), do: not valid?(pin) and require_pin? != true

  @spec assert_pinned!(term(), boolean()) :: :ok
  def assert_pinned!(pin, require_pin?) do
    if fail_open?(pin, require_pin?) do
      raise ArgumentError,
            "Xochi deposit-attestation signer is not pinned (fail-open): deposit " <>
              "routes would trust a signer published by the quote endpoint itself. " <>
              "Set config :raxol_payments, :xochi_deposit_attestation_signer to the " <>
              "canonical 0x signer address, or set :require_deposit_signer_pin to true."
    end

    :ok
  end

  defp operator_pin(opts) do
    case opts[:deposit_attestation_signer] ||
           Application.get_env(:raxol_payments, :xochi_deposit_attestation_signer) do
      "" -> nil
      pin -> pin
    end
  end

  defp validate_pin(pin) do
    if valid?(pin), do: {:ok, pin}, else: {:error, :invalid_deposit_signer_pin}
  end

  defp fallback(true, _matrix_signer), do: {:error, :deposit_signer_unpinned}

  defp fallback(false, matrix_signer) do
    case matrix_signer.() do
      signer when is_binary(signer) and signer != "" -> {:ok, signer}
      _ -> {:error, :deposit_signer_unavailable}
    end
  end

  # Explicit config wins both ways; unset, a deployed release requires the pin.
  defp required? do
    Application.get_env(:raxol_payments, :require_deposit_signer_pin, Deployment.production?())
  end

  defp valid?(pin), do: is_binary(pin) and Regex.match?(@address_re, pin)
end
