defmodule Hamaca.Runs.Scheduler.NoopEngine do
  @moduledoc """
  The default `Hamaca.Runs.Scheduler.Engine` binding until a real adapter onto
  `Hamaca.Runs`'s run-execution engine is wired up. Reports no active runs and
  swallows dispatches. With no runner connected the capacity store is empty,
  so the scheduler stays dormant and these write callbacks are never invoked
  before a real engine replaces this via the `:runs_engine` config.
  """

  @behaviour Hamaca.Runs.Scheduler.Engine

  @impl true
  def active_runs(_board_id), do: []

  @impl true
  def start_run(_card_id, _flow_key, _runner_id), do: :ok

  @impl true
  def resume_run(_run_id, _runner_id), do: :ok
end
