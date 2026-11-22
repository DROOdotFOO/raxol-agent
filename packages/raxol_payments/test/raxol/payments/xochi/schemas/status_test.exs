defmodule Raxol.Payments.Xochi.Schemas.StatusTest do
  use ExUnit.Case, async: true

  alias Raxol.Payments.Xochi.Schemas.{ExecuteResponse, Intent, IntentStatus, Status}

  test "parses every known wire status and reads anything else as :unknown" do
    assert Status.parse("completed") == :completed
    assert Status.parse("refund_pending") == :refund_pending

    for unknown <- [nil, "", "COMPLETED", "not_a_status", 7, :completed],
        do: assert(Status.parse(unknown) == :unknown)
  end

  test "parse/2 reads a known status outside the allowed set as :unknown" do
    assert Status.parse("quoted", [:completed]) == :unknown
    assert Status.parse("completed", [:completed]) == :completed
  end

  test "the schemas agree on a shared status and differ only where the execute set is narrower" do
    assert IntentStatus.from_json(%{"status" => "quoted"}).status == :quoted
    assert Intent.from_json(%{"status" => "quoted"}).status == :quoted
    assert ExecuteResponse.from_json(%{"status" => "quoted"}).status == :unknown

    for wire <- ~w(pending executing completed failed expired refunded) do
      status = String.to_existing_atom(wire)
      assert IntentStatus.from_json(%{"status" => wire}).status == status
      assert Intent.from_json(%{"status" => wire}).status == status
      assert ExecuteResponse.from_json(%{"status" => wire}).status == status
    end
  end
end
