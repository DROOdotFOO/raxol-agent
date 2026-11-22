defmodule Mix.Tasks.RaxolEarn.Order.Budget do
  @moduledoc false
  # Escrow arithmetic and the on-chain reads behind it for
  # `mix raxol_earn.order`: the expected fee, the ceiling --fund may pay, the
  # verdict on a provider-set budget, `getJob` budget reads, and the buyer's
  # USDC transfers in a receipt.

  alias Raxol.Agent.Secret
  alias Raxol.Earn.Onchain.RPC
  alias Raxol.Payments.Assets

  @transfer_topic "0xddf252ad1be2c89b69c2b068fc378daa952ba7f163c4a11628f55a4df523b3ef"

  @spec expected_escrow(map()) :: non_neg_integer()
  def expected_escrow(cfg), do: div(cfg.principal_atomic * cfg.fee_bps, 10_000)

  # The most --fund may pay. Default: the take-rate asserted with --fee-bps, so
  # a provider that writes a bigger budget cannot be paid without the operator
  # naming the number.
  @spec escrow_ceiling(map(), keyword()) :: non_neg_integer()
  def escrow_ceiling(cfg, opts) do
    case Keyword.get(opts, :max_escrow) do
      nil -> expected_escrow(cfg)
      human -> parse_max_escrow(human, Assets.decimals(cfg.from, cfg.src_token))
    end
  end

  @spec budget_verdict(map(), non_neg_integer(), non_neg_integer()) ::
          {:ok, String.t()} | {:error, String.t()}
  def budget_verdict(cfg, budget, ceiling) do
    expected = expected_escrow(cfg)

    cond do
      budget == expected ->
        {:ok, "OK: budget == #{cfg.fee_bps} bps of the principal"}

      budget <= ceiling ->
        {:ok,
         "budget #{budget} != expected #{expected} (#{cfg.fee_bps} bps), " <>
           "within the ceiling #{ceiling}"}

      true ->
        {:error,
         "provider set budget #{budget} base units, above the #{ceiling} ceiling -- " <>
           "refusing to fund. The budget is what --fund approves and escrows, so a " <>
           "provider that sets its own number is simply paid it. Either the offering's " <>
           "fee changed, in which case re-run with a matching --fee-bps, or this " <>
           "provider is not charging what it advertises. The ceiling is #{cfg.fee_bps} " <>
           "bps of --amount #{cfg.amount}; on --job-id it does not describe the resumed " <>
           "job at all. Accept this budget with --max-escrow <USDC>."}
    end
  end

  # --amount and --fee-bps describe a job this run creates. A resumed job's
  # budget was set by whoever created it, so it is read rather than derived.
  @spec resume_escrow(map(), keyword()) :: :new_job | :unreadable | {:ok, non_neg_integer()}
  def resume_escrow(cfg, opts) do
    with job_id when not is_nil(job_id) <- Keyword.get(opts, :job_id),
         {:ok, budget} <- read_budget(cfg, job_id) do
      {:ok, budget}
    else
      nil -> :new_job
      :not_ready -> :unreadable
    end
  end

  # getJob(uint256) returns a dynamic struct: a leading offset word, then the
  # head (client, status, provider, expiredAt, evaluator, hook, budget, ...), so
  # budget is word 7.
  @spec read_budget(map(), non_neg_integer()) :: {:ok, non_neg_integer()} | :not_ready
  def read_budget(cfg, job_id) do
    selector = binary_part(ExKeccak.hash_256("getJob(uint256)"), 0, 4)

    data =
      "0x" <> Base.encode16(selector <> <<job_id::unsigned-big-integer-size(256)>>, case: :lower)

    body = %{
      jsonrpc: "2.0",
      id: 1,
      method: "eth_call",
      params: [%{to: cfg.core, data: data}, "latest"]
    }

    case Req.post(reveal(cfg.acp_rpc), json: body) do
      {:ok, %{status: 200, body: %{"result" => "0x" <> hex}}} when byte_size(hex) >= 8 * 64 ->
        <<_lead::binary-size(7 * 32), budget::unsigned-big-integer-size(256), _rest::binary>> =
          Base.decode16!(hex, case: :mixed)

        {:ok, budget}

      _ ->
        :not_ready
    end
  end

  # Only USDC transfers OUT of the buyer count as spend; anything else in the
  # receipt is someone else's money.
  @spec buyer_transfers(Req.Request.t(), map(), String.t()) ::
          {:ok, [{String.t(), non_neg_integer()}]} | {:error, term()}
  def buyer_transfers(client, cfg, tx_hash) do
    case RPC.await_receipt(client, tx_hash, timeout_ms: 20_000) do
      {:ok, %{"logs" => logs}} when is_list(logs) ->
        buyer_topic = pad_topic(cfg.buyer)
        token = String.downcase(cfg.src_token)

        {:ok,
         for %{"address" => addr, "topics" => [topic0, from, to | _], "data" => data} <- logs,
             String.downcase(addr) == token,
             String.downcase(topic0) == @transfer_topic,
             String.downcase(from) == buyer_topic do
           {"0x" <> String.slice(to, -40, 40), parse_uint(data)}
         end}

      {:ok, other} ->
        {:error, {:receipt_without_logs, other}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec rpc_client(map()) :: Req.Request.t()
  def rpc_client(cfg), do: RPC.client(url: reveal(cfg.rpc))

  defp parse_max_escrow(human, decimals) do
    case Decimal.parse(human) do
      {value, ""} ->
        Assets.to_atomic(value, decimals)

      _ ->
        Mix.raise("--max-escrow #{inspect(human)} is not a USDC amount (e.g. --max-escrow 0.05)")
    end
  end

  # Raw or wrapped: `Secret.new/1` is idempotent, and tests pass hand-built cfgs.
  defp reveal(value), do: value |> Secret.new() |> Secret.reveal()

  defp pad_topic("0x" <> addr), do: String.downcase("0x" <> String.duplicate("0", 24) <> addr)

  defp parse_uint("0x" <> hex), do: String.to_integer(hex, 16)
  defp parse_uint(_), do: 0
end
