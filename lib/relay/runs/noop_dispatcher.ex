defmodule Relay.Runs.NoopDispatcher do
  @moduledoc """
  Default dispatcher: jobs simply sit `:queued` — correct for the pull
  model, where real executors poll and claim over REST (card 04). Revoke
  is a DB-state-only affair until a push transport exists.
  """

  @behaviour Relay.Runs.Dispatcher

  @impl true
  def dispatch(_job), do: :ok

  @impl true
  def revoke(_job), do: :ok
end
