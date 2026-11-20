defmodule Mix.Tasks.Raxol.Broker.EvidenceTest do
  use ExUnit.Case, async: true

  import ExUnit.CaptureIO

  alias Raxol.Agent.Journal.FileStore
  alias Mix.Tasks.Raxol.Broker.Evidence

  setup do
    base =
      Path.join(System.tmp_dir!(), "broker-evidence-task-#{System.unique_integer([:positive])}")

    File.mkdir_p!(base)
    on_exit(fn -> File.rm_rf!(base) end)
    path = Path.join(base, "journal")
    {:ok, handle} = FileStore.open("journal", base_dir: base, chain: true)

    {:ok, _} =
      FileStore.append_many(handle, [
        %{
          "kind" => "broker",
          "type" => "intent",
          "group_id" => "private-group",
          "at" => "2026-10-02T14:30:00Z",
          "intent" => %{
            "id" => "private-intent",
            "kind" => "limit",
            "strategy" => "private-secret"
          }
        }
      ])

    :ok = FileStore.close(handle)
    {:ok, base: base, path: path}
  end

  test "prints one redacted JSON document without changing the closed journal or creating an export",
       %{
         base: base,
         path: path
       } do
    before = contents(base)
    json = capture_io(fn -> Evidence.run(["--date", "2026-10-02", "--journal", path]) end)
    assert {:ok, report} = Jason.decode(json)
    assert report["journal_integrity"] == "VERIFIED"
    assert report["result"] == "UNVERIFIED"
    assert [%{"stages" => %{"review" => "UNVERIFIED"}}] = report["groups"]
    refute json =~ "private-secret"
    refute json =~ "private-group"
    refute json =~ "private-intent"
    assert contents(base) == before
  end

  test "rejects bad arguments without printing any JSON", %{path: path} do
    for args <- [
          [],
          ["--date", "2026-02-30"],
          ["--date", "2026-10-02", "--unredacted"],
          ["--date", "2026-10-02", "unexpected"],
          ["--date", "2026-10-02", "--journal", Path.join(path, "missing")]
        ] do
      assert capture_io(fn -> assert_raise Mix.Error, fn -> Evidence.run(args) end end) == ""
    end
  end

  test "a damaged journal raises before any evidence is printed", %{path: path} do
    [segment] = Path.wildcard(Path.join(path, "journal/*.jsonl"))
    File.write!(segment, String.replace(File.read!(segment), "private-intent", "changed-intent"))

    assert capture_io(fn ->
             assert_raise Mix.Error, ~r/hash chain broken at offset/, fn ->
               Evidence.run(["--date", "2026-10-02", "--journal", path])
             end
           end) == ""
  end

  defp contents(base) do
    base
    |> Path.join("**/*")
    |> Path.wildcard(match_dot: true)
    |> Enum.filter(&File.regular?/1)
    |> Map.new(&{Path.relative_to(&1, base), File.read!(&1)})
  end
end
