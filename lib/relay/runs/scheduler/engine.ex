defmodule Relay.Runs.Scheduler.Engine do
  @moduledoc """
  The seam between the scheduler shell and the run engine (W5 / RLY-132). The
  shell reads active runs and delegates each decision here; the engine owns
  `Run` rows, the `→ :working` transition, and the stage move (the scheduler
  never does). Named here as a behaviour so the shell is injectable and testable.

  Note: this is deliberately NOT named `Relay.Runs.Engine` — RLY-132/W5 landed
  first and already owns that name for its pure outcome-routing core
  (`Relay.Runs.Engine.decide/4`). This module is the *scheduler's* engine
  seam — a different contract entirely (dispatch decisions in, not outcome
  routing) — so it is nested under `Scheduler` to keep the two apart.
  `Relay.Runs.Scheduler.NoopEngine` is the production binding until a real
  adapter onto `Relay.Runs`'s run-execution engine is wired up.

    * `active_runs/1` — the active runs (`status in [:running, :parked]`) for a
      board, each as a `Snapshot.run` map.
    * `start_run/3` — start a run for `card_id` under `flow_key` on `executor_id`
      (engine moves the card to works-in and sets `:working`).
    * `resume_run/2` — re-enter parked `run_id` on `executor_id`.
  """

  @callback active_runs(board_id :: term()) :: [map()]
  @callback start_run(card_id :: term(), flow_key :: String.t(), executor_id :: term()) :: :ok
  @callback resume_run(run_id :: term(), executor_id :: term()) :: :ok
end
