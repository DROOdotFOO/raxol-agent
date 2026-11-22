defmodule Raxol.Earn.TestSupport.SolverAgentFixtures do
  @moduledoc false
  # Shared setup for the `Raxol.Earn.Xochi.SolverAgent` suites: a real
  # `Raxol.Earn.Agent` over the in-memory transport, job API and provider.

  alias Raxol.Earn.{Agent, JobApi, JobSession, ProviderAdapter, Transport}
  alias Raxol.Earn.Xochi.SolverAgent

  @solver_wallet "0xfeedfacefeedfacefeedfacefeedfacefeedface"
  @evaluator "0x" <> String.duplicate("ed", 20)
  @acp_core "0x238E541BfefD82238730D00a2208E5497F1832E0"

  # Real Base USDC (6dp), from Raxol.Payments.Assets.
  @base_usdc "0x833589fcd6edb6e08f4c7c32d4f71b54bda02913"

  @spec solver_wallet() :: String.t()
  def solver_wallet, do: @solver_wallet

  @spec acp_core() :: String.t()
  def acp_core, do: @acp_core

  @spec solver_context() :: keyword()
  def solver_context do
    for {_, pid, _, _} <- DynamicSupervisor.which_children(JobSession.Supervisor),
        is_pid(pid) do
      DynamicSupervisor.terminate_child(JobSession.Supervisor, pid)
    end

    transport = Transport.Mock.new()
    job_api = JobApi.Mock.new(me: %{wallet_address: @solver_wallet, name: "Xochi"})

    provider =
      ProviderAdapter.Mock.new(address: @solver_wallet, supported_chain_ids: [8453])

    {:ok, agent} =
      Agent.start_link(
        transport: transport,
        api: job_api,
        wallet_address: @solver_wallet,
        supported_chain_ids: [8453],
        default_role: :provider
      )

    [transport: transport, api: job_api, provider: provider, agent: agent]
  end

  @spec start_solver(keyword(), map()) :: GenServer.on_start()
  def start_solver(opts, ctx) do
    SolverAgent.start_link(
      Keyword.merge(
        [
          agent: ctx.agent,
          provider: ctx.provider,
          wallet_address: @solver_wallet,
          evaluator_address: @evaluator,
          chain_id: 8453,
          acp_core_address: @acp_core,
          xochi_config: xochi_stub()
        ],
        opts
      )
    )
  end

  # In-process Xochi: GET /api/intent/:id returns an intent carrying the
  # authoritative `from_amount` the budget is sized on. `from_token` defaults to
  # real Base USDC, since the fee is derived 1:1 from the origin amount.
  @spec xochi_stub(String.t(), String.t(), keyword()) :: map()
  def xochi_stub(from_amount \\ "1000000", status \\ "quoted", opts \\ []) do
    plug = fn conn ->
      body = %{
        "id" => "xi_1",
        "status" => status,
        "from_chain_id" => 8453,
        "to_chain_id" => 10,
        "from_token" => Keyword.get(opts, :from_token, @base_usdc),
        "to_token" => "0x" <> String.duplicate("22", 20),
        "from_amount" => from_amount,
        "to_amount" => from_amount,
        "quote_id" => "xq_1"
      }

      conn
      |> Plug.Conn.put_resp_content_type("application/json")
      |> Plug.Conn.send_resp(200, Jason.encode!(body))
    end

    %{base_url: "https://api.xochi.fi", req_options: [plug: plug, retry: false]}
  end

  @spec requirement(keyword()) :: map()
  def requirement(overrides \\ []) do
    Map.merge(
      %{
        "src_chain_id" => 8453,
        "dst_chain_id" => 10,
        "src_token" => "0x" <> String.duplicate("11", 20),
        "dst_token" => "0x" <> String.duplicate("22", 20),
        "amount_atomic" => "1000000",
        "signed_intent" => %{
          "intent_id" => "xi_1",
          "quote_id" => "xq_1",
          "signature" => "0x" <> String.duplicate("11", 65),
          "nonce" => 7,
          "pull_signature" => "0x" <> String.duplicate("22", 65)
        }
      },
      Map.new(overrides)
    )
  end

  @spec job_created_entry(keyword()) :: map()
  def job_created_entry(opts \\ []) do
    %{
      "kind" => "system",
      "event" => "job.created",
      "chainId" => 8453,
      "jobId" => Keyword.get(opts, :job_id, "42"),
      "provider" => Keyword.get(opts, :provider, @solver_wallet)
    }
  end

  @spec requirement_message(keyword()) :: map()
  def requirement_message(opts \\ []) do
    %{
      "kind" => "message",
      "contentType" => "requirement",
      "chainId" => 8453,
      "jobId" => Keyword.get(opts, :job_id, "42"),
      "content" => Jason.encode!(Keyword.get_lazy(opts, :requirement, &requirement/0))
    }
  end
end
