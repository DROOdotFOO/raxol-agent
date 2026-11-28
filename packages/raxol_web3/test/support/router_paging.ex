defmodule Raxol.Web3.TestSupport.RouterPaging do
  @moduledoc false
  # Page two through `Raxol.Web3.Router`, for a backend that mints cursors.
  #
  # The router sends a request that carries a cursor only to a handle whose
  # `cursor_scopes/1` includes the scope the cursor claims. A backend that
  # mints cursors without declaring that scope gets page two refused with
  # `invalid_cursor` and nobody asked, and the hint tells a model to start
  # again: it would page through page one for ever. So each minting backend
  # mints page one itself and must get page two back through the router.
  #
  # The decoy is declared first, on the same chain, claims another scope and
  # refuses every cursor: page two comes back only if the router chose the
  # minter by its declared scope.

  alias Raxol.Web3.Backend
  alias Raxol.Web3.Backend.Stub
  alias Raxol.Web3.Router

  @spec page_two(Backend.t(), atom(), [term()]) :: {map(), {:ok, map()} | {:error, term()}}
  def page_two({module, state} = handle, callback, leading_args) do
    [chain | _] = module.supported_chain_ids(state)

    {:ok, first} = Backend.call(handle, callback, leading_args ++ [[]])
    true = is_binary(first.next)

    {:ok, decoy} =
      Stub.new(chain,
        name: :decoy,
        cursor_scopes: ["a-scope-no-backend-mints"],
        answers: %{callback => {:error, {:invalid_cursor, :wrong_scope}}}
      )

    router = Router.new([decoy, handle])

    {first, Router.call(router, chain, callback, leading_args ++ [[cursor: first.next]])}
  end
end
