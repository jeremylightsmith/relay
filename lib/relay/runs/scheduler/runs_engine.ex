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

  Every other outcome is a permanent condition, not a race (an unsupported node
  type, an empty flow, an invalid changeset, or a missing card/board/flow) — the
  card stays `:ready` and the next reconcile would just re-dispatch and fail the
  same way forever. Those are logged via `Logger.warning/1`, naming the card id,
  flow key, and reason, so they're visible to an operator instead of vanishing.
  """

  @behaviour Relay.Runs.Scheduler.Engine

  alias Relay.Flows
  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Run

  require Logger

  @impl true
  def active_runs(board_id), do: Runs.active_runs(board_id)

  @impl true
  def start_run(card_id, flow_key, _executor_id) do
    case lookup(card_id, flow_key) do
      {:ok, card, flow} ->
        case Runs.start_run(card, flow) do
          {:ok, _run} -> :ok
          {:error, :active_run_exists} -> :ok
          {:error, :flow_disabled} -> :ok
          {:error, other} -> warn(card_id, flow_key, other)
        end

      {:error, reason} ->
        warn(card_id, flow_key, reason)
    end
  end

  defp lookup(card_id, flow_key) do
    with %Card{} = card <- Repo.get(Card, card_id),
         %Board{} = board <- Repo.get(Board, card.board_id),
         %{} = flow <- Enum.find(Flows.list_enabled_flows(board), &(&1.key == flow_key)) do
      {:ok, card, flow}
    else
      _ -> {:error, :card_board_or_flow_not_found}
    end
  end

  # Not a race — the card stays :ready and would be re-dispatched (and fail the
  # same way) on the next reconcile, so this must be visible to an operator.
  defp warn(card_id, flow_key, reason) do
    Logger.warning(
      "RunsEngine.start_run/3 permanent failure: card_id=#{card_id} flow_key=#{flow_key} reason=#{inspect(reason)}"
    )

    :ok
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
