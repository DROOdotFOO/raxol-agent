defmodule Raxol.Broker.Test.ExecutorIdentity do
  @moduledoc """
  Impersonate `Raxol.Broker.Executor` in the calling test process.

  The journal only grants its claim to a process whose proc_lib initial call
  is `{Raxol.Broker.Executor, :init, 1}`. Tests that drive the journal or
  `Raxol.Broker.Executor.Place` directly need that claim, so this module
  writes the initial call into the caller's process dictionary by hand.

  That is exactly the deliberate-subversion path the broker's threat model
  excludes: the BEAM cannot stop code that writes another module's private
  process state on purpose. It exists for tests only and lives in
  `test/support`, so it is never compiled into the library.
  """

  import ExUnit.Assertions

  alias Raxol.Broker.Journal

  @doc """
  Make the calling process look like an Executor and claim `journal` for it.

  Sets `:"$initial_call"` to `{Raxol.Broker.Executor, :init, 1}` and
  asserts the claim succeeds.
  """
  @spec assume!(Journal.server()) :: :ok
  def assume!(journal) do
    Process.put(:"$initial_call", {Raxol.Broker.Executor, :init, 1})
    assert Journal.claim(journal) == :ok
    :ok
  end
end
