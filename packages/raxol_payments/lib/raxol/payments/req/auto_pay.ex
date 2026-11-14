defmodule Raxol.Payments.Req.AutoPay do
  @moduledoc """
  Req plugin that transparently handles HTTP 402 Payment Required responses.

  Intercepts 402 responses, detects the payment protocol (x402 or MPP),
  checks spending budget, signs a payment, and retries the request with
  payment credentials attached. Retries at most once per request to
  prevent infinite loops.

  ## Usage

      req =
        Req.new(url: "https://api.example.com/data")
        |> Raxol.Payments.Req.AutoPay.attach(
          wallet: Raxol.Payments.Wallets.Env,
          protocols: [:x402, :mpp],
          ledger: ledger_pid,
          policy: SpendingPolicy.dev(),
          agent_id: :my_agent
        )

      {:ok, response} = Req.get(req)

  ## Options

  - `:wallet` (required) -- module implementing `Raxol.Payments.Wallet`
  - `:protocols` -- list of protocol atoms, default `[:x402, :mpp]`
  - `:policy` (required) -- `SpendingPolicy` struct. On every payment the
    request URL host must be in `approved_domains` (`nil` allows any), an amount above
    `require_confirmation_above` needs `:on_confirm` to approve, and the
    challenge amount must be at most `per_request_max`. The cumulative caps,
    `session_max` and `lifetime_max`, are enforced only with a `:ledger`.
    Every amount is compared in one unit, human amounts of the policy's
    `currency` (`SpendingPolicy.unit/1`; US dollars by default): an x402
    challenge is priced only for USDC, an MPP challenge from its currency
    (ISO 4217 minor units for USD, EUR and CHF; registered decimals for a
    stablecoin), and a challenge in any other unit is refused with
    `%{error: :currency_mismatch}` before anything is reserved. `attach/2`
    raises `ArgumentError` without a policy, or when `per_request_max` (and,
    with a `:ledger`, `session_max`, `session_window_ms` and `lifetime_max`) is
    not a finite positive value; for development pass `SpendingPolicy.dev()`
  - `:ledger` -- Ledger server; with it, every payment is also reserved
    against the policy's session and lifetime caps, atomically, before
    signing (optional). The reservation is given back only if nothing was
    signed; once the signed payment is sent it stays spent, whatever the
    paid retry returns, because the server can still settle it
  - `:agent_id` -- identifier for ledger tracking (required if ledger given)
  - `:on_confirm` -- 2-arity function `(amount, domain) -> :approve | :deny`
    called when `policy.require_confirmation_above` is exceeded. Runs
    synchronously inside the Req response step. Absent or non-`:approve`
    return denies the payment.
  """

  alias Raxol.Payments.{Ledger, PolicyGate, Protocol, SpendingPolicy}

  @default_protocols [:x402, :mpp]

  @doc """
  Attach the auto-pay plugin to a Req request.

  Raises `ArgumentError` when `opts` has no `:policy` `SpendingPolicy`.
  """
  @spec attach(Req.Request.t(), keyword()) :: Req.Request.t()
  def attach(%Req.Request{} = req, opts) do
    validate_opts!(opts)
    Req.Request.append_response_steps(req, auto_pay: &handle_response(&1, opts))
  end

  @doc false
  # Shared with `Raxol.Payments.Req.AgentPlugin.auto_pay/1`, which checks at
  # build time rather than when the plugin is first applied.
  @spec validate_opts!(keyword()) :: :ok
  def validate_opts!(opts) do
    case Keyword.get(opts, :policy) do
      %SpendingPolicy{} = policy ->
        validate_policy!(policy, Keyword.get(opts, :ledger) != nil)

      nil ->
        raise ArgumentError,
              "Raxol.Payments.Req.AutoPay requires a :policy option (a " <>
                "%Raxol.Payments.SpendingPolicy{}); none was given. The policy's " <>
                "per_request_max, approved_domains and require_confirmation_above " <>
                "apply to every payment; its session_max and lifetime_max need a " <>
                ":ledger as well. Pass policy: Raxol.Payments.SpendingPolicy.dev() " <>
                "for development"

      other ->
        raise ArgumentError,
              "Raxol.Payments.Req.AutoPay :policy must be a " <>
                "%Raxol.Payments.SpendingPolicy{}, got #{policy_shape(other)}. Pass " <>
                "policy: Raxol.Payments.SpendingPolicy.dev() for development"
    end
  end

  # The caps the payment path compares against must be usable before the first
  # 402, not discovered per request: `per_request_max` always, the cumulative
  # caps when a ledger enforces them, and a currency to price challenges in.
  defp validate_policy!(policy, ledger?) do
    fields =
      if ledger?,
        do: [:per_request_max, :session_max, :session_window_ms, :lifetime_max],
        else: [:per_request_max]

    case SpendingPolicy.validate(policy, fields) do
      :ok ->
        :ok

      {:error, {:invalid_policy, field}} ->
        raise ArgumentError,
              "Raxol.Payments.Req.AutoPay :policy #{field} must be a finite positive " <>
                "Decimal (session_window_ms a positive integer), got " <>
                inspect(Map.fetch!(policy, field))
    end

    if SpendingPolicy.unit(policy) == nil do
      raise ArgumentError,
            "Raxol.Payments.Req.AutoPay :policy currency must be a currency code " <>
              "string, got #{inspect(policy.currency)}"
    end

    :ok
  end

  defp policy_shape(%module{}), do: "a #{inspect(module)} struct"
  defp policy_shape(value) when is_map(value), do: "a map"
  defp policy_shape(value) when is_list(value), do: "a list"
  defp policy_shape(value) when is_atom(value), do: "the atom #{inspect(value)}"
  defp policy_shape(_value), do: "another term"

  @spec handle_response({Req.Request.t(), Req.Response.t()}, keyword()) ::
          {Req.Request.t(), Req.Response.t()}
  defp handle_response({request, %Req.Response{status: 402} = response}, opts) do
    wallet = Keyword.fetch!(opts, :wallet)
    protocols = Keyword.get(opts, :protocols, @default_protocols)
    headers = Raxol.Payments.Headers.flatten(response.headers)

    with {:ok, protocol_mod, challenge} <- detect_and_parse(protocols, headers),
         :ok <- require_policy_unit(challenge, Keyword.fetch!(opts, :policy)) do
      amount = protocol_mod.amount(challenge)
      host = request_host(request)

      case reserve_budget(protocol_mod, amount, host, opts) do
        :ok ->
          # Budget is now reserved. It is given back only if nothing was
          # signed; once a signed payment has left the process, the server can
          # settle it whatever it answers, so the reservation stays spent.
          settle(request, response, protocol_mod, challenge, wallet, amount, host, opts)

        {:error, _} = denied ->
          handle_failure(denied, request, response)
      end
    else
      error -> handle_failure(error, request, response)
    end
  end

  defp handle_response(req_response, _opts), do: req_response

  # Sign and retry under a reservation already made by `reserve_budget/4`.
  #
  # The reservation is released only when signing failed (an error or a raise
  # out of `build_payment/2`), because then no payment left this process. Once
  # the signed payment is sent, the server holds an authorization it can settle
  # on-chain until it expires, whatever status it answers with or whether the
  # connection survives: a 500 or a dropped retry keeps the spend recorded, so a
  # server that answers every paid retry with an error cannot sign its way past
  # `session_max` and `lifetime_max`.
  defp settle(request, response, protocol_mod, challenge, wallet, amount, host, opts) do
    case build_payment_safely(protocol_mod, challenge, wallet) do
      {:ok, payment_headers} ->
        # Build retry request: add payment headers and strip the auto_pay step
        # to prevent infinite loops if the server returns 402 again.
        retry_request =
          request
          |> add_payment_headers(payment_headers)
          |> remove_auto_pay_step()

        case Req.Request.run(retry_request) do
          {_req, %Req.Response{} = paid_or_failed} ->
            {request, paid_or_failed}

          {:error, reason} ->
            {request, payment_retry_error(response, reason)}
        end

      {:error, _} = error ->
        # Signed nothing, so nothing was paid: refund the reservation.
        release_budget(protocol_mod, amount, host, opts)
        handle_failure(error, request, response)
    end
  end

  # A raise while building the payment (a malformed challenge field the parser
  # let through) happens before any header is sent: refund the reservation
  # rather than leak it. The exception module is kept, its message (which may
  # carry challenge data) is not.
  defp build_payment_safely(protocol_mod, challenge, wallet) do
    protocol_mod.build_payment(challenge, wallet)
  rescue
    error -> {:error, {:build_payment_raised, error.__struct__}}
  end

  defp payment_retry_error(response, reason) do
    %{response | body: %{error: :payment_retry_failed, reason: sanitize_error(reason)}}
  end

  defp handle_failure({:error, :no_matching_protocol}, request, response),
    do: {request, response}

  defp handle_failure(
         {:error, {:over_budget, limit_type, _amount}},
         request,
         response
       ),
       do: {request, %{response | body: %{error: :budget_exceeded, limit: limit_type}}}

  defp handle_failure(
         {:error, {:gate_denied, {:domain_not_approved, domain}}},
         request,
         response
       ),
       do: {request, %{response | body: %{error: :domain_not_approved, domain: domain}}}

  defp handle_failure(
         {:error, {:gate_denied, {:requires_confirmation, amount, domain}}},
         request,
         response
       ) do
    body = %{error: :requires_confirmation, amount: amount, domain: domain}
    {request, %{response | body: body}}
  end

  defp handle_failure({:error, {:currency_mismatch, unit, policy_unit}}, request, response) do
    body = %{error: :currency_mismatch, currency: unit, policy_currency: policy_unit}
    {request, %{response | body: body}}
  end

  defp handle_failure(
         {:error, {:gate_denied, :missing_host}},
         request,
         response
       ),
       do: {request, %{response | body: %{error: :missing_host}}}

  defp handle_failure({:error, reason}, request, response) do
    body = %{error: :payment_failed, reason: sanitize_error(reason)}
    {request, %{response | body: body}}
  end

  @spec detect_and_parse([atom()], Raxol.Payments.Headers.headers()) ::
          {:ok, module(), map()} | {:error, :no_matching_protocol}
  defp detect_and_parse(protocols, headers) do
    Enum.find_value(protocols, {:error, :no_matching_protocol}, fn proto_atom ->
      mod = Protocol.resolve(proto_atom)

      if mod.detect?(402, headers) do
        case mod.parse_challenge(headers) do
          {:ok, challenge} -> {:ok, mod, challenge}
          {:error, _} -> nil
        end
      end
    end)
  end

  # `amount/1` is in human units of the challenge's `:unit`; the caps are in
  # the policy's. A challenge priced in another unit (or in none) is refused
  # before the gate, never compared across units.
  defp require_policy_unit(challenge, policy) do
    case {Map.get(challenge, :unit), SpendingPolicy.unit(policy)} do
      {unit, unit} when is_binary(unit) -> :ok
      {unit, policy_unit} -> {:error, {:currency_mismatch, unit, policy_unit}}
    end
  end

  # Run the policy gate then atomically reserve the budget. `:ok` means the spend
  # is authorized and recorded; `settle/8` releases it with `release_budget/4`
  # only if nothing was signed.
  @spec reserve_budget(module(), Decimal.t(), String.t() | nil, keyword()) ::
          :ok | {:error, term()}
  defp reserve_budget(protocol_mod, amount, host, opts) do
    with :ok <- enforce_policy_gate(Keyword.get(opts, :policy), amount, host, opts) do
      enforce_budget(protocol_mod, amount, host, opts)
    end
  end

  # Refund a reservation made by `reserve_budget/4`. Mirrors `do_enforce_budget`'s
  # guard: budget is only reserved when both a policy and a ledger are present, so
  # a release fires only in that same case (no spurious refund otherwise).
  @spec release_budget(module(), Decimal.t(), String.t() | nil, keyword()) :: :ok
  defp release_budget(protocol_mod, amount, host, opts) do
    with %SpendingPolicy{} <- Keyword.get(opts, :policy),
         ledger when not is_nil(ledger) <- Keyword.get(opts, :ledger) do
      agent_id = Keyword.get(opts, :agent_id, :unknown)
      metadata = %{protocol: protocol_mod.name(), domain: host, reason: :payment_failed}
      Ledger.release(ledger, agent_id, amount, metadata)
    else
      _ -> :ok
    end
  end

  defp enforce_policy_gate(%SpendingPolicy{} = _policy, _amount, host, _opts)
       when host in [nil, ""],
       do: {:error, {:gate_denied, :missing_host}}

  defp enforce_policy_gate(%SpendingPolicy{} = policy, amount, host, opts) do
    case PolicyGate.evaluate(policy, amount, host, on_confirm: Keyword.get(opts, :on_confirm)) do
      :ok -> :ok
      {:deny, reason} -> {:error, {:gate_denied, reason}}
    end
  end

  defp enforce_budget(protocol_mod, amount, host, opts) do
    do_enforce_budget(
      Keyword.get(opts, :policy),
      Keyword.get(opts, :ledger),
      protocol_mod,
      amount,
      host,
      opts
    )
  end

  # No ledger: no history to hold the cumulative caps against, but the
  # per-request cap needs none, so it is enforced here with the same check and
  # the same refusal as the ledger path.
  defp do_enforce_budget(%SpendingPolicy{} = policy, nil, _proto, amount, _host, _opts) do
    case Ledger.check_request(amount, policy) do
      :ok -> :ok
      {:over_limit, limit_type} -> {:error, {:over_budget, limit_type, amount}}
    end
  end

  defp do_enforce_budget(
         %SpendingPolicy{} = policy,
         ledger,
         protocol_mod,
         amount,
         host,
         opts
       ) do
    agent_id = Keyword.get(opts, :agent_id, :unknown)
    metadata = %{protocol: protocol_mod.name(), domain: host}

    case Ledger.try_spend(ledger, agent_id, amount, policy, metadata) do
      :ok -> :ok
      {:over_limit, limit_type} -> {:error, {:over_budget, limit_type, amount}}
    end
  end

  defp request_host(%Req.Request{url: %URI{host: host}})
       when is_binary(host) and host != "",
       do: host

  defp request_host(%Req.Request{url: url}) when is_binary(url) do
    case URI.parse(url) do
      %URI{host: host} when is_binary(host) and host != "" -> host
      _ -> nil
    end
  end

  defp request_host(_), do: nil

  defp add_payment_headers(request, headers) do
    Enum.reduce(headers, request, fn {key, value}, req ->
      Req.Request.put_header(req, key, value)
    end)
  end

  # Strip internal details from error reasons before including in response bodies.
  # Prevents leaking API URLs, internal state, or cryptographic details.
  defp sanitize_error({:sign_failed, _}), do: :sign_failed
  defp sanitize_error({:op_failed, _code, _output}), do: :wallet_unavailable
  defp sanitize_error({:request_failed, _}), do: :upstream_error
  defp sanitize_error(reason) when is_atom(reason), do: reason
  defp sanitize_error(_), do: :internal_error

  defp remove_auto_pay_step(request) do
    steps =
      request.response_steps
      |> Enum.reject(fn {name, _fun} -> name == :auto_pay end)

    %{request | response_steps: steps}
  end
end
