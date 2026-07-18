defmodule Relay.Runs.ExecutorReaper do
  @moduledoc """
  The executor-liveness clock (ADR 0006 card 04): a supervised GenServer that
  periodically calls `Relay.Runs.reclaim_stale_executors/0`, returning a dead
  executor's in-flight `shared_clean` jobs to the queue and parking its
  `exclusive` runs. It holds no state beyond its timer — the reclaim policy is a
  pure/DB function on `Relay.Runs`; this is only its heartbeat. Its first sweep
  is one interval away, so booting never touches the DB.
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
    Process.send_after(self(), :sweep, state.interval)
    {:noreply, state}
  end
end
