# Capability booleans decode least-permissively: only a literal boolean
# survives; `0`, `""`, `"false"`, `[]` or an object read as `false`.
defmodule Raxol.AgentClientProtocol.Schema.CapabilityBooleanStrictnessTest do
  use ExUnit.Case, async: true

  alias Raxol.AgentClientProtocol.Schema.AgentTypes.{
    AgentCapabilities,
    McpCapabilities,
    PromptCapabilities,
    SessionCapabilities
  }

  describe "capability booleans reject non-boolean wire values (least-permissive)" do
    test ~S(PromptCapabilities: 0 / "" / "false" do not enable) do
      assert {:ok, caps} =
               PromptCapabilities.from_json(%{
                 "image" => 0,
                 "audio" => "",
                 "embeddedContext" => "false"
               })

      refute caps.image, "integer 0 must not enable image"
      refute caps.audio, "empty string must not enable audio"
      refute caps.embedded_context, "the string \"false\" must not enable embeddedContext"
    end

    test "PromptCapabilities: a literal true still enables" do
      assert {:ok, caps} = PromptCapabilities.from_json(%{"image" => true})
      assert caps.image
    end

    test "McpCapabilities: an empty list does not enable http" do
      assert {:ok, caps} = McpCapabilities.from_json(%{"http" => [], "sse" => true})
      refute caps.http
      assert caps.sse
    end

    test "AgentCapabilities: a non-empty string does not enable loadSession" do
      assert {:ok, caps} = AgentCapabilities.from_json(%{"loadSession" => "yes"})
      refute caps.load_session
    end

    test "SessionCapabilities: a non-boolean does not enable modes" do
      assert {:ok, caps} = SessionCapabilities.from_json(%{"modes" => 1})
      refute caps.modes
    end
  end
end
