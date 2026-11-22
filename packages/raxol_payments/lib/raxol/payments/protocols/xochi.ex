defmodule Raxol.Payments.Protocols.Xochi do
  @moduledoc """
  Xochi private execution protocol.

  Xochi is the default agent-facing protocol for cross-chain transfers.
  It routes intents through the Xochi dark pool where Riddler (and other
  solvers) compete to fill them. This is the cash-positive path with
  tier-based fees.

  Unlike x402/MPP, Xochi is not a 402-triggered protocol. It uses an
  explicit quote -> sign -> execute -> poll flow.

  ## Usage

      config = %{base_url: "https://api.xochi.fi", auth: {:member, "..."}}
      wallet = MyWallet

      {:ok, quote} = Xochi.get_quote(config, request)
      {:ok, exec} = Xochi.execute(config, quote, wallet, request)
      {:ok, status} = Xochi.poll_status(config, exec.intent_id, read_token: exec.read_token)

  ## Fee Tiers

  The fee is layered: a solver spread plus gas floor (never discounted), a venue
  fee, and a routing fee. Trust discounts carve the venue and routing layers only,
  so the solver floor is identical at every tier. Headline totals by tier and asset:

  | Tier           | Score | Stable | Volatile |
  |----------------|-------|--------|----------|
  | Standard       | 0-24  | 0.22%  | 0.40%    |
  | Trusted        | 25-49 | 0.19%  | 0.35%    |
  | Verified       | 50-74 | 0.15%  | 0.29%    |
  | Premium        | 75-99 | 0.12%  | 0.25%    |
  | Institutional  | 100+  | 0.10%  | 0.22%    |

  ## Origin-pull solver allowlist

  The origin pull authorizes the solver to collect funds from the agent wallet.
  The pull recipient/spender is the solver's collection address; by default it is
  not pinned (solver addresses rotate and there is no client-facing manifest). An
  operator who knows their solver set can pin it:

      config :raxol_payments, :pull_solver_allowlist, ["0xsolver...", "0xsolver2..."]

  When the list is set, a pull whose `to` (ERC-3009) or `spender` (Permit2) is
  not in it is rejected before any signature, whatever
  `:pull_require_solver_pin` says. When the list is empty, a Permit2 pull is
  always rejected, and an ERC-3009 pull is rejected when
  `config :raxol_payments, :pull_require_solver_pin` is `true`. That setting
  defaults to `Raxol.Payments.Deployment.production?/0`, so a deployed release
  requires the pin and development and tests do not; an explicit `true` or
  `false` overrides the default, and `false` matters only with an empty list.
  """

  @behaviour Raxol.Payments.Protocol

  alias Raxol.Payments.{Poll, TypedData}
  alias Raxol.Payments.Protocols.Xochi.EIP712, as: Served

  alias Raxol.Payments.Protocols.Xochi.{
    DepositSignerPin,
    IntentValidation,
    PullAuthorization,
    SignedRequest,
    SolverPin
  }

  alias Raxol.Payments.Xochi.{Capabilities, Client, DepositAttestation}

  alias Raxol.Payments.Xochi.Schemas.{
    DepositRouteRequest,
    ExecuteRequest,
    ExecuteResponse,
    Intent,
    IntentStatus,
    QuoteRequest,
    QuoteResponse
  }

  @impl true
  @spec name() :: String.t()
  def name, do: "Xochi"

  @impl true
  @spec detect?(integer(), [{String.t(), String.t()}]) :: boolean()
  def detect?(_status, _headers), do: false

  @impl true
  @spec parse_challenge([{String.t(), String.t()}]) ::
          {:error, :not_a_402_protocol}
  def parse_challenge(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec build_payment(map(), module()) :: {:error, :not_a_402_protocol}
  def build_payment(_challenge, _wallet), do: {:error, :not_a_402_protocol}

  @impl true
  @spec parse_receipt([{String.t(), String.t()}]) ::
          {:error, :not_a_402_protocol}
  def parse_receipt(_headers), do: {:error, :not_a_402_protocol}

  @impl true
  @spec amount(map()) :: Decimal.t()
  def amount(%{to_amount: amt}) when is_binary(amt), do: Decimal.new(amt)
  def amount(%{xochi_fee: fee}) when is_binary(fee), do: Decimal.new(fee)
  def amount(_challenge), do: Decimal.new(0)

  @doc """
  Request a cross-chain intent quote from Xochi.
  """
  @spec get_quote(Client.config(), QuoteRequest.t()) ::
          {:ok, QuoteResponse.t()} | {:error, term()}
  def get_quote(config, %QuoteRequest{} = request) do
    Client.get_quote(config, request)
  end

  @doc """
  Fetch a persisted intent by id (`GET /api/intent/:id`).

  Returns the authoritative corridor + amounts written at quote time, so a
  storefront can read what the buyer signed before settlement rather than trust
  a relayed, buyer-declared amount. `opts[:read_token]` is forwarded to
  `Client.get_intent/3` (see its "Read capability").
  """
  @spec get_intent(Client.config(), String.t(), keyword()) ::
          {:ok, Intent.t()} | {:error, term()}
  def get_intent(config, intent_id, opts \\ []) when is_binary(intent_id) do
    Client.get_intent(config, intent_id, opts)
  end

  @doc """
  Fetch a deposit-route quote and verify its `deposit_attestation` before
  returning the deposit instructions -- the authenticated form of a Tron-origin
  quote.

  A non-EVM origin has no gasless pull, so the quote returns a bare
  `deposit_address` the payer must fund directly. raxol verifies the
  `xochi-deposit-attestation:v3` attestation (`Raxol.Payments.Xochi.DepositAttestation`)
  BEFORE surfacing the address and fails closed otherwise. The signed message is
  rebuilt from the caller's own request (depositor `wallet`, origin chain and
  token, `from_amount`, destination chain and token, resolved recipient, refund
  address, settlement preference) plus the server-chosen quote values (intent
  and quote ids, deposit address and deadline, `to_amount`, `min_to_amount`), so
  an attestation for any other deal -- including a genuine one issued to someone
  else, or a replayed v1 -- does not recover to the pinned signer
  (`{:error, :attestation_mismatch}`). raxol never sends the funds; the returned
  instructions are for the caller's own Tron wallet to fund, then poll with
  `poll_status/3`.

  Also refused, before recovery:

    * `{:unsupported_deposit_attestation_version, advertised}` -- the capability
      matrix's `deposit_attestation_version` is not
      `"xochi-deposit-attestation:v3"` (absent counts as unsupported).
    * `:missing_deposit_deadline` / `{:deposit_deadline_passed, detail}` -- the
      attested deadline must be in the future of `opts[:clock]`.
    * `{:invalid_quote_amount, %{field: field, value: value}}` -- `to_amount` or
      `min_to_amount` absent, or not a non-negative decimal integer (an
      integral JSON float of at most 2^53 counts as its integer).
    * `{:inconsistent_quote_amounts, detail}` -- `min_to_amount > to_amount`.
    * `{:invalid_quote_id, %{field: field, value: value}}` -- an empty intent
      or quote id.
    * `:recipient_is_destination_token` -- funds paid to the token contract are
      unspendable (raxol#869), and no signature can catch it.

  Signer resolution, in precedence order: `opts[:deposit_attestation_signer]`
  (an operator's out-of-band pin), else `config :raxol_payments,
  :xochi_deposit_attestation_signer`, else the live capability matrix's
  `deposit_attestation_signer`; `nil` and `""` count as unset. A pin must be a
  `0x` + 40-hex address (`{:error, :invalid_deposit_signer_pin}` otherwise).
  The matrix is served by the quote endpoint itself, so unless `config
  :raxol_payments, :require_deposit_signer_pin` is exactly `false` (unset, it
  follows `Raxol.Payments.Deployment.production?/0`) it is not consulted and
  an unpinned run fails with `{:error, :deposit_signer_unpinned}`. The matrix
  is always read for `deposit_attestation_version`; a version is not a trust
  anchor, only a way to name a field-set skew.

  ## Options

    * `:deposit_attestation_signer` -- pin the expected signer explicitly.
    * `:capabilities` -- a pre-fetched `Capabilities.t()` (skips the network).
    * `:clock` -- zero-arity function returning unix seconds (default
      `System.system_time(:second)`), for the deadline check.
  """
  @spec deposit_route_quote(Client.config(), DepositRouteRequest.t(), keyword()) ::
          {:ok, map()} | {:error, term()}
  def deposit_route_quote(config, %DepositRouteRequest{} = request, opts \\ []) do
    with {:ok, quote} <- Client.get_deposit_route_quote(config, request),
         :ok <- ensure_solvable(quote) do
      verify_deposit_route(config, request, quote, opts)
    end
  end

  @doc """
  Verify a deposit-route quote's v3 attestation against the pinned signer and
  the caller's own request, and return the deposit instructions, or a
  fail-closed error. See `deposit_route_quote/3` for the checks, signer
  resolution and options.
  """
  @spec verify_deposit_route(
          Client.config(),
          DepositRouteRequest.t(),
          QuoteResponse.t(),
          keyword()
        ) :: {:ok, map()} | {:error, term()}
  def verify_deposit_route(
        config,
        %DepositRouteRequest{} = request,
        %QuoteResponse{} = quote,
        opts \\ []
      ) do
    # Validated here as well as in the client: this is public, and the request
    # is half the signed message, so an unvalidated one could bind a value
    # (e.g. a `0x`-prefixed non-hex recipient) whose case v3 cannot pin.
    with :ok <- DepositRouteRequest.validate(request),
         :ok <- ensure_deposit_route(quote),
         caps = deposit_capabilities(config, opts),
         version = Capabilities.deposit_attestation_version(caps),
         {:ok, signer} <- resolve_deposit_signer(caps, opts),
         # Also checked inside verify/3; here first, so a v1 venue is named as
         # such before a field-level refusal can mask it.
         :ok <- DepositAttestation.check_version(version),
         {:ok, fields} <- deposit_binding_fields(request, quote),
         :ok <- refuse_token_recipient(fields),
         :ok <-
           DepositAttestation.verify(fields, quote.deposit_attestation, %{
             signer: signer,
             version: version,
             now: deposit_now(opts)
           }) do
      {:ok, deposit_instructions(fields)}
    end
  end

  defp ensure_solvable(%QuoteResponse{can_solve: true}), do: :ok

  defp ensure_solvable(%QuoteResponse{error: reason}),
    do: {:error, {:not_solvable, reason}}

  defp ensure_deposit_route(%QuoteResponse{} = quote) do
    if QuoteResponse.deposit_route?(quote),
      do: :ok,
      else: {:error, :not_a_deposit_route}
  end

  # A bare deposit address with nothing to authenticate it against is never
  # trusted; see `DepositSignerPin` for when the matrix signer may stand in.
  defp resolve_deposit_signer(caps, opts) do
    DepositSignerPin.resolve(opts, fn -> Capabilities.deposit_attestation_signer(caps) end)
  end

  defp deposit_capabilities(config, opts) do
    case Keyword.get(opts, :capabilities) do
      %{} = caps -> caps
      _ -> Capabilities.get(config)
    end
  end

  defp deposit_now(opts) do
    case Keyword.get(opts, :clock) do
      clock when is_function(clock, 0) -> clock.()
      _ -> System.system_time(:second)
    end
  end

  # The attested deal. The caller-supplied half comes from OUR request, never
  # from the response: rebuilding it is what binds the attestation to this
  # caller, so a quote signed for another wallet, recipient, chain, token,
  # amount, refund address or settlement type does not recover. The response
  # echoes none of it anyway. Only server-chosen values come from the quote.
  defp deposit_binding_fields(%DepositRouteRequest{} = request, %QuoteResponse{} = quote) do
    with {:ok, intent_id} <- quote_id_field(:intent_id, quote.intent_id),
         {:ok, quote_id} <- quote_id_field(:quote_id, quote.quote_id),
         {:ok, to_amount} <- quote_amount(:to_amount, quote.to_amount),
         {:ok, min_to_amount} <- quote_amount(:min_to_amount, quote.min_to_amount),
         :ok <- amounts_consistent(to_amount, min_to_amount) do
      {:ok,
       %{
         intent_id: intent_id,
         quote_id: quote_id,
         wallet: request.wallet,
         from_chain_id: request.from_chain_id,
         from_token: request.from_token,
         from_amount: request.from_amount,
         deposit_address: quote.deposit_address,
         deposit_deadline: quote.deposit_deadline,
         refund_address: request.refund_address,
         to_chain_id: request.to_chain_id,
         to_token: request.to_token,
         to_amount: to_amount,
         min_to_amount: min_to_amount,
         # Riddler signs the resolved recipient (requested, else the wallet);
         # `DepositRouteRequest.validate/1` requires one, so it is the request's.
         recipient: request.recipient_address,
         stealth_spending_pub_key: request.stealth_spending_pub_key,
         stealth_viewing_pub_key: request.stealth_viewing_pub_key,
         settlement_preference: request.settlement_preference
       }}
    end
  end

  defp quote_id_field(_field, id) when is_binary(id) and id != "", do: {:ok, id}
  defp quote_id_field(field, id), do: {:error, {:invalid_quote_id, %{field: field, value: id}}}

  # The message signs decimal base units. A digit string is used byte for byte
  # (Riddler signs the string it serves); a JSON integer is that integer, and a
  # JSON float only when it is integral and at most 2^53, where the float is
  # exactly the integer written. Anything else -- absent, fractional, signed,
  # grouped -- is refused rather than reformatted into an amount the quote
  # never stated.
  @max_exact_float Integer.pow(2, 53)

  defp quote_amount(field, n) when is_integer(n) and n >= 0,
    do: quote_amount(field, Integer.to_string(n))

  defp quote_amount(field, n) when is_float(n) do
    int = trunc(n)

    if int == n and int >= 0 and int <= @max_exact_float,
      do: {:ok, Integer.to_string(int)},
      else: {:error, {:invalid_quote_amount, %{field: field, value: n}}}
  end

  # A uint256 has at most 78 decimal digits. Longer is refused before any parse:
  # the quote endpoint is the party being verified, and a multi-million-digit
  # string would stall `String.to_integer/1` (or raise `SystemLimitError`).
  @max_amount_digits 78

  defp quote_amount(field, amount) when is_binary(amount) do
    if amount != "" and byte_size(amount) <= @max_amount_digits and
         String.match?(amount, ~r/\A[0-9]+\z/),
       do: {:ok, amount},
       else: {:error, {:invalid_quote_amount, %{field: field, value: amount}}}
  end

  defp quote_amount(field, other),
    do: {:error, {:invalid_quote_amount, %{field: field, value: other}}}

  defp amounts_consistent(to_amount, min_to_amount) do
    if String.to_integer(min_to_amount) <= String.to_integer(to_amount),
      do: :ok,
      else:
        {:error,
         {:inconsistent_quote_amounts, %{to_amount: to_amount, min_to_amount: min_to_amount}}}
  end

  # The venue really would deliver to the token contract, so the signature
  # verifies; the funds are still unspendable there (raxol#869).
  # Case-folded on both sides: on today's EVM destinations that is the address
  # rule, and for a case-sensitive encoding it can only over-refuse.
  defp refuse_token_recipient(%{recipient: recipient, to_token: to_token}) do
    if String.downcase(recipient) == String.downcase(to_token),
      do: {:error, :recipient_is_destination_token},
      else: :ok
  end

  # Every value returned is an attested one.
  defp deposit_instructions(fields) do
    %{
      intent_id: fields.intent_id,
      quote_id: fields.quote_id,
      deposit_address: fields.deposit_address,
      deposit_deadline: fields.deposit_deadline,
      from_chain_id: fields.from_chain_id,
      from_token: fields.from_token,
      from_amount: fields.from_amount,
      to_chain_id: fields.to_chain_id,
      to_token: fields.to_token,
      recipient_address: fields.recipient,
      refund_address: fields.refund_address,
      settlement_preference: fields.settlement_preference,
      to_amount: fields.to_amount,
      min_to_amount: fields.min_to_amount
    }
  end

  @doc """
  Sign and execute an intent from a quote.

  Binds the served EIP-712 intent (`validate_intent/2`) and any origin-pull
  authorization (`validate_pull/3`) to the caller's intended transfer
  (`request`) before signing either, then submits the signed intent.

  The agent signs typed data the quote endpoint serves; a hostile or
  compromised endpoint could otherwise serve an intent that pays a different
  recipient, token, or chain, or a pull that drains the wallet. Nothing is
  signed unless both match the request.
  """
  @spec execute(Client.config(), QuoteResponse.t(), module(), QuoteRequest.t()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute(config, %QuoteResponse{} = quote_resp, wallet, %QuoteRequest{} = request) do
    with {:ok, bundle} <- sign_intent(quote_resp, wallet, request) do
      execute_signed(config, bundle)
    end
  end

  @doc """
  Sign a quoted intent into a relayable bundle WITHOUT executing it.

  The buyer-side counterpart to `execute_signed/2`: validates the quote, binds
  the served intent and origin pull to `request` (see `execute/4`), signs the
  EIP-712 intent with `wallet`, and returns the opaque bundle
  `%{intent_id, quote_id, signature, nonce}` (plus `pull_signature` when the
  quote carried an origin-pull authorization) to hand to a storefront/relay or
  to `execute_signed/2` directly. Does not talk to the worker.
  """
  @spec sign_intent(QuoteResponse.t(), module(), QuoteRequest.t()) ::
          {:ok, signed_intent()} | {:error, term()}
  def sign_intent(%QuoteResponse{} = quote_resp, wallet, %QuoteRequest{} = request) do
    with :ok <- validate_quote(quote_resp),
         :ok <- IntentValidation.validate(quote_resp, request),
         :ok <- PullAuthorization.validate(quote_resp, request, wallet),
         {:ok, signature} <- IntentValidation.sign(quote_resp, wallet),
         {:ok, pull_signature} <- PullAuthorization.sign(quote_resp, wallet) do
      {:ok, SignedRequest.build(quote_resp, signature, pull_signature)}
    end
  end

  defp validate_quote(%QuoteResponse{can_solve: false, error: err}),
    do: {:error, {:cannot_solve, err || "no solver available"}}

  defp validate_quote(%QuoteResponse{can_solve: true}), do: :ok

  @doc """
  Buyer-side one-shot: `get_quote/2` then `sign_intent/3`.

  Fetches a quote for `request` and signs it into a relayable bundle. The buyer
  hands the bundle to a storefront (e.g. as an ACP requirement's `signed_intent`)
  which relays it via `execute_signed/2`; the storefront never re-signs.
  """
  @spec quote_and_sign(Client.config(), QuoteRequest.t(), module()) ::
          {:ok, signed_intent()} | {:error, term()}
  def quote_and_sign(config, %QuoteRequest{} = request, wallet) do
    with {:ok, quote_resp} <- get_quote(config, request) do
      sign_intent(quote_resp, wallet, request)
    end
  end

  @typedoc """
  A buyer's pre-signed Xochi intent bundle, as handed to the storefront relay.

  Keys may be atoms (internal callers) or strings (decoded from an ACP
  requirement). Required: `intent_id`, `quote_id`, `signature`, `nonce`.
  Generated bundles also carry the EIP-712 intent's signed `deadline`, which is
  optional on input. Optional: `pull_signature` (nil for non-pulling methods)
  and `aztec_proof` (shielded claims).
  """
  @type signed_intent :: %{optional(atom() | String.t()) => term()}

  @doc """
  Relay a buyer's pre-signed intent to Xochi WITHOUT re-signing.

  The storefront (pure-relay) primitive. The buyer quoted and signed the EIP-712
  intent (and any origin-pull authorization) against Xochi itself, then handed
  raxol the opaque bundle `{intent_id, quote_id, signature, nonce,
  pull_signature}`. raxol posts it verbatim; Riddler verifies the signature
  against its own server-persisted quote, so neither raxol nor the buyer can
  forge the amount or route.

  Unlike `execute/4`, this takes no wallet and releases no signature -- raxol
  is never on the fund-signing path. Fails closed with
  `{:error, {:invalid_signed_intent, field}}` on a missing or malformed field,
  before any network call.
  """
  @spec execute_signed(Client.config(), signed_intent()) ::
          {:ok, Raxol.Payments.Xochi.Schemas.ExecuteResponse.t()}
          | {:error, term()}
  def execute_signed(config, signed_intent) when is_map(signed_intent) do
    with {:ok, exec_request} <- prepare_signed_execute(signed_intent) do
      execute_prepared(config, exec_request)
    end
  end

  @doc false
  @spec prepare_signed_execute(signed_intent()) :: {:ok, ExecuteRequest.t()} | {:error, term()}
  def prepare_signed_execute(signed_intent) when is_map(signed_intent),
    do: SignedRequest.to_execute_request(signed_intent)

  @doc false
  @spec execute_prepared(Client.config(), ExecuteRequest.t()) ::
          {:ok, ExecuteResponse.t()} | {:error, term()}
  def execute_prepared(config, %ExecuteRequest{} = request), do: Client.execute(config, request)

  @doc """
  Preserve the signed intent id on an execute response that omitted it.

  Ambiguous post-submit outcomes already arrive as a reconciling successful
  response from `Client.execute/2`; clean rejections remain errors.
  """
  @spec as_dispatched({:ok, ExecuteResponse.t()} | {:error, term()}, String.t() | nil) ::
          {:ok, ExecuteResponse.t()} | {:error, term()}
  def as_dispatched({:ok, %ExecuteResponse{} = exec}, intent_id),
    do: {:ok, %{exec | intent_id: exec.intent_id || intent_id}}

  def as_dispatched(result, _intent_id), do: result

  @doc """
  Poll intent status until terminal (completed/failed/expired) or timeout.

  Fast-polls inside the settlement budget window, then backs off. See
  `Raxol.Payments.Poll` for the timing options (`:budget_ms`,
  `:fast_interval_ms`, `:slow_interval_ms`, `:timeout_ms`). `:read_token` (the
  execute response's `read_token`) is sent on every poll so a stealth/shielded
  intent's tx hashes come back; without it the worker withholds them
  (`Client.get_status/3`).
  """
  @spec poll_status(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def poll_status(config, intent_id, opts \\ []) do
    case poll_status_timed(config, intent_id, opts) do
      {:ok, status, _elapsed_ms} -> {:ok, status}
      {:error, reason} -> {:error, reason}
    end
  end

  @doc """
  Like `poll_status/3` but also returns the elapsed milliseconds to the terminal
  status, so the caller can report whether settlement landed within budget.
  """
  @spec poll_status_timed(Client.config(), String.t(), keyword()) ::
          {:ok, IntentStatus.t(), non_neg_integer()} | {:error, term()}
  def poll_status_timed(config, intent_id, opts \\ []) do
    {read_token, poll_opts} = Keyword.pop(opts, :read_token)

    Poll.run(
      fn -> Client.get_status(config, intent_id, read_token: read_token) end,
      &IntentStatus.terminal?/1,
      poll_opts
    )
  end

  @doc """
  Full transfer flow: quote -> sign -> execute -> poll.

  Convenience function that runs the complete Xochi intent lifecycle.
  Returns the final terminal status.
  """
  @spec transfer(Client.config(), QuoteRequest.t(), module(), keyword()) ::
          {:ok, IntentStatus.t()} | {:error, term()}
  def transfer(config, %QuoteRequest{} = request, wallet, opts \\ []) do
    started = System.monotonic_time(:millisecond)

    with {:ok, quote_resp} <- get_quote(config, request),
         {:ok, exec_resp} <-
           as_dispatched(execute(config, quote_resp, wallet, request), quote_resp.intent_id),
         {:ok, status} <-
           poll_status(
             config,
             exec_resp.intent_id,
             Keyword.put(opts, :read_token, exec_resp.read_token)
           ) do
      emit_settled(
        request,
        quote_resp,
        status,
        System.monotonic_time(:millisecond) - started
      )

      {:ok, status}
    end
  end

  # Emit a settlement-completion event carrying the quote fee + delivered amount +
  # destination tx, so accounting can book the fill's P&L without threading a ledger
  # through the protocol. Only on a completed terminal status. See
  # `Raxol.Payments.Telemetry` and `Raxol.Payments.SettlementAccountant`.
  defp emit_settled(
         request,
         quote_resp,
         %IntentStatus{status: :completed} = status,
         elapsed_ms
       ) do
    :telemetry.execute(
      [:raxol, :payments, :xochi, :settled],
      %{elapsed_ms: elapsed_ms},
      %{
        intent_id: status.intent_id,
        from_chain_id: request.from_chain_id,
        to_chain_id: request.to_chain_id,
        from_token: request.from_token,
        to_token: request.to_token,
        from_amount: IntentValidation.from_amount(quote_resp),
        to_amount: quote_resp.to_amount,
        xochi_fee: quote_resp.xochi_fee,
        tx_hash: status.tx_hash,
        settlement_type: status.settlement_type
      }
    )
  end

  defp emit_settled(_request, _quote_resp, _status, _elapsed_ms), do: :ok

  @doc """
  Bind the served EIP-712 intent to the caller's request WITHOUT signing -- the
  check `sign_intent/3` runs before it signs.

  The intent is what Riddler settles, so its signed values -- not the quote's
  top-level fields -- are compared: `wallet`, `fromChainId`/`toChainId`,
  `fromToken`/`toToken`, `recipient` (the request's `recipient_address`, else
  `wallet`, as Riddler defaults it), `settlementPreference`, a `deadline` no
  more than an hour ahead of the wall clock, and the signed `toAmount` against
  the quote's own `to_amount`. On `exact_input` the signed `fromAmount` must
  equal the request's `from_amount`; on `exact_output` the signed `toAmount`
  must equal `output_amount` and `fromAmount` must not exceed `max_from_amount`,
  which is required. The payload must be exactly the canonical `XochiIntent`
  (`intent_kind/0`) under the `Xochi` v3 domain for the origin chain.

  Returns `:ok` or `{:error, {:intent_mismatch, field}}` naming the first field
  that does not match.
  """
  @spec validate_intent(QuoteResponse.t(), QuoteRequest.t()) :: :ok | {:error, term()}
  defdelegate validate_intent(quote_resp, request), to: IntentValidation, as: :validate

  @doc """
  The `XochiIntent` canonical types the agent signs: `%{primary, types,
  type_hash}`.
  """
  @spec intent_kind() :: TypedData.kind()
  defdelegate intent_kind, to: IntentValidation, as: :kind

  @doc """
  The origin amount the served intent signs (`fromAmount`), as a string, or nil
  when the quote carries none. After `validate_intent/2` it equals the request's
  `from_amount` on `exact_input` and is the solver-chosen amount, at most
  `max_from_amount`, on `exact_output`.
  """
  @spec intent_from_amount(QuoteResponse.t()) :: String.t() | nil
  defdelegate intent_from_amount(quote_resp), to: IntentValidation, as: :from_amount

  @doc """
  Validate the served origin-pull authorization against the intended transfer
  WITHOUT signing or executing -- the read-only counterpart of the check
  `execute/4` runs before it signs.

  Returns `:ok` when the quote's `pull_authorization` binds to `request` (signer,
  token, chain, value, envelope type, expiry) and its `to`/`spender` satisfies the
  configured solver pin, or `{:error, {:authorization_mismatch, field}}` otherwise.
  A quote with no pull authorization is `:ok` -- there is nothing to pull. Lets a
  preflight reject a forged or rotated-solver quote before any funded run.
  """
  @spec validate_pull(QuoteResponse.t(), QuoteRequest.t(), module()) :: :ok | {:error, term()}
  def validate_pull(%QuoteResponse{} = quote_resp, %QuoteRequest{} = request, wallet),
    do: PullAuthorization.validate(quote_resp, request, wallet)

  @doc """
  True when the origin-pull solver pin would let an unverified recipient through:
  an empty allowlist with the pin not required. In that state `validate_pull`
  accepts any ERC-3009 `to` (Permit2 stays fail-closed regardless).
  """
  @spec origin_pull_fail_open?([String.t()] | nil, boolean()) :: boolean()
  defdelegate origin_pull_fail_open?(allowlist, require_pin?), to: SolverPin, as: :fail_open?

  @doc """
  Raise when the origin-pull solver pin is fail-open for the given allowlist and
  requirement flag, otherwise return `:ok`. Call at boot in a fund-moving
  deployment so a missing solver pin halts startup.
  """
  @spec assert_origin_pull_pinned!([String.t()] | nil, boolean()) :: :ok
  defdelegate assert_origin_pull_pinned!(allowlist, require_pin?),
    to: SolverPin,
    as: :assert_pinned!

  @doc """
  Raise when `pin` is set but is not a `0x` + 40-hex address, or when deposit
  routes would trust the capability matrix's attestation signer (fail-open: no
  valid `pin` and `require_pin?` is `false`). A required pin that is unset is not
  fail-open: the boot goes ahead and every deposit route is refused with
  `{:error, :deposit_signer_unpinned}`. `assert_deposit_signer_pinned!/0`
  reads both from config.
  """
  @spec assert_deposit_signer_pinned!(String.t() | nil, boolean()) :: :ok
  defdelegate assert_deposit_signer_pinned!(pin, require_pin?),
    to: DepositSignerPin,
    as: :assert_pinned!

  @doc """
  `assert_deposit_signer_pinned!/2` over the configured
  `:xochi_deposit_attestation_signer` and `:require_deposit_signer_pin` (unset,
  `Raxol.Payments.Deployment.production?/0`). Call it from the start-up of a
  release that serves deposit routes.
  """
  @spec assert_deposit_signer_pinned!() :: :ok
  defdelegate assert_deposit_signer_pinned!, to: DepositSignerPin, as: :assert_pinned!

  @doc """
  Reads the origin-pull solver pin from the environment, for the
  `config/runtime.exs` of a release that signs origin pulls:

      config :raxol_payments,
             Raxol.Payments.Protocols.Xochi.origin_pull_pin_env_config!()

  `XOCHI_SOLVER_ETH`, `XOCHI_SOLVER_BASE`, `XOCHI_SOLVER_ARBITRUM`,
  `XOCHI_SOLVER_OPTIMISM`, `XOCHI_SOLVER_POLYGON` and `XOCHI_SOLVER_ROBINHOOD`
  name the solver collection address the agent signs pulls to; the allowlist is
  flat. `XOCHI_PULL_REQUIRE_SOLVER_PIN` (`true` or `false`; unset, it follows
  `Raxol.Payments.Deployment.production?/0`) becomes `:pull_require_solver_pin`
  and decides only whether a boot with no `XOCHI_SOLVER_*` set goes ahead
  (`true`) or raises as `assert_origin_pull_pinned!/2` does (`false`).

  The returned `:pull_solver_allowlist` is the configured addresses plus
  `Raxol.Payments.Xochi.PullContracts.pull_recipients/0`, since the origin pull
  routes to the verified per-chain pull contracts.
  """
  @spec origin_pull_pin_env_config!() :: [
          pull_solver_allowlist: [String.t()],
          pull_require_solver_pin: boolean()
        ]
  defdelegate origin_pull_pin_env_config!, to: SolverPin, as: :env_config!

  @doc """
  Check a served Permit2 `PermitWitnessTransferFrom` + `OriginPullWitness`
  authorization before signing it: exactly the canonical types, message
  fields and domain (`name` "Permit2", `chainId` = `chain_id`,
  `verifyingContract` = `Permit2.verifying_contract/0`), `permitted.token` =
  `token`, `permitted.amount` at most `ceiling`, a `spender` the solver pin
  allows (the pin is always required for Permit2) and a bounded `deadline`.

  Returns `:ok` or `{:error, {:authorization_mismatch, field}}`. Used for the
  Xochi origin pull and for the Relay gasless pull, which serve the same
  envelope.
  """
  @spec validate_permit2_authorization(term(), String.t(), pos_integer(), term()) ::
          :ok | {:error, {:authorization_mismatch, term()}}
  defdelegate validate_permit2_authorization(pull, token, chain_id, ceiling),
    to: PullAuthorization,
    as: :validate_permit2

  @doc """
  The canonical Permit2 pull kind (`%{primary, types, type_hash}`) the agent
  signs.
  """
  @spec permit2_kind() :: TypedData.kind()
  defdelegate permit2_kind, to: PullAuthorization

  @doc """
  Project a served EIP-712 payload's `"domain"` onto the domain map the wallet
  signs, carrying over exactly the keys the worker sent.

  Every field is conditional: `Raxol.Payments.EIP712` derives the EIP712Domain
  field list from the keys present, so a key carrying `nil` still declares that
  field. The XochiIntent domain omits `verifyingContract` and carries a `salt`;
  Permit2's omits `version`. Public so conformance checks exercise this
  projection rather than a copy of it.
  """
  @spec eip712_domain(map()) :: map()
  defdelegate eip712_domain(eip712), to: Served, as: :domain

  @doc """
  The served `types` map, projected into the shape `Raxol.Payments.EIP712`
  encodes, with `EIP712Domain` dropped (the domain is hashed from
  `eip712_domain/1`). Public for the same reason as `eip712_domain/1`;
  `Raxol.Earn.Xochi.PullPreflight` calls it rather than mirroring it.
  """
  @spec eip712_types(map()) :: map()
  defdelegate eip712_types(eip712), to: Served, as: :types
end
