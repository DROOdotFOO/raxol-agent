defmodule Mix.Tasks.RaxolEarn.Order.Errors do
  @moduledoc false
  # Operator-facing explanations for the ways `mix raxol_earn.order` stops
  # before a write: signing the intent, and starting the Privy signer sidecar.

  alias Raxol.Earn.SignerSidecar
  alias Raxol.Earn.Xochi.OriginPull

  # A transport failure is more often the local network than Xochi: some ISPs
  # null-route the Cloudflare range api.xochi.fi resolves into, so requests die
  # at connect with no HTTP status to explain them.
  @spec sign_intent(term()) :: String.t()
  def sign_intent(%{__struct__: Req.TransportError, reason: reason}) do
    """
    could not reach the Xochi API (transport #{inspect(reason)}).

    This is usually the network path, not Xochi. Check, in order:

      nc -z api.xochi.fi 443          # dropped => blocked upstream, not down
      curl -sI http://api.xochi.fi    # a non-Cloudflare page here => intercepted
      curl -s "https://r.jina.ai/https://xochi.fi"   # answers => the API is fine

    A control host only proves anything if it shares the blocked IP range;
    cloudflare.com and other Cloudflare sites sit elsewhere and will pass while
    this one fails. Route around it with a VPN or an exit node in another
    country. Confirm from off-network before reporting an outage upstream.
    """
  end

  def sign_intent({:origin_pull, reason}), do: OriginPull.explain(reason)

  def sign_intent({:authorization_mismatch, field}) when field in [:pull_to, :pull_spender] do
    """
    the quote's origin-pull recipient is not pinned (#{field}).

    Nothing was signed. The accepted set is the verified XochiPull contracts this
    repo mirrors, plus any --solver / ORDER_SOLVER address. A solver that has
    redeployed its pull contract will fail exactly here: confirm the new address
    against Riddler's XochiPull deployment record, then re-run with

      --solver 0x<spender>

    Do not widen the pin to whatever the quote served -- checking that value is
    the entire point of it.
    """
  end

  # The worker builds the served XochiIntent from our own quote body, so any
  # drift is a bug or an attack upstream.
  def sign_intent({:intent_mismatch, field}) do
    """
    the quote's signed intent does not match this order (#{field}).

    Nothing was signed. The XochiIntent the solver served disagrees with the
    request on #{field} (wallet, recipient, chains, tokens, amounts, settlement
    and deadline are all checked). Re-run to fetch a fresh quote; if it fails
    the same way, report it upstream with the quote id rather than overriding.
    """
  end

  def sign_intent(:pull_signature_rejected) do
    """
    the origin pull's signature will not verify on chain.

    Nothing was written and nothing was escrowed. The preflight line above shows
    which contract was asked and what it answered: the digest it rebuilds is not
    the one this signature covers, so the pull would revert and the job would sit
    funded and unsettleable until it expired.

    That is a defect in what was signed, not a configuration you can retry
    around. The domain the quote serves and the domain the verifier declares have
    diverged. Capture the served pull_authorization and compare its domain to the
    verifying contract's own DOMAIN_SEPARATOR() before re-running.

    --dry-run reproduces this for free, and fails the same way.
    """
  end

  def sign_intent(:pull_preflight_inconclusive) do
    """
    the origin pull's signature could not be checked against the chain.

    Nothing was written and nothing was escrowed. The preflight line above says
    what stopped the check and what to do about it -- read it before changing
    anything.

    This is not a claim that the signature is bad. It is a refusal to escrow a
    fee on a question nobody answered -- and since --corridor's origin is pinned
    to the ACP core's own chain, the endpoint that could not answer is the SAME
    ORDER_RPC_8453 the createJob and fund writes go to, so those are in doubt as
    well.

    Re-run once ORDER_RPC_8453 answers, or with --dry-run to rehearse for free.
    """
  end

  def sign_intent({:pull_signature_missing, got}) do
    """
    the quote served an origin pull, but the signed bundle carries no
    pull_signature (got #{inspect(got)}).

    Nothing was written and nothing was escrowed. The solver will be asked to
    pull funds on the origin chain and will have no authorization to do it with,
    so this would strand a funded job exactly the way a bad signature does.

    This is a defect in the signing path rather than in the quote or the chain:
    Protocols.Xochi.sign_intent/3 attaches :pull_signature whenever the quote
    carries a pull_authorization. Capture the bundle it returned.
    """
  end

  def sign_intent(reason), do: "could not sign the Xochi intent: #{inspect(reason)}"

  # A write refused because the sidecar failed its identity check. What it
  # means depends on what this run already put on chain.
  @spec write_blocked(:create_job | {:fund, non_neg_integer()}, String.t(), term()) ::
          String.t()
  def write_blocked(:create_job, url, reason) do
    """
    createJob was not sent: #{sidecar_problem(url, reason)}

    Nothing from this run is on chain; the signed intent is unused. Fix or stop
    the sidecar (see below), then re-run.

    #{sidecar(reason, url)}
    """
  end

  def write_blocked({:fund, job_id}, url, reason) do
    """
    job #{job_id} is on chain but was NOT funded: #{sidecar_problem(url, reason)}

    Do not re-run from scratch: that creates a second job. Fix or stop the
    sidecar (see below), then fund this one with the same flags plus

      --job-id #{job_id} --fund

    #{sidecar(reason, url)}
    """
  end

  defp sidecar_problem(url, {:sidecar_wrong_wallet, got, _want}),
    do: "the sidecar at #{url} reports wallet #{got}."

  defp sidecar_problem(url, {:sidecar_refused, reason}),
    do: "the sidecar at #{url} refused the request (#{inspect(reason)}, unverified)."

  defp sidecar_problem(url, :sidecar_unauthenticated),
    do: "the process at #{url} could not prove it holds the authorization key."

  defp sidecar_problem(url, _reason), do: "the sidecar at #{url} did not pass its /health check."

  defp refusal_hint("stale"),
    do: "the request's timestamp was more than 30s off the sidecar's clock."

  defp refusal_hint("bad_signature"),
    do:
      "the request signature did not verify -- the sidecar was started with a " <>
        "different RAXOL_ACP_SIGNER_PRIVATE_KEY, or something else holds the port."

  defp refusal_hint("replayed"),
    do: "the sidecar had already served a request with this nonce -- something replayed it."

  defp refusal_hint(reason) when reason in ["missing_auth", "malformed_auth"],
    do:
      "the request carried no valid authentication headers -- this BEAM and the " <>
        "sidecar run different versions."

  defp refusal_hint("body_too_large"), do: "the request body exceeded the sidecar's 1 MB cap."
  defp refusal_hint(reason), do: inspect(reason)

  @spec sidecar(term(), String.t()) :: String.t()
  def sidecar(reason, url \\ SignerSidecar.base_url([]))

  def sidecar({:sidecar_unhealthy, reason}, url), do: sidecar(reason, url)

  def sidecar({:sidecar_wrong_wallet, got, want}, url) do
    """
    #{url} answers /health for the WRONG wallet: #{got}, expected #{want}.

    Something else already holds that port -- most often a signer sidecar left over
    from an earlier run, delegated to a different agent. Left alone it would sign
    this order's intent and its on-chain calls as #{got}, while every log line here
    said #{want}. Find and stop it:

      lsof -i :#{URI.parse(url).port}

    Or point this run elsewhere with RAXOL_ACP_SIGNER_PORT / RAXOL_ACP_SIDECAR_URL.
    """
  end

  def sidecar({:sidecar_refused, reason}, url) do
    """
    the sidecar at #{url} refused this run's request: #{refusal_hint(reason)}

    The refusal is unsigned, so nothing proves it came from the sidecar; the
    request was not served either way.
    """
  end

  def sidecar({:bad_sidecar_url, message}, _url), do: message <> "\n"

  def sidecar(:sidecar_unauthenticated, url) do
    """
    the process answering at #{url} could not prove it is this run's signer.

    Nothing was signed or sent through it. Every sidecar response must carry a
    signature made with a key derived from RAXOL_ACP_SIGNER_PRIVATE_KEY, for this
    run's wallet; this one did not. Another process holds the port, or the sidecar
    there was started with a different authorization key or wallet. Find it with

      lsof -i :#{URI.parse(url).port}
    """
  end

  def sidecar(:health_timeout, url) do
    """
    the Privy signer sidecar at #{url} stopped answering /health.

    Nothing was signed. The sidecar passed its boot check earlier in this run, so
    it has since exited or hung. Check its output above, then re-run; the task
    starts a fresh one.
    """
  end

  def sidecar(reason, url) do
    """
    the Privy signer sidecar did not start: #{inspect(reason)}

    It is a Node process under packages/raxol_earn/priv/signer_sidecar.
    Check, in order:

      node --version                       # must be present on PATH
      ls priv/signer_sidecar/node_modules  # run `npm install` there if absent
      lsof -i :#{URI.parse(url).port}   # the sidecar exits if taken

    RAXOL_ACP_WALLET_ADDRESS / RAXOL_ACP_WALLET_ID / RAXOL_ACP_SIGNER_PRIVATE_KEY
    must all be set: the sidecar reads them at boot and exits if any is missing.
    """
  end
end
