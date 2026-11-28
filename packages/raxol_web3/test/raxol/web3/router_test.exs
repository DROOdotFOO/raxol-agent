defmodule Raxol.Web3.RouterTest do
  use ExUnit.Case, async: true

  alias Raxol.MCP.CircuitBreaker
  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Blockscout
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.Cursor
  alias Raxol.Web3.Router
  alias Raxol.Web3.Tables

  @chain "eip155:1"
  @account {:evm, "0xd8dA6BF26964aF9D7eEd9e03E53415D37aA96045"}

  # Each test that touches a breaker uses its own key, because one shared table
  # holds them all and an async sibling must not inherit another test's health.
  defp key(name), do: {:origin, "router-test-#{name}-#{System.unique_integer([:positive])}"}

  defp open(key) do
    CircuitBreaker.record_failure(Tables.breakers(), key, failure_threshold: 1)
    key
  end

  defp stub(opts \\ []) do
    {:ok, handle} = Stub.new(Keyword.get(opts, :chain_ref, @chain), opts)
    handle
  end

  # Records which backend answered, so "the fallback was used" is an assertion
  # about behaviour rather than about a return value two backends share.
  #
  # `put_new`, not `put`: a caller that configures its own `chain_info` answer
  # is configuring a FAILURE, and a marker that overwrote it would make every
  # failover test pass by never failing.
  defp marked(name, opts) do
    answers = Map.put_new(answers(opts), :chain_info, {:ok, %{marker: name}})
    stub(Keyword.put(opts, :answers, answers))
  end

  defp answers(opts), do: Keyword.get(opts, :answers, %{})

  describe "routing" do
    test "a chain nobody declares is not the same error as a callback nobody answers" do
      # Two different operator problems: a missing configuration entry, and a
      # source set that cannot answer this question.
      router = Router.new([stub(capabilities: [])])

      assert {:error, :no_backend} = Router.call(router, "eip155:999", :chain_info)

      assert {:error, {:unsupported, :get_logs}} =
               Router.call(router, @chain, :get_logs, [@account, []])
    end

    test "declaration order is preference order" do
      router = Router.new([marked(:primary, []), marked(:fallback, [])])

      assert {:ok, %{marker: :primary}} = Router.call(router, @chain, :chain_info)
    end

    test "one handle declaring several chains takes its place in each" do
      multi = stub(chain_ref: "eip155:8453")
      router = Router.new([stub(), multi])

      assert @chain in Router.chains(router)
      assert "eip155:8453" in Router.chains(router)
      assert {:ok, _info} = Router.call(router, "eip155:8453", :chain_info)
    end

    test "the required two are always dispatched, whatever capabilities says" do
      # `capabilities/1` declares the optional half only, so a handle that
      # declares nothing still answers the two every backend implements: which
      # chain this is, and how far it has got.
      router = Router.new([stub(capabilities: [])])

      for {callback, arity} <- Backend.required() do
        args = List.duplicate(@account, arity - 1)
        assert {:ok, _value} = Router.call(router, @chain, callback, args)
      end
    end

    test "a read about a thing on the chain is declared now, not assumed" do
      # ADR-0039: each of these needs an index over things of its kind, over
      # accounts for three of them and over transaction ids for the fourth. A
      # node has neither and an archive has both only over ranges, so a handle
      # that declares nothing must not be dispatched them. Before that
      # amendment all four were required and this returned data.
      router = Router.new([stub(capabilities: [])])

      assert {:error, {:unsupported, :get_transaction}} =
               Router.call(router, @chain, :get_transaction, ["0xdeadbeef"])

      assert {:error, {:unsupported, :account_info}} =
               Router.call(router, @chain, :account_info, [@account])

      assert {:error, {:unsupported, :list_transactions}} =
               Router.call(router, @chain, :list_transactions, [@account, []])

      assert {:error, {:unsupported, :token_balances}} =
               Router.call(router, @chain, :token_balances, [@account])
    end
  end

  describe "per-callback candidates" do
    test "a fallback chain can be shorter for one callback than another" do
      full = stub(capabilities: [:get_logs, :get_block])
      partial = stub(capabilities: [:get_block])

      router = Router.new([full, partial])

      assert length(Router.candidates(router, @chain, :get_block)) == 2
      assert length(Router.candidates(router, @chain, :get_logs)) == 1
      assert Router.candidates(router, @chain, :raw_request) == []
    end

    test "a declared capability with no implementation is not a candidate" do
      # The half of `Backend.supports?/2` that catches a lie: a router would
      # otherwise dispatch and raise UndefinedFunctionError inside its own
      # failover, which is the one place an exception is least recoverable.
      liar = stub(capabilities: [:definitely_not_a_callback])

      assert Router.candidates(Router.new([liar]), @chain, :definitely_not_a_callback) == []
    end
  end

  describe "health ordering" do
    test "an open breaker demotes a backend to last, it does not remove it" do
      # If every candidate is open, answering nothing is worse than trying one:
      # a breaker can be stale, an upstream cannot be asked while we refuse to
      # ask it.
      sick = marked(:sick, health_key: open(key("sick")))
      well = marked(:well, [])

      router = Router.new([sick, well])

      assert {:ok, %{marker: :well}} = Router.call(router, @chain, :chain_info)

      only_sick = Router.new([sick])
      assert {:ok, %{marker: :sick}} = Router.call(only_sick, @chain, :chain_info)
      assert [_one] = Router.candidates(only_sick, @chain, :chain_info)
    end

    test "within a health class, declaration order survives" do
      # A partition, not a sort: reordering equally healthy backends would
      # silently override the operator's stated preference.
      router = Router.new([marked(:first, []), marked(:second, [])])

      assert {:ok, %{marker: :first}} = Router.call(router, @chain, :chain_info)
    end

    test "a backend with no health key is never unhealthy" do
      # The honest answer for a source that opens no socket. Inventing a key
      # for it would put a row in the breaker table that nothing can ever clear.
      assert Backend.health_key(stub()) == nil
    end

    test "a Blockscout handle reports the same key the outbound path writes" do
      # If these two disagreed, the router would order by one opinion and the
      # client would gate on another, and a tripped breaker would be invisible
      # to failover.
      {:ok, handle} = Blockscout.new(@chain)

      assert {:origin, origin_id} = Backend.health_key(handle)
      assert {:ok, "https://eth.blockscout.com:443"} = Raxol.Web3.Origin.resolve(origin_id)
    end
  end

  describe "failover decides on the error, not on the attempt" do
    test "an error about the source moves to the next backend" do
      for reason <- [
            {:breaker_open, "abc"},
            {:transport, :econnrefused},
            {:timeout, :chunk},
            {:timeout, :connect},
            {:dns_failed, "abc"},
            {:rate_limited, 500},
            {:too_large, 2048},
            {:decode_failed, :json},
            {:http, 403},
            {:http, 429},
            {:http, 503},
            {:blocked, :address},
            # A base URL that does not parse is this source's configuration.
            {:blocked, :invalid_url},
            # A credential this deployment does not hold is a fact about the
            # source, and it cannot be reached through health: an upstream that
            # answers 404 under a withdrawn key prefix records a breaker
            # success, so only this classification moves the call on.
            {:upstream_refused, :auth},
            {:upstream_refused, :rate_limit},
            # "This source does not serve this chain", which a sibling may.
            {:unsupported_chain, "solana-mainnet"}
          ] do
        router =
          Router.new([
            marked(:primary, answers: %{chain_info: {:error, reason}}),
            marked(:fallback, [])
          ])

        assert {:ok, %{marker: :fallback}} = Router.call(router, @chain, :chain_info),
               "#{inspect(reason)} did not fail over"
      end
    end

    test "an error about the question is final, because the next source answers the same" do
      for reason <- [
            {:upstream_refused, :not_found},
            # A refusal we could not classify is not evidence that another
            # source would do better, so the caller sees the first refusal
            # rather than the last source's.
            {:upstream_refused, :unknown},
            {:unsupported_account_ref, :party},
            {:http, 404},
            {:http, 400}
          ] do
        router =
          Router.new([
            marked(:primary, answers: %{chain_info: {:error, reason}}),
            marked(:fallback, [])
          ])

        assert {:error, ^reason} = Router.call(router, @chain, :chain_info),
               "#{inspect(reason)} failed over when it should not have"
      end
    end

    test "failing over does not record health, so one failure is not counted twice" do
      # The outbound path is the only writer. A router that also recorded would
      # open a breaker at half the configured threshold, and an operator tuning
      # the threshold would be tuning something else.
      health = key("not-written")

      router =
        Router.new([
          stub(health_key: health, answers: %{chain_info: {:error, {:timeout, :chunk}}}),
          stub()
        ])

      assert {:ok, _info} = Router.call(router, @chain, :chain_info)
      assert CircuitBreaker.status(Tables.breakers(), health).failures == 0
    end
  end

  describe "which error a failed walk reports" do
    # One backend per answer, in walk order; an `:ok` answer marks a success.
    defp walk(answers, callback \\ :chain_info, args \\ []) do
      answers
      |> Enum.with_index()
      |> Enum.map(fn {answer, i} -> stub(name: :"s#{i}", answers: %{callback => answer}) end)
      |> Router.new()
      |> Router.call(@chain, callback, args)
    end

    defp fails(reason), do: {:error, reason}

    @page [@account, [cursor: "minted-by-the-first-source"]]

    test "a cursor the second source refuses does not stand in for the first source's timeout" do
      # A cursor is bound to the source that minted it, so the fallback refuses
      # it with :wrong_scope. The cursor was right; a retry with it is the
      # correct next step, which the timeout says.
      assert {:error, {:timeout, :chunk}} =
               walk(
                 [fails({:timeout, :chunk}), fails({:invalid_cursor, :wrong_scope})],
                 :list_transactions,
                 @page
               )
    end

    test "with no failover, the first source's own invalid_cursor stands" do
      assert {:error, {:invalid_cursor, :wrong_scope}} =
               walk(
                 [fails({:invalid_cursor, :wrong_scope}), {:ok, %{}}],
                 :list_transactions,
                 @page
               )
    end

    test "with no failover, the one source's answer stands, a bare 400 included" do
      for reason <- [
            {:upstream_refused, :not_found},
            {:unsupported_account_ref, :party},
            {:http, 400}
          ] do
        assert {:error, ^reason} = walk([fails(reason), {:ok, %{}}]), inspect(reason)
      end
    end

    test "when every source fails, the caller is told the first fault, not the last" do
      assert {:error, {:timeout, :chunk}} =
               walk([fails({:timeout, :chunk}), fails({:timeout, :connect}), fails({:http, 403})])

      assert {:error, {:http, 503}} = walk([fails({:http, 503}), fails({:rate_limited, 500})])
    end

    test "a bare status from a fallback does not stand in for an earlier fault (the live case)" do
      assert {:error, {:timeout, :chunk}} =
               walk([fails({:timeout, :chunk}), fails({:http, 403}), fails({:http, 400})])

      assert {:error, {:timeout, :chunk}} =
               walk([
                 fails({:timeout, :chunk}),
                 fails({:too_large, 2_097_152}),
                 fails({:http, 400})
               ])
    end

    test "after a failover, an answer only that source would give is not reported" do
      for later <- [
            {:http, 404},
            {:http, 422},
            {:upstream_refused, :unknown},
            {:unsupported, :read_contract},
            {:invalid_argument, "hash"},
            {:blocked, :invalid_url}
          ] do
        assert {:error, {:timeout, :chunk}} = walk([fails({:timeout, :chunk}), fails(later)]),
               inspect(later)
      end
    end

    test "after a failover, an answer every source would give stands" do
      for later <- [
            {:upstream_refused, :not_found},
            {:unsupported_account_ref, :not_an_address},
            {:missing_argument, "account"}
          ] do
        assert {:error, ^later} = walk([fails({:timeout, :chunk}), fails(later)]), inspect(later)
      end
    end

    test "an open breaker gives way to the first fault from a call actually made" do
      assert {:error, {:timeout, :chunk}} =
               walk([fails({:breaker_open, "a"}), fails({:timeout, :chunk})])

      assert {:error, {:breaker_open, "a"}} =
               walk([fails({:breaker_open, "a"}), fails({:breaker_open, "b"})])
    end

    test "after only open breakers, the first source actually called answers for itself" do
      # An open breaker is a fact about earlier calls, so a walk whose only
      # earlier faults are open breakers has not failed over from a call. Same
      # outcome as a primary demoted by its health key (below), whether or not
      # the backend exposes one.
      for {walk, expected} <- [
            {[fails({:breaker_open, "a"}), fails({:http, 400})], {:http, 400}},
            {[fails({:breaker_open, "a"}), fails({:invalid_argument, "hash"})],
             {:invalid_argument, "hash"}},
            {[fails({:breaker_open, "a"}), fails({:breaker_open, "b"}), fails({:http, 404})],
             {:http, 404}}
          ] do
        assert {:error, ^expected} = walk(walk), inspect(walk)
      end
    end

    test "a primary demoted for its open breaker is tried last, and its breaker_open is not reported" do
      sick =
        stub(
          name: :sick,
          health_key: open(key("demoted")),
          answers: %{chain_info: fails({:breaker_open, "sick"})}
        )

      timing_out = stub(name: :slow, answers: %{chain_info: fails({:timeout, :chunk})})

      assert {:error, {:timeout, :chunk}} =
               Router.call(Router.new([sick, timing_out]), @chain, :chain_info)
    end

    test "a primary demoted for its open breaker does not change the answer of the source asked first" do
      sick =
        stub(
          name: :sick,
          health_key: open(key("demoted-400")),
          answers: %{chain_info: fails({:breaker_open, "sick"})}
        )

      refusing = stub(name: :refusing, answers: %{chain_info: fails({:http, 400})})

      assert {:error, {:http, 400}} =
               Router.call(Router.new([sick, refusing]), @chain, :chain_info)
    end

    test "a success after a failover is still the success" do
      assert {:ok, %{marker: :fallback}} =
               walk([fails({:timeout, :chunk}), fails({:http, 403}), {:ok, %{marker: :fallback}}])
    end
  end

  describe "a request that carries a cursor goes to the source that minted it" do
    defp minting(name, scope, opts \\ []) do
      answers = %{list_transactions: Keyword.get(opts, :answer, {:ok, %{marker: name}})}

      stub(
        [name: name, cursor_scopes: [scope], answers: answers] ++
          Keyword.take(opts, [:health_key])
      )
    end

    defp page_two(router, cursor),
      do: Router.call(router, @chain, :list_transactions, [@account, [cursor: cursor]])

    defp cursor_for(scope),
      do: Cursor.encode(%{"block_number" => 1}, scope, :address_transactions)

    test "a minter demoted by its open breaker is still the one asked, and its pause is reported" do
      # Today the first candidate refused the cursor as :wrong_scope and the
      # walk stopped before it asked the minter.
      minter =
        minting(:minter, "scope-a",
          health_key: open(key("minter")),
          answer: {:error, {:breaker_open, "minter"}}
        )

      other = minting(:other, "scope-b", answer: {:error, {:invalid_cursor, :wrong_scope}})

      assert {:error, {:breaker_open, "minter"}} =
               page_two(Router.new([minter, other]), cursor_for("scope-a"))
    end

    test "a minter demoted by its breaker that does answer serves page two" do
      minter = minting(:minter, "scope-a", health_key: open(key("minter-ok")))
      other = minting(:other, "scope-b", answer: {:error, {:invalid_cursor, :wrong_scope}})

      assert {:ok, %{marker: :minter}} =
               page_two(Router.new([minter, other]), cursor_for("scope-a"))
    end

    test "a healthy minter first is asked as before" do
      router = Router.new([minting(:minter, "scope-a"), minting(:other, "scope-b")])

      assert {:ok, %{marker: :minter}} = page_two(router, cursor_for("scope-a"))
    end

    test "a cursor whose scope no configured source has is invalid_cursor, and nobody is asked" do
      router =
        Router.new([
          minting(:a, "scope-a", answer: {:error, {:timeout, :chunk}}),
          minting(:b, "scope-b", answer: {:error, {:timeout, :chunk}})
        ])

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               page_two(router, cursor_for("scope-gone"))
    end

    test "a source that mints no cursors is never sent one" do
      # The stub ignores cursors; asked, it would answer page one as page two.
      router =
        Router.new([
          marked(:mints_none, answers: %{list_transactions: {:ok, %{marker: :rewound}}})
        ])

      assert {:error, {:invalid_cursor, :wrong_scope}} = page_two(router, cursor_for("scope-a"))
    end

    test "a cursor whose claim cannot be read is routed as before, and the first source refuses it" do
      router =
        Router.new([
          minting(:a, "scope-a", answer: {:error, {:invalid_cursor, :malformed}}),
          minting(:b, "scope-b")
        ])

      assert {:error, {:invalid_cursor, :malformed}} = page_two(router, "not-a-cursor")
    end

    test "a forged cursor reaches the source it claims, which refuses it as it does today" do
      # A real backend, so the MAC is really checked: the claim chose the
      # source and nothing else.
      {:ok, minter} =
        Blockscout.new(@chain, cache: false, http_opts: [exchange: refusing_exchange()])

      [scope] = Backend.cursor_scopes(minter)
      [version, payload, _mac] = String.split(cursor_for(scope), ".")

      forged =
        Enum.join(
          [version, payload, Base.url_encode64(:binary.copy(<<0>>, 32), padding: false)],
          "."
        )

      router = Router.new([minting(:other, "scope-b"), minter])

      assert {:error, {:invalid_cursor, :bad_signature}} = page_two(router, forged)
    end
  end

  describe "a misconfigured source is skipped" do
    @invalid_url {:error, {:blocked, :invalid_url}}

    test "the fallback answers when the first source's URL does not parse" do
      assert {:ok, %{marker: :fallback}} = walk([@invalid_url, {:ok, %{marker: :fallback}}])
    end

    test "after only misconfigured or paused sources, the first source called answers for itself" do
      assert {:error, {:http, 400}} = walk([@invalid_url, fails({:http, 400})])

      assert {:error, {:http, 404}} =
               walk([@invalid_url, fails({:breaker_open, "a"}), fails({:http, 404})])

      assert {:error, {:timeout, :chunk}} = walk([@invalid_url, fails({:timeout, :chunk})])
    end

    test "when every source is skipped, the first skip is reported" do
      assert {:error, {:blocked, :invalid_url}} =
               walk([@invalid_url, fails({:breaker_open, "a"})])

      assert {:error, {:breaker_open, "a"}} = walk([fails({:breaker_open, "a"}), @invalid_url])
      assert {:error, {:blocked, :invalid_url}} = walk([@invalid_url, @invalid_url])
    end

    test "a misconfigured fallback after a fault does not stand in for the fault" do
      assert {:error, {:timeout, :chunk}} = walk([fails({:timeout, :chunk}), @invalid_url])
    end

    test "the operator is warned once per source, by name and never by URL" do
      name = :"misconfigured_#{System.unique_integer([:positive])}"
      broken = stub(name: name, answers: %{chain_info: @invalid_url})
      router = Router.new([broken, marked(:fallback, [])])

      log =
        ExUnit.CaptureLog.capture_log([level: :warning], fn ->
          for _call <- 1..3, do: assert({:ok, _} = Router.call(router, @chain, :chain_info))
        end)

      lines = for line <- String.split(log, "\n"), line =~ "does not parse", do: line
      assert [line] = lines
      assert line =~ "#{name} (#{@chain})"
      refute line =~ "://"
    end
  end

  describe "a paging walk is pinned to the backend that started it" do
    test "an invalid cursor is final, so a failover cannot rewind a paginated read" do
      # The failure this rule prevents: the fallback cannot use another
      # backend's cursor, so it would answer with its FIRST page and the caller
      # would receive page one labelled page two. An error is recoverable; a
      # silent rewind is not. The cursor claims a scope no configured source
      # has, so nothing is asked, and the fallback (which mints no cursors)
      # is never sent it.
      cursor = Cursor.encode(%{"block_number" => 1}, "someotherorigin", :address_transactions)

      {:ok, primary} =
        Blockscout.new(@chain, cache: false, http_opts: [exchange: refusing_exchange()])

      router = Router.new([primary, marked(:fallback, [])])

      assert {:error, {:invalid_cursor, :wrong_scope}} =
               Router.call(router, @chain, :list_transactions, [@account, [cursor: cursor]])
    end

    test "a walk that starts on the primary continues on the primary" do
      {:ok, primary} = Blockscout.new(@chain, cache: false, http_opts: paging_exchange())

      router = Router.new([primary, stub()])

      assert {:ok, %{next: cursor}} =
               Router.call(router, @chain, :list_transactions, [@account, []])

      assert is_binary(cursor)

      assert {:ok, page} =
               Router.call(router, @chain, :list_transactions, [@account, [cursor: cursor]])

      assert [%{hash: "0xpage2"}] = page.items
    end
  end

  describe "coverage/2" do
    test "reports what is answerable now, in preference order" do
      router =
        Router.new([
          stub(capabilities: [:get_logs]),
          stub(capabilities: [:get_logs, :get_block])
        ])

      coverage = Router.coverage(router, @chain)

      assert coverage[:get_logs] == [:stub, :stub]
      assert coverage[:get_block] == [:stub]
      assert coverage[:chain_info] == [:stub, :stub]
      refute Map.has_key?(coverage, :raw_request)
    end

    test "a callback whose only source is open-breakered drops out" do
      # The degradation that is otherwise invisible until a caller gets an
      # error: a challenge-serving explorer takes the explorer-only callbacks
      # with it, and the operator's question is which ones.
      sick = stub(capabilities: [:get_logs], health_key: open(key("coverage")))

      coverage = Router.coverage(Router.new([sick]), @chain)

      assert coverage == %{}
    end

    test "an unrouted chain has no coverage rather than an error" do
      assert Router.coverage(Router.new([stub()]), "eip155:999") == %{}
    end
  end

  describe "against a real upstream" do
    @tag :live_web3
    test "routes a live read and reports live coverage" do
      {:ok, blockscout} =
        Blockscout.new(@chain,
          cache: false,
          http_opts: [chunk_timeout_ms: 30_000, deadline_ms: 60_000]
        )

      router = Router.new([blockscout])

      assert {:ok, info} = Router.call(router, @chain, :chain_info)
      assert info.total_blocks > 25_000_000

      coverage = Router.coverage(router, @chain)
      assert coverage[:chain_info] == [:blockscout]
      assert coverage[:get_logs] == [:blockscout]

      # Declined rather than declared, so it is absent from a live coverage
      # report too, not merely from the capability list.
      refute Map.has_key?(coverage, :raw_request)
    end
  end

  defp refusing_exchange do
    fn _vetted, request, _opts ->
      flunk("the router built a request from an unusable cursor: #{inspect(request.path)}")
    end
  end

  # Page one carries a cursor; page two is whatever the cursor asks for. Keyed
  # on the presence of the query string, which is the only difference between
  # the two requests.
  defp paging_exchange do
    [
      resolver: fn _charlist, family ->
        case family do
          :inet -> {:ok, [{93, 184, 216, 34}]}
          :inet6 -> {:ok, []}
        end
      end,
      rate_limit: [capacity: 1_000_000, refill_per_second: 1_000_000.0],
      breaker: [failure_threshold: 1_000_000],
      exchange: fn _vetted, request, _opts ->
        body =
          if String.contains?(request.path, "block_number=") do
            ~s({"items":[{"hash":"0xpage2"}],"next_page_params":null})
          else
            ~s({"items":[{"hash":"0xpage1"}],"next_page_params":{"block_number":1,"index":2,"items_count":50}})
          end

        {:ok, %{status: 200, headers: [], body: body}}
      end
    ]
  end
end
