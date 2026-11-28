defmodule Raxol.Web3.Backend.CursorScopesTest do
  use ExUnit.Case, async: true

  alias Raxol.Web3.Backend

  # A backend that mints cursors without declaring the scope it mints under
  # has page two refused by the router with `invalid_cursor` and nobody asked.
  # The per-backend round trips catch the five that exist; this catches the
  # next one, before anyone writes its round trip.
  @minting ~r/\b(Cursor\.encode|Paging\.next_cursor)\(/

  test "every module that mints cursors belongs to a backend that declares cursor_scopes/1" do
    minters =
      for module <- Application.spec(:raxol_web3, :modules),
          module not in [Raxol.Web3.Cursor, Raxol.Web3.Backend.Paging],
          # A protocol implementation shares its backend's source file.
          Code.ensure_loaded?(module),
          not function_exported?(module, :__impl__, 1),
          source = module.module_info(:compile)[:source],
          String.contains?(to_string(source), "/lib/"),
          File.read!(to_string(source)) =~ @minting,
          uniq: true,
          do: owner(module)

    assert minters != [], "found no module that mints cursors"

    for backend <- minters do
      assert function_exported?(backend, :cursor_scopes, 1),
             "#{inspect(backend)} mints cursors but does not export cursor_scopes/1"
    end
  end

  # A helper module (`Canton.Holdings`) mints for the backend it sits under.
  defp owner(module) do
    if backend?(module) do
      module
    else
      parent = module |> Module.split() |> Enum.drop(-1) |> Module.concat()
      if backend?(parent), do: parent, else: module
    end
  end

  defp backend?(module) do
    Code.ensure_loaded?(module) and
      Backend in List.flatten(Keyword.get_values(module.module_info(:attributes), :behaviour))
  end
end
