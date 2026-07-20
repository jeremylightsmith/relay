defmodule Relay.Runs.Listener do
  @moduledoc """
  Reconciles card events with runs (ADR 0006 §5). `Relay.Cards` cannot
  depend on `Relay.Runs` (the dependency runs the other way), so the
  engine observes: one GenServer subscribes to the `Relay.Events`
  firehose and, on any event naming a card, compares current card state
  against run state and fixes mismatches — stateless, so a missed
  broadcast self-heals on the next event, and reconciliation triggered by
  its own writes converges to a no-op.

  A boot sweep (`init/1`'s `{:continue, :boot_reconcile}`) reconciles every card holding a
  `:parked` run at startup, so an answer that arrived while this process was down is not lost
  — the scheduler is no longer a backstop for `:needs_input`/`:claimed` parks (RLY-200).

  Rules, in order:
    * active `:running` run + human owner present → revoke the active job
      and park the run `:claimed` at its last checkpoint (the card is not
      touched).
    * parked `:needs_input` + card no longer `:needs_input` (the answer
      arrived) → resume the SAME node with the stored `session_id`
      (`claude -p --resume`; the only session-resuming re-entry).
    * parked `:claimed` + card AI-owned again (hand-back) → resume fresh
      (the human may have changed anything).
    * no active run + open rejection + the card sits in the works-in stage
      of an enabled flow + the card's latest run (if any) is `:done` →
      start a new run with `context: %{"changes_requested" => note}`.
      The latest-run guard keeps a failed re-entry from looping forever;
      re-pulling after failure is a human call (03's scheduler rule).
  """

  use GenServer

  import Ecto.Query

  alias Relay.Repo
  alias Relay.Runs
  alias Schemas.Card
  alias Schemas.Flow
  alias Schemas.NodeExecution
  alias Schemas.Run

  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @impl true
  def init(_opts) do
    # Traps its supervisor's :shutdown exit signal into a message instead of
    # dying mid-reconcile: an untrapped signal can land while a Repo call is
    # in flight (e.g. a test's stop_supervised!/1 racing a queued firehose
    # event), which — in the test sandbox's shared connection — poisons the
    # one shared connection for the rest of the test. Trapping lets the
    # current handle_info finish, then GenServer's default handling of the
    # parent's {:EXIT, ...} message stops it normally.
    Process.flag(:trap_exit, true)
    :ok = Relay.Events.subscribe_firehose()
    {:ok, %{}, {:continue, :boot_reconcile}}
  end

  @impl true
  def handle_continue(:boot_reconcile, state) do
    Run
    |> where([r], r.status == :parked)
    |> select([r], r.card_id)
    |> Repo.all()
    |> Enum.each(&reconcile/1)

    {:noreply, state}
  end

  @impl true
  def handle_info({_board_id, event}, state) do
    case card_id_of(event) do
      nil -> :ok
      card_id -> reconcile(card_id)
    end

    {:noreply, state}
  end

  def handle_info(_other, state), do: {:noreply, state}

  defp card_id_of({:card_upserted, %Card{id: id}}), do: id
  defp card_id_of({:card_moved, %Card{id: id}, _from_stage_id}), do: id
  defp card_id_of({:timeline_appended, card_id, _entry}), do: card_id
  defp card_id_of(_event), do: nil

  defp reconcile(card_id) do
    case Repo.get(Card, card_id) do
      nil -> :ok
      card -> card |> Repo.preload(:owners) |> reconcile_card()
    end
  end

  defp reconcile_card(card), do: reconcile_card(card, Runs.active_run(card))

  defp reconcile_card(card, nil), do: maybe_reenter_after_rejection(card)

  defp reconcile_card(card, %Run{status: :running} = run) do
    if Relay.Cards.active_owner_type(card) == :human, do: Runs.park_claimed(run)
    :ok
  end

  defp reconcile_card(card, %Run{status: :parked, parked_reason: :needs_input} = run) do
    if card.status != :needs_input do
      _ = Runs.resume_run(run, resume_session: last_session(run))
    end

    :ok
  end

  defp reconcile_card(card, %Run{status: :parked, parked_reason: :claimed} = run) do
    if Relay.Cards.active_owner_type(card) == :ai do
      _ = Runs.resume_run(run)
    end

    :ok
  end

  # Defensive fallback: any other run shape (e.g. a parked run with an
  # unexpected/missing `parked_reason`, such as data seeded or migrated
  # outside `Relay.Runs`'s own park_* functions) is left untouched rather
  # than crashing the reconciler — reconciliation self-heals on the next
  # event, so a no-op here is safe.
  defp reconcile_card(_card, %Run{}), do: :ok

  defp last_session(%Run{} = run) do
    Repo.one(
      from e in NodeExecution,
        where: e.run_id == ^run.id and e.node_key == ^run.current_node and not is_nil(e.session_id),
        order_by: [desc: e.id],
        limit: 1,
        select: e.session_id
    )
  end

  defp maybe_reenter_after_rejection(%Card{rejection: nil}), do: :ok

  defp maybe_reenter_after_rejection(%Card{} = card) do
    flow =
      Repo.one(
        from f in Flow,
          where: f.board_id == ^card.board_id and f.works_in_stage_id == ^card.stage_id and f.enabled,
          order_by: f.key,
          limit: 1
      )

    if flow && last_run_done?(card) do
      _result = Runs.start_run(card, flow, context: %{"changes_requested" => card.rejection.note})
    end

    :ok
  end

  defp last_run_done?(card) do
    case Runs.list_runs(card) do
      [] -> true
      [latest | _rest] -> latest.status == :done
    end
  end
end
