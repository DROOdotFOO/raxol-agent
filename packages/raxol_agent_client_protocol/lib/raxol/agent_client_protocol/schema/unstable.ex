defmodule Raxol.AgentClientProtocol.Schema.Unstable do
  @moduledoc """
  Unstable ACP types (the reference implementation's `unstable_*` features):
  `session/set_model`, `session/set_config_option`, `session/fork`,
  `session/resume`, `session/list`, and their capability flags. They may change
  at any time; gate use on `Schema.AgentTypes.SessionCapabilities`.

  Decoding follows the `Schema.AgentTypes` conventions (`_meta` pass-through,
  `from_json/1` never raises).

  Ported from the MIT `f1729/agent_client_protocol` (c) 2025 f1729; see NOTICE.md.
  """
end
