defmodule Relay.Runs.Scheduler.RunsEngine do
  @moduledoc """
  Production `Relay.Runs.Scheduler.Engine` binding (RLY-136 / W11) — replaces
  `NoopEngine`. Translates the pure scheduler's dispatch tuples into `Relay.Runs`
  lifecycle calls, preserving the two-layer split: the scheduler owns only the
  `ready ↔ queued` marking, while `Relay.Runs.start_run/3` owns the Run row, the
  works-in move, and setting the card `:working`.

  The scheduler plans against a snapshot that may be a beat stale, so a dispatch
  can race: the card may already have an active run, or the flow may have just
  been disabled. Both documented returns (`:active_run_exists`, `:flow_disabled`)
  are benign here — swallow them as `:ok`; the next reconcile re-derives from
  fresh state. The scheduler must never crash on a lost race.
  """

  @behaviour Relay.Runs.Scheduler.Engine

  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Run

  @impl true
  def active_runs(board_id), do: Runs.active_runs(board_id)

  @impl true
  def start_run(card_id, flow_key, _executor_id) do
    with %Card{} = card <- Repo.get(Card, card_id),
         %Board{} = board <- Repo.get(Board, card.board_id),
         %{} = flow <- Enum.find(Flows.list_enabled_flows(board), &(&1.key == flow_key)) do
      case Runs.start_run(card, flow) do
        {:ok, _run} -> :ok
        {:error, :active_run_exists} -> :ok
        {:error, :flow_disabled} -> :ok
        {:error, _other} -> :ok
      end
    else
      _ -> :ok
    end
  end

  @impl true
  def resume_run(run_id, _executor_id) do
    case Runs.get_run(run_id) do
      %Run{status: :parked} = run ->
        _ = Runs.resume_run(run)
        :ok

      _already_resumed_or_gone ->
        :ok
    end
  end
end
