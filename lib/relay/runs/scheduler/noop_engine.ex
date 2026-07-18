defmodule Relay.Runs.Scheduler.NoopEngine do
  @moduledoc """
  The default `Relay.Runs.Scheduler.Engine` binding until a real adapter onto
  `Relay.Runs`'s run-execution engine is wired up. Reports no active runs and
  swallows dispatches. In production the capacity store is empty until W9, so
  the scheduler stays dormant and these write callbacks are never invoked
  before a real engine replaces this via the `:runs_engine` config.
  """

  @behaviour Relay.Runs.Scheduler.Engine

  @impl true
  def active_runs(_board_id), do: []

  @impl true
  def start_run(_card_id, _flow_key, _executor_id), do: :ok

  @impl true
  def resume_run(_run_id, _executor_id), do: :ok
end
