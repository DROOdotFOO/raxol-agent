defmodule Raxol.Earn.Secret do
  @moduledoc """
  Deprecated: use `Raxol.Agent.Secret`, which this module delegates to.

  Calls to `new/1`, `reveal/1` and `with_revealed/2` keep working (with a
  deprecation warning); `new/1` returns a `Raxol.Agent.Secret`, which inspects
  as `#Raxol.Agent.Secret<redacted>`. A pattern on this module's old struct
  no longer matches: match `%Raxol.Agent.Secret{}`.
  """

  @type t :: Raxol.Agent.Secret.t()

  @deprecated "Use Raxol.Agent.Secret.new/1"
  defdelegate new(bytes), to: Raxol.Agent.Secret
  @deprecated "Use Raxol.Agent.Secret.reveal/1"
  defdelegate reveal(secret), to: Raxol.Agent.Secret
  @deprecated "Use Raxol.Agent.Secret.with_revealed/2"
  defdelegate with_revealed(secret, fun), to: Raxol.Agent.Secret
end
