defmodule Relay.Runs.ExecutorReaper do
  @moduledoc """
  The run-lifecycle clock (ADR 0006 card 04): a supervised GenServer whose periodic (30s) sweep
  runs the DB-only run-lifecycle policies on `Relay.Runs` — executor liveness
  (`reclaim_stale_executors/0`: returns a dead executor's in-flight `shared_clean` jobs to the
  queue and parks its `exclusive` runs) and orphaned-run closure
  (`close_orphaned_runs/0`: closes any run still active while its card sits in a terminal stage,
  RLY-233). It holds no state beyond its timer — the policies are pure/DB functions; this is only
  their heartbeat, and its first tick (≤ one interval after boot) doubles as the startup catch-up.
  """
  use GenServer

  @default_interval_ms to_timeout(second: 30)

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: Keyword.get(opts, :name, __MODULE__))

  @impl true
  def init(opts) do
    interval = Keyword.get(opts, :interval_ms, @default_interval_ms)
    {:ok, %{interval: interval}, {:continue, :schedule}}
  end

  @impl true
  def handle_continue(:schedule, state) do
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end

  @impl true
  def handle_info(:sweep, state) do
    Relay.Runs.reclaim_stale_executors()
    Relay.Runs.close_orphaned_runs()
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end
end
