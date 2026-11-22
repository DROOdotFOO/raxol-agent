defmodule Raxol.Web3.Backend.Solana.Normalize do
  @moduledoc false
  # Internal to `Raxol.Web3.Backend.Solana`.
  #
  # Maps Solana JSON-RPC results onto the `Raxol.Web3.Backend` shapes. See
  # `Raxol.Web3.Backend.Solana` for what each field does and does not claim.

  import Raxol.Web3.Backend.Decode, only: [dig: 2, object: 1]

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Solana.RPC

  @system_program "11111111111111111111111111111111"
  @token_program "TokenkegQfeZyiNwAJbNbGKPFXCWuBvf9Ss623VQ5DA"
  @token_account_space 165
  @mint_space 82

  @doc "The SPL token program id."
  @spec token_program() :: String.t()
  def token_program, do: @token_program

  @doc "A `getAccountInfo` value as an account."
  @spec account_record(String.t(), term()) :: {:ok, Backend.account()} | {:error, Backend.error()}
  def account_record(pubkey, info) when is_map(info) do
    with {:ok, balance} <- Backend.money(info["lamports"], :balance) do
      {:ok,
       %{
         ref: {:solana, pubkey},
         balance: balance,
         contract?: info["executable"] == true,
         verified?: false,
         name: nil,
         ens: nil,
         kind: kind(info)
       }}
    end
  end

  def account_record(_pubkey, _info), do: {:error, {:decode_failed, :account}}

  @doc """
  The envelope's `value` is the list of token accounts. A body carrying
  something else where the list belongs is a decode failure rather than a
  wallet holding nothing: an empty page would answer "no tokens" for a
  response nobody could read, and the router fails over on the first.
  """
  @spec token_accounts(term()) :: {:ok, list()} | {:error, {:decode_failed, :token_accounts}}
  def token_accounts(%{"value" => nil}), do: {:ok, []}

  def token_accounts(%{"value" => accounts}) when is_list(accounts), do: {:ok, accounts}
  def token_accounts(_other), do: {:error, {:decode_failed, :token_accounts}}

  @doc "A `getSignaturesForAddress` result as rows; `nil` is an empty page."
  @spec signature_rows(term()) :: {:ok, list()} | {:error, {:decode_failed, :signatures}}
  def signature_rows(nil), do: {:ok, []}
  def signature_rows(rows) when is_list(rows), do: {:ok, rows}
  def signature_rows(_other), do: {:error, {:decode_failed, :signatures}}

  @doc "A `getTransaction` result."
  @spec transaction(term()) :: {:ok, Backend.transaction()} | {:error, Backend.error()}
  def transaction(body) when is_map(body) do
    meta = body |> Map.get("meta") |> object()
    message = body |> dig(["transaction", "message"]) |> object()

    with {:ok, fee} <- Backend.money(meta["fee"], :fee) do
      {:ok,
       %{
         hash: body |> dig(["transaction", "signatures"]) |> first(),
         status: status(meta["err"]),
         block: body["slot"],
         timestamp: unix(body["blockTime"]),
         from: message |> Map.get("accountKeys") |> first() |> account_ref(),
         to: nil,
         value: nil,
         fee: fee,
         method: nil
       }}
    end
  end

  def transaction(_body), do: {:error, {:decode_failed, :transaction}}

  @doc "A signature-listing row as a thin transaction."
  @spec signature_row(term()) :: {:ok, Backend.transaction()} | {:error, Backend.error()}
  def signature_row(item) when is_map(item) do
    {:ok,
     %{
       hash: item["signature"],
       status: status(item["err"]),
       block: item["slot"],
       timestamp: unix(item["blockTime"]),
       from: nil,
       to: nil,
       value: nil,
       fee: nil,
       method: nil
     }}
  end

  def signature_row(_item), do: {:error, {:decode_failed, :signature_row}}

  @doc "A parsed token account as a balance."
  @spec token_balance(term()) :: {:ok, Backend.token_balance()} | {:error, Backend.error()}
  def token_balance(item) when is_map(item) do
    info = item |> dig(["account", "data", "parsed", "info"]) |> object()
    amount = info |> Map.get("tokenAmount") |> object()

    with {:ok, parsed} <- Backend.money(amount["amount"], :amount) do
      {:ok,
       %{
         token: %{
           address: info["mint"],
           # A validator serves no token registry, so a symbol and a name are
           # absent rather than guessed from a mint address.
           symbol: nil,
           name: nil,
           decimals: amount["decimals"],
           type: dig(item, ["account", "data", "program"])
         },
         amount: parsed,
         token_id: nil
       }}
    end
  end

  def token_balance(_item), do: {:error, {:decode_failed, :token_balance_row}}

  @doc "A `getBlock` result for `slot`; a skipped slot is a block with `hash: nil`."
  @spec block_result(
          {:ok, term()} | {:rpc_error, integer()} | {:error, term()},
          non_neg_integer()
        ) ::
          {:ok, Backend.block()} | {:error, Backend.error()}
  def block_result({:ok, body}, slot) when is_map(body) do
    {:ok,
     %{
       height: slot,
       hash: body["blockhash"],
       timestamp: unix(body["blockTime"]),
       transactions_count: body |> Map.get("signatures") |> count(),
       miner: nil
     }}
  end

  # A skipped slot is a success with no block in it, and the nil hash is what
  # says so: a produced block always carries a blockhash.
  def block_result({:ok, nil}, slot), do: {:ok, skipped(slot)}

  # A result that is neither a block nor `null` is a body that is not what it
  # claimed, and fails over rather than raising.
  def block_result({:ok, _other}, _slot), do: {:error, {:decode_failed, :block}}

  def block_result({:rpc_error, -32_009}, slot), do: {:ok, skipped(slot)}

  def block_result({:rpc_error, code}, _slot),
    do: {:error, {:upstream_refused, RPC.error_class(code)}}

  def block_result({:error, _reason} = error, _slot), do: error

  defp skipped(slot) do
    %{height: slot, hash: nil, timestamp: nil, transactions_count: nil, miner: nil}
  end

  defp kind(%{"executable" => true}), do: :program
  defp kind(%{"owner" => @system_program}), do: :wallet

  defp kind(%{"owner" => @token_program, "space" => @token_account_space}),
    do: :token_account

  defp kind(%{"owner" => @token_program, "space" => @mint_space}), do: :mint
  defp kind(_info), do: :data

  defp status(nil), do: :success
  defp status(_error), do: :reverted

  defp account_ref(pubkey) when is_binary(pubkey), do: {:solana, pubkey}
  defp account_ref(_absent), do: nil

  defp first([head | _rest]), do: head
  defp first(_other), do: nil

  defp count(list) when is_list(list), do: length(list)
  defp count(_other), do: nil

  # `DateTime.from_unix!/2` raises on a value outside the calendar's range,
  # and `blockTime` is the upstream's integer rather than one of ours.
  defp unix(seconds) when is_integer(seconds) do
    case DateTime.from_unix(seconds) do
      {:ok, datetime} -> datetime
      {:error, _reason} -> nil
    end
  end

  defp unix(_other), do: nil
end
