# Every `file:line` citation in test/INVARIANTS.md must land on a test,
# describe or property line, so renumbering a test file cannot silently
# point a row at the wrong test.
defmodule Raxol.AgentClientProtocol.InvariantsCitationsTest do
  use ExUnit.Case, async: true

  # Rows that deliberately cite a comment or moduledoc line, with text that
  # line must contain.
  @comment_citations %{
    "support/connection_case.ex:39" => "IC-8 pins Connection",
    "integration/end_to_end_test.exs:297" => "IC-8",
    "integration/end_to_end_test.exs:21" => "P-JS5",
    "attach_policy_test.exs:2" => "P-BUS4",
    "attach_policy_test.exs:165" => "CDI-1",
    "ctx_test.exs:18" => "@moduledoc"
  }

  test "every INVARIANTS.md citation points at a test" do
    test_files = Path.wildcard("test/**/*_test.exs") ++ Path.wildcard("test/support/**/*.ex")
    doc = File.read!("test/INVARIANTS.md")
    citations = doc |> String.split("\n") |> Enum.flat_map(&row_citations/1)

    assert length(citations) > 50, "found only #{length(citations)} citations"

    bad =
      for [cite, file, line] <- citations do
        [path] = Enum.filter(test_files, &String.ends_with?(&1, "/" <> file))
        text = path |> File.read!() |> String.split("\n") |> Enum.at(String.to_integer(line) - 1)

        ok? =
          case Map.fetch(@comment_citations, cite) do
            {:ok, marker} -> String.contains?(text, marker)
            :error -> text =~ ~r/^\s*(test|describe|property)\s+"/
          end

        if ok?, do: [], else: [{cite, String.trim(text)}]
      end
      |> List.flatten()

    assert bad == [], "citations not on a test line: #{inspect(bad, pretty: true)}"
  end

  # A bare `:N` cites the file named last before it in the same row, so it is
  # checked against that file too.
  defp row_citations(row) do
    ~r/(support\/[a-z_\/]+\.ex|[a-z_\/]+_test\.exs)(?::(\d+))?|`:(\d+)`/
    |> Regex.scan(row)
    |> Enum.map_reduce(nil, fn
      [_, file], _last -> {[], file}
      [_, file, line], _last -> {[["#{file}:#{line}", file, line]], file}
      [_, "", "", line], nil -> raise "bare `:#{line}` with no file before it: #{row}"
      [_, "", "", line], last -> {[["#{last}:#{line}", last, line]], last}
    end)
    |> elem(0)
    |> Enum.concat()
  end
end
