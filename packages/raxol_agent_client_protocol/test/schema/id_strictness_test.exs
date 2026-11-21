# Identifier fields must be strings: a wrong-typed value fails decode (-32602)
# instead of reaching a handler.
defmodule Raxol.AgentClientProtocol.Schema.IdStrictnessTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.LifecycleExtras.{
    CloseSessionRequest,
    DeleteSessionRequest
  }

  alias Raxol.AgentClientProtocol.Schema.Unstable.{
    ForkSessionRequest,
    ResumeSessionRequest,
    SetSessionConfigOptionRequest,
    SetSessionModelRequest
  }

  @bad [12_345, nil, %{"x" => 1}, ["s"]]

  for {mod, base} <- [
        {CloseSessionRequest, %{}},
        {DeleteSessionRequest, %{}},
        {ForkSessionRequest, %{"cwd" => "/w"}},
        {ResumeSessionRequest, %{"cwd" => "/w"}},
        {SetSessionModelRequest, %{"modelId" => "m"}}
      ] do
    test "#{inspect(mod)} rejects a non-string sessionId" do
      for bad <- @bad do
        assert {:error, {:invalid_field, "sessionId", ^bad}} =
                 unquote(mod).from_json(Map.put(unquote(Macro.escape(base)), "sessionId", bad))
      end

      assert {:ok, _} =
               unquote(mod).from_json(Map.put(unquote(Macro.escape(base)), "sessionId", "s"))
    end
  end

  test "fork and resume reject a non-string cwd" do
    for mod <- [ForkSessionRequest, ResumeSessionRequest] do
      assert {:error, {:invalid_field, "cwd", 1}} =
               mod.from_json(%{"sessionId" => "s", "cwd" => 1})
    end
  end

  test "modelId and configId must be strings" do
    assert {:error, {:invalid_field, "modelId", 7}} =
             SetSessionModelRequest.from_json(%{"sessionId" => "s", "modelId" => 7})

    assert {:error, {:invalid_field, "configId", 7}} =
             SetSessionConfigOptionRequest.from_json(%{
               "sessionId" => "s",
               "configId" => 7,
               "value" => "v"
             })
  end
end
