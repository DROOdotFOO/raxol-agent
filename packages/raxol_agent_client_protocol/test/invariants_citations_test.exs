# Every `file:line` citation in test/INVARIANTS.md must land on a test,
# describe or property line, so renumbering a test file cannot silently
# point a row at the wrong test.
defmodule Raxol.AgentClientProtocol.InvariantsCitationsTest do
  use ExUnit.Case, async: true

  # Rows that deliberately cite a comment or moduledoc line.
  @comment_citations MapSet.new([
                       "connection_test.exs:76",
                       "integration/end_to_end_test.exs:301",
                       "integration/end_to_end_test.exs:21",
                       "attach_policy_test.exs:2",
                       "attach_policy_test.exs:165"
                     ])

  test "every INVARIANTS.md citation points at a test" do
    test_files = Path.wildcard("test/**/*_test.exs")
    doc = File.read!("test/INVARIANTS.md")
    citations = Regex.scan(~r/([a-z_\/]+_test\.exs):(\d+)/, doc)

    assert length(citations) > 50, "found only #{length(citations)} citations"

    bad =
      for [cite, file, line] <- citations, not MapSet.member?(@comment_citations, cite) do
        [path] = Enum.filter(test_files, &String.ends_with?(&1, "/" <> file))
        text = path |> File.read!() |> String.split("\n") |> Enum.at(String.to_integer(line) - 1)
        if text =~ ~r/^\s*(test|describe|property)\s+"/, do: [], else: [{cite, String.trim(text)}]
      end
      |> List.flatten()

    assert bad == [], "citations not on a test line: #{inspect(bad, pretty: true)}"
  end
end
