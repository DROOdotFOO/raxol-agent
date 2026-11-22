defmodule Raxol.Web3.Backend.Tron.Sources do
  @moduledoc """
  The three Tron MCP sources, the accepted chain references and what each
  source declares. Data, dated 2026-09-14; the behaviour is in
  `Raxol.Web3.Backend.Tron`.
  """

  @type source :: :trongrid | :sqd | :tronscan

  # The registered CAIP-2 form for Tron mainnet is the genesis-block prefix.
  @chain_ref "tron:0x2b6653dc"

  # Dated 2026-09-14. `tron:mainnet` is the spelling operators and upstreams
  # reach for, so it is accepted on ingest and collapsed here rather than in
  # three source-specific places. Data, so a new alias is a table row.
  @chain_aliases %{
    "tron:mainnet" => @chain_ref,
    @chain_ref => @chain_ref
  }

  # Probed 2026-09-14. `network` is the upstream's own name for this chain and
  # is an argument this module chooses, never a name it forwards.
  @sources %{
    trongrid: %{
      url: "https://mcp.trongrid.io/mcp",
      stateful?: true,
      concurrency: :pooled,
      tools: 149,
      network: nil
    },
    sqd: %{
      url: "https://portal.sqd.dev/mcp",
      stateful?: false,
      concurrency: :stateless,
      tools: 31,
      network: "tron-mainnet"
    },
    tronscan: %{
      url: "https://mcp.tronscan.org/mcp",
      stateful?: true,
      concurrency: :serialized,
      tools: 119,
      network: nil
    }
  }

  @trongrid_capabilities [
    :get_transaction,
    :account_info,
    :list_transactions,
    :token_balances,
    :list_token_transfers,
    :get_block
  ]

  # No `list_transactions/3`: the only account-scoped transaction tools take a
  # single `fromAddress` or `toAddress`, so "the transactions of this address"
  # would be two half-answers stitched together. `getTransferList` answers
  # transfers in both directions and is `list_token_transfers/3`.
  @tronscan_capabilities [
    :get_transaction,
    :account_info,
    :token_balances,
    :list_token_transfers
  ]

  @doc "The canonical CAIP-2 reference for Tron mainnet."
  @spec chain_ref() :: String.t()
  def chain_ref, do: @chain_ref

  @doc "The source table, with its session and concurrency facts."
  @spec all() :: %{source() => map()}
  def all, do: @sources

  @doc "The accepted chain references and what each one canonicalizes to."
  @spec chain_aliases() :: %{String.t() => String.t()}
  def chain_aliases, do: @chain_aliases

  @doc "One source's row, or `{:unsupported_source, source}`."
  @spec fetch(atom()) :: {:ok, map()} | {:error, {:unsupported_source, atom()}}
  def fetch(source) do
    case Map.fetch(@sources, source) do
      {:ok, config} -> {:ok, config}
      :error -> {:error, {:unsupported_source, source}}
    end
  end

  @doc "One known source's row."
  @spec fetch!(source()) :: map()
  def fetch!(source), do: Map.fetch!(@sources, source)

  @doc "The optional callbacks a source declares."
  @spec capabilities(source()) :: [atom()]
  def capabilities(:trongrid), do: @trongrid_capabilities
  def capabilities(:tronscan), do: @tronscan_capabilities
  def capabilities(:sqd), do: []

  @doc "Canonicalize an accepted chain reference."
  @spec canonical_chain_ref(term()) :: {:ok, String.t()} | {:error, {:unsupported_chain, term()}}
  def canonical_chain_ref(chain_ref) when is_binary(chain_ref) do
    case Map.fetch(@chain_aliases, chain_ref) do
      {:ok, canonical} -> {:ok, canonical}
      :error -> {:error, {:unsupported_chain, chain_ref}}
    end
  end

  def canonical_chain_ref(other), do: {:error, {:unsupported_chain, other}}
end
