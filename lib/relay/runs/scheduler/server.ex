defmodule Relay.Runs.Scheduler.Server do
  @moduledoc """
  The per-board event-driven shell (ADR 0006 / RLY-133). Assembles a
  `Relay.Runs.Scheduler.Snapshot` from the DB + `Relay.Runs.Capacity`, calls the
  pure `Relay.Runs.Scheduler.plan/1`, delegates each dispatch to the injected
  `Relay.Runs.Scheduler.Engine`, and applies the `ready ↔ queued` marking via
  `Relay.Cards` (the only card writes the scheduler owns — it never writes
  `Run` rows or moves cards into works-in).

  Reacts to the board's `Relay.Events` topic and the `Relay.Runs.Capacity`
  capacity-changed topic, debouncing a burst into one reconcile, with a slow
  (~60s) tick as backstop. `reconcile_now/1` forces a synchronous reconcile.
  """

  use GenServer

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Runs.Capacity
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Snapshot

  @tick_ms 60_000
  @debounce_ms 50

  def start_link(opts) do
    board_id = Keyword.fetch!(opts, :board_id)
    GenServer.start_link(__MODULE__, opts, name: name(opts, board_id))
  end

  defp name(opts, board_id) do
    Keyword.get(opts, :name, {:via, Registry, {Relay.Runs.SchedulerRegistry, board_id}})
  end

  @doc "Forces a synchronous reconcile; returns `:ok` once it has run."
  def reconcile_now(server), do: GenServer.call(server, :reconcile)

  @impl true
  def init(opts) do
    board_id = Keyword.fetch!(opts, :board_id)

    state = %{
      board_id: board_id,
      engine: Keyword.get(opts, :engine, default_engine()),
      tick_ms: Keyword.get(opts, :tick_ms, @tick_ms),
      debounce_ms: Keyword.get(opts, :debounce_ms, @debounce_ms),
      pending?: false
    }

    Relay.Events.subscribe(board_id)
    Capacity.subscribe()
    Process.send_after(self(), :tick, state.tick_ms)
    {:ok, state, {:continue, :boot_reconcile}}
  end

  defp default_engine, do: Application.get_env(:relay, :runs_engine, Relay.Runs.Scheduler.NoopEngine)

  @impl true
  def handle_continue(:boot_reconcile, state), do: {:noreply, reconcile(state)}

  @impl true
  def handle_call(:reconcile, _from, state), do: {:reply, :ok, reconcile(state)}

  @impl true
  def handle_info(:tick, state) do
    Process.send_after(self(), :tick, state.tick_ms)
    {:noreply, reconcile(state)}
  end

  def handle_info(:flush, state), do: {:noreply, reconcile(%{state | pending?: false})}

  # Any capacity change or card move/upsert on this board is a reason to reconcile.
  def handle_info({:executor_capacity_changed, _executor_id}, state), do: {:noreply, mark_dirty(state)}
  def handle_info({:card_moved, _card, _from_stage_id}, state), do: {:noreply, mark_dirty(state)}
  def handle_info({:card_upserted, _card}, state), do: {:noreply, mark_dirty(state)}
  def handle_info({:card_archived, _card}, state), do: {:noreply, mark_dirty(state)}
  def handle_info(_msg, state), do: {:noreply, state}

  # Debounce a burst of events into one reconcile.
  defp mark_dirty(%{pending?: true} = state), do: state

  defp mark_dirty(state) do
    Process.send_after(self(), :flush, state.debounce_ms)
    %{state | pending?: true}
  end

  defp reconcile(state) do
    {snapshot, cards_by_id} = build_snapshot(state)
    plan = Scheduler.plan(snapshot)
    Enum.each(plan.dispatches, &dispatch(&1, state.engine))
    apply_marking(plan, cards_by_id)
    state
  end

  defp dispatch({:start, card_id, flow_key, executor_id}, engine), do: engine.start_run(card_id, flow_key, executor_id)

  defp dispatch({:resume, run_id, executor_id}, engine), do: engine.resume_run(run_id, executor_id)

  # --- snapshot assembly (returns the loaded card structs so apply_marking can write status) ---

  @doc """
  Assembles the dispatch snapshot for `board_id` against `engine`, returning it alongside
  the loaded card structs (which `apply_marking/2` writes status through).

  Public because `Relay.Runs.diagnose/3` (RLY-177) must diagnose against **byte-for-byte
  the snapshot this server plans from** — including the `reserve_active_runs/2` debit for
  in-flight runs. A second assembly path would be a second source of truth.
  """
  def build_snapshot(board_id, engine) do
    board = Boards.get_board_by_id!(board_id)
    cards = Cards.list_cards(board)
    runs = engine.active_runs(board_id)

    snapshot = %Snapshot{
      stages: Enum.map(Boards.list_stages(board), &stage_snap/1),
      cards: Enum.map(cards, &card_snap(&1, board)),
      flows: Enum.map(Relay.Flows.list_enabled_flows(board), &flow_snap/1),
      runs: runs,
      capacity: reserve_active_runs(Capacity.snapshot(), runs),
      executors: executor_snap(board_id)
    }

    {snapshot, Map.new(cards, &{&1.id, &1})}
  end

  # Reuses Relay.Runs.executor_outdated?/1 and executor_freshness/2 — the same truth the
  # runners view and the reaper read — so the scheduler's "outdated" can never disagree with
  # the roster's. `now` is read once for a consistent freshness pass.
  defp executor_snap(board_id) do
    now = DateTime.utc_now()

    board_id
    |> Relay.Runs.list_board_executors()
    |> Map.new(fn e ->
      {e.id,
       %{
         name: e.name,
         version: e.version,
         outdated: Relay.Runs.executor_outdated?(e),
         freshness: Relay.Runs.executor_freshness(e, now)
       }}
    end)
  end

  @doc "The app's configured engine — for callers with no injected one (e.g. `Runs.diagnose/3`)."
  def configured_engine, do: default_engine()

  defp build_snapshot(state), do: build_snapshot(state.board_id, state.engine)

  # A run that is :running is being worked on an executor right now, so it holds
  # one slot of its isolation class until it finishes — even if the executor's
  # next heartbeat hasn't yet reflected it. Subtract those held slots from the
  # advertised capacity before planning (parked runs hold no slot; the pure
  # planner's resume_runs consumes a slot only when it actually resumes one).
  #
  # NOTE (board-scoped vs. global): `runs` here is this board's active runs only
  # (`state.engine.active_runs(state.board_id)`), but `Capacity.snapshot/0` is
  # global — an executor shared across boards has its capacity debited only by
  # the runs each board's own scheduler knows about. Two boards dispatching to
  # the same executor at once can each believe a slot is free. Tracked as a
  # follow-up; not a regression introduced here (there was no accounting at all
  # before this change).
  defp reserve_active_runs(capacity, runs) do
    runs
    |> Enum.filter(&(&1.status == :running))
    |> Enum.reduce(capacity, fn run, cap -> reserve_slot(cap, run) end)
  end

  # Reuses Relay.Runs.Scheduler.take_slot/3 — the pure planner's own greedy
  # placement arithmetic — instead of a second copy, so this subtraction can
  # never drift out of sync with how the planner actually placed the run.
  # `:none` (nothing to take, e.g. capacity already fully spent) leaves the
  # snapshot unchanged rather than raising.
  #
  # Always targets `:any`, even for `:exclusive` runs: executor-affinity pinning
  # is unimplemented (`pinned_executor_id` is always nil — RLY-139), so a
  # `{:pinned, nil}` target would be permanently unfree and this debit would be
  # a silent no-op — exactly the isolation class where an unaccounted running
  # run is most damaging (two exclusive runs sharing one worktree). Debiting
  # greedily may charge the wrong executor's slot, but it keeps the aggregate
  # slot count correct, which is what this accounting exists to protect. This
  # mirrors `Relay.Runs.Scheduler.place_fresh/4`, which already places every
  # fresh pull — exclusive included — against `:any`.
  defp reserve_slot(cap, %{isolation: nil}), do: cap

  defp reserve_slot(cap, run) do
    case Scheduler.take_slot(cap, run.isolation, :any) do
      :none -> cap
      {_executor_id, updated} -> updated
    end
  end

  defp stage_snap(stage) do
    %{id: stage.id, position: stage.position, parent_id: stage.parent_id, wip_limit: stage.wip_limit}
  end

  defp card_snap(card, board) do
    %{
      id: card.id,
      ref: Cards.ref(board, card),
      stage_id: card.stage_id,
      status: card.status,
      active_owner: Cards.active_owner_type(card),
      position: card.position
    }
  end

  defp flow_snap(flow) do
    %{
      key: flow.key,
      pulls_from_stage_id: flow.pulls_from_stage_id,
      works_in_stage_id: flow.works_in_stage_id,
      isolation: flow.isolation
    }
  end

  # --- the scheduler-owned ready <-> queued marking ---

  defp apply_marking(plan, cards_by_id) do
    Enum.each(plan.to_queue, &set_status(cards_by_id, &1, :queued))
    Enum.each(plan.to_unqueue, &set_status(cards_by_id, &1, :ready))
    :ok
  end

  # :queued/:ready are valid in the pulls-from stage (queue/done), so a plain set_status is safe.
  # Skip a no-op write (already at the target status) — set_status/3 re-broadcasts unconditionally,
  # which would re-trigger this reconcile in a loop.
  defp set_status(cards_by_id, card_id, status) do
    case Map.get(cards_by_id, card_id) do
      nil -> :ok
      %{status: ^status} -> :ok
      card -> Cards.set_status(card, %{status: status})
    end
  end
end
