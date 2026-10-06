defmodule Relay.Runs.Scheduler.Server do
  @moduledoc """
  The per-board event-driven shell (ADR 0006 / RLY-133). Assembles a
  `Relay.Runs.Scheduler.Snapshot` from the DB + `Relay.Runs.Capacity`, calls the
  pure `Relay.Runs.Scheduler.plan/1`, delegates each dispatch to the injected
  `Relay.Runs.Scheduler.Engine`, and applies the `ready ↔ queued` marking via
  `Relay.Cards` (the only card writes the scheduler owns — it never writes a `Run`'s
  **status** or moves cards into works-in). It also hands `plan/1`'s `refusals` to
  `Relay.Runs.record_resume_refusals/4` (RE297), which stamps the refusal clock on the run
  rows — a fact, not a status, and owned by `Relay.Runs` exactly as dispatch is owned by the
  engine and marking by `Relay.Cards`.

  A reconcile is cheap by construction (RE402): the snapshot is five narrow reads (stages,
  card projection, active runs, runners, enabled flows); `record_resume_refusals/4` decides
  what to clear from the snapshot's runs instead of a SELECT; and marking loads a `%Card{}`
  only for a card whose status actually changes. A steady-state reconcile is ≤ 5 queries.

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
  alias Schemas.Board

  require Logger

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
    Relay.Runs.Instance.adopt_callers(opts)
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
  def handle_info({:runner_capacity_changed, _runner_id}, state), do: {:noreply, mark_dirty(state)}
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

  # A raise here must stay on this board (RE387). Uncaught, it crashed the server, whose boot
  # reconcile raised again on every restart — blowing the shared SchedulerSupervisor's restart
  # intensity and taking every board's scheduler down with it. Logged and retried on the next
  # event or tick instead.
  defp reconcile(state) do
    do_reconcile(state)
  catch
    kind, reason ->
      Logger.error(
        "scheduler reconcile failed for board #{state.board_id}: " <>
          Exception.format(kind, reason, __STACKTRACE__)
      )

      state
  end

  defp do_reconcile(state) do
    {snapshot, cards_by_id} = build_snapshot(state)
    plan = Scheduler.plan(snapshot)
    Enum.each(plan.dispatches, &dispatch(&1, state.engine))
    Relay.Runs.record_resume_refusals(state.board_id, plan.refusals, nil, snapshot.runs)
    apply_marking(plan, state.board_id, cards_by_id)
    state
  end

  defp dispatch({:start, card_id, flow_key, runner_id}, engine), do: engine.start_run(card_id, flow_key, runner_id)

  defp dispatch({:resume, run_id, runner_id}, engine), do: engine.resume_run(run_id, runner_id)

  # --- snapshot assembly ---

  @doc """
  Assembles the dispatch snapshot for `board_id` against `engine`, returning it alongside
  `cards_by_id` — card id → that card's `Snapshot.card` map (what `apply_marking/3` reads the
  current status from before it loads and writes a changed card).

  Five narrow reads (RE402): `Boards.list_scheduler_stages/1`, `Cards.list_scheduler_cards/2`
  (the projection, with `blocked_by` from the same predicate as `Cards.unmet_dependencies/2`),
  `engine.active_runs/1`, `Runs.list_board_runners/1` and `Flows.list_enabled_flow_snapshots/1`.

  Public because `Relay.Runs.diagnose/3` (RLY-177) must diagnose against **byte-for-byte
  the snapshot this server plans from** — including the `reserve_active_runs/2` debit for
  in-flight runs. A second assembly path would be a second source of truth.
  """
  def build_snapshot(board_id, engine) do
    stages = Boards.list_scheduler_stages(board_id)
    # RE93 — the ONE "is this card blocked" read (`blocked_by` on each card), done here where the
    # stage list is already in hand, so the pure planner never re-derives "which stage is
    # complete". Runs.diagnose/3 reuses this same function, so plan and explain cannot disagree.
    cards = Cards.list_scheduler_cards(board_id, Boards.top_level_done_stage_ids(stages))
    runs = engine.active_runs(board_id)
    runners = runner_snap(board_id)

    snapshot = %Snapshot{
      stages: Enum.map(stages, &stage_snap/1),
      cards: cards,
      flows: Relay.Flows.list_enabled_flow_snapshots(board_id),
      runs: runs,
      capacity: Capacity.snapshot() |> reserve_active_runs(runs) |> counting_capacity(runners),
      runners: runners
    }

    {snapshot, Map.new(cards, &{&1.id, &1})}
  end

  # Keep ONLY capacity entries whose runner is a counting (`Relay.Runs.counting_runner?/1` —
  # not `:gone`) runner of THIS board (RE338). An allow-list, not a deny-list: `Capacity` is a
  # global ETS store keyed by runner id across every board and never evicted, so an id this
  # board's `runners` map does not name — another board's runner, or an entry whose row is
  # gone — is dropped rather than passed through. Before this, another board's runner's free
  # slots reached `relay why`'s evidence AND `take_slot/3`, so the planner started runs no
  # runner on this board had room for. Every capacity key is therefore a runner the roster
  # (`Relay.Runs.list_runner_status/2`) names.
  #
  # A `:gone` runner's advertised capacity is void too — its slots died with the machine, and
  # the reaper has already requeued/parked its in-flight work. Applied AFTER
  # reserve_active_runs, so a not-yet-reaped :running run still debits the machine it's stuck
  # on before the machine leaves the map. Without this, an exclusive run pinned to a dead
  # machine oscillates forever — the scheduler keeps resuming it onto the lingering capacity
  # and the reaper keeps re-parking it (RLY-199) — and `explain/2` reports "dispatchable"
  # instead of naming the awaited machine.
  defp counting_capacity(capacity, runners) do
    Map.filter(capacity, fn {runner_id, _slots} ->
      case Map.fetch(runners, runner_id) do
        {:ok, entry} -> Relay.Runs.counting_runner?(entry)
        :error -> false
      end
    end)
  end

  # Reuses Relay.Runs.runner_outdated?/1 and runner_freshness/2 — the same truth the
  # runners view and the reaper read — so the scheduler's "outdated" can never disagree with
  # the roster's, and its live rate limit (RE320). `now` is read once for a consistent pass.
  defp runner_snap(board_id) do
    now = DateTime.utc_now()

    board_id
    |> Relay.Runs.list_board_runners()
    |> Map.new(&{&1.id, Relay.Runs.runner_snapshot_entry(&1, now)})
  end

  @doc "The app's configured engine — for callers with no injected one (e.g. `Runs.diagnose/3`)."
  def configured_engine, do: default_engine()

  defp build_snapshot(state), do: build_snapshot(state.board_id, state.engine)

  # A run that is :running is being worked on a runner right now, so it holds
  # one slot of its isolation class until it finishes — even if the runner's
  # next heartbeat hasn't yet reflected it. Subtract those held slots from the
  # advertised capacity before planning (parked runs hold no slot; the pure
  # planner's resume_runs consumes a slot only when it actually resumes one).
  #
  # NOTE (board-scoped vs. global): `runs` here is this board's active runs only
  # (`state.engine.active_runs(state.board_id)`), but `Capacity.snapshot/0` is
  # global — `counting_capacity/2` later narrows it to this board's runners (RE338), but one
  # physical machine registered on two boards is two runner rows advertising the same slots,
  # each debited only by the runs its own board's scheduler knows about. Two boards
  # dispatching to the same machine at once can each believe a slot is free. Tracked as a
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
  #
  # A pinned :exclusive run (RLY-199) debits its pinned runner via
  # `{:pinned, id}`, mirroring how resume_runs/2 will place its resume — so the
  # accounting charges the runner that actually holds the run's slot. If that
  # runner is absent from the capacity map (gone, or not yet re-advertised),
  # `take_slot` returns `:none` and we fall back to a greedy `:any` debit, which
  # keeps the AGGREGATE slot count correct (the property this accounting exists to
  # protect) even if it charges the wrong runner. An unpinned run (a fresh
  # pre-first-claim exclusive run, or any shared_clean run) debits `:any` directly,
  # matching `Relay.Runs.Scheduler.place_fresh/4`. `:none` on the fallback leaves the
  # snapshot unchanged rather than raising. A deleted-flow run (isolation nil) holds
  # no slot.
  defp reserve_slot(cap, %{isolation: nil}), do: cap

  defp reserve_slot(cap, %{pinned_runner_id: eid} = run) when not is_nil(eid) do
    case Scheduler.take_slot(cap, run.isolation, {:pinned, eid}) do
      :none -> debit_any(cap, run)
      {_runner_id, updated} -> updated
    end
  end

  defp reserve_slot(cap, run), do: debit_any(cap, run)

  defp debit_any(cap, run) do
    case Scheduler.take_slot(cap, run.isolation, :any) do
      :none -> cap
      {_runner_id, updated} -> updated
    end
  end

  defp stage_snap(stage) do
    %{id: stage.id, position: stage.position, parent_id: stage.parent_id, wip_limit: stage.wip_limit}
  end

  # --- the scheduler-owned ready <-> queued marking ---

  defp apply_marking(plan, board_id, cards_by_id) do
    Enum.each(plan.to_queue, &set_status(board_id, cards_by_id, &1, :queued))
    Enum.each(plan.to_unqueue, &set_status(board_id, cards_by_id, &1, :ready))
    :ok
  end

  # :queued/:ready are valid in the pulls-from stage (queue/done), so a plain set_status is safe.
  # Skip a no-op write (already at the target status, per the snapshot) — Cards.set_status/2
  # re-broadcasts unconditionally, which would re-trigger this reconcile in a loop. Only a card
  # that really changes is loaded (RE402); one gone since the snapshot is skipped.
  defp set_status(board_id, cards_by_id, card_id, status) do
    case Map.get(cards_by_id, card_id) do
      nil -> :ok
      %{status: ^status} -> :ok
      _changed -> write_status(board_id, card_id, status)
    end
  end

  defp write_status(board_id, card_id, status) do
    case Cards.get_card(%Board{id: board_id}, card_id) do
      nil -> :ok
      card -> Cards.set_status(card, %{status: status})
    end
  end
end
