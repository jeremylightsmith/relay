defmodule Mix.Tasks.Relay.Flows.SyncDefaults do
  @shortdoc "Push the current default flow library onto existing boards (RLY-192)"

  @moduledoc """
  Re-syncs every board's library-key flows to the current `Relay.Flows.DefaultLibrary`, so a
  flow-graph edit reaches boards that already exist. Upgrades only library-managed flows
  (version == 1) and preserves hand-customized ones (version > 1).

      mix relay.flows.sync_defaults

  The deploy path (`Relay.Release.migrate/0`) already runs this; the task is the local/dev
  equivalent.
  """

  use Mix.Task
  use Boundary, check: [in: false, out: false]

  @impl Mix.Task
  def run(_args) do
    Mix.Task.run("app.start")
    summary = Relay.Flows.sync_defaults!()

    Mix.shell().info(
      "sync_defaults: upgraded=#{length(summary.upgraded)} " <>
        "skipped=#{length(summary.skipped)} unchanged=#{length(summary.unchanged)}"
    )
  end
end
