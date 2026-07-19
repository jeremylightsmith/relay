defmodule Relay.Runs.Scheduler do
  @moduledoc """
  The pure dispatch core (ADR 0006 / RLY-133) — the server-side heir to
  `bin/relay`'s `find_all_ready`. `plan/1` takes a `Snapshot` and returns a
  `Plan`: an ordered list of `{:resume, ...}` / `{:start, ...}` decisions plus
  the `ready ↔ queued` reconciliation. No processes, no DB — every ported rule
  unit-tests directly.

  Ported semantics: process enabled flows **rightmost works-in stage first**
  (by stage `position`, descending — not config order); within a flow, resume
  parked runs before pulling fresh; WIP limits count a column **plus its
  sub-lanes**; `:needs_input` cards are skipped; human-owned cards are off-limits
  (ADR 0004); capacity and WIP are consumed as decisions are made, so a single
  pass never over-dispatches. Extensions: every decision names an executor
  (capacity consumed on that executor's isolation class); `exclusive` runs are
  pinned to their affine executor (absolute — never reassigned mid-run).
  """

  alias Relay.Runs.Scheduler.Plan
  alias Relay.Runs.Scheduler.Snapshot

  @spec plan(Snapshot.t()) :: Plan.t()
  def plan(%Snapshot{} = snapshot) do
    stage_by_id = Map.new(snapshot.stages, &{&1.id, &1})
    children = children_index(snapshot.stages)
    cards_by_stage = Enum.group_by(snapshot.cards, & &1.stage_id)
    card_by_id = Map.new(snapshot.cards, &{&1.id, &1})
    run_by_card = Map.new(snapshot.runs, &{&1.card_id, &1})

    acc0 = %{
      capacity: snapshot.capacity,
      decided: MapSet.new(),
      wip_extra: %{},
      dispatches: [],
      to_queue: []
    }

    acc =
      snapshot.flows
      |> Enum.sort_by(&works_in_position(&1, stage_by_id), :desc)
      |> Enum.reduce(acc0, fn flow, acc ->
        acc
        |> resume_runs(flow, snapshot.runs, children, card_by_id)
        |> fresh_pulls(flow, stage_by_id, children, cards_by_stage, run_by_card)
      end)

    %Plan{
      dispatches: acc.dispatches,
      to_queue: acc.to_queue,
      to_unqueue: unqueue(snapshot.cards, acc.to_queue, acc.dispatches, run_by_card)
    }
  end

  # --- flow ordering ---

  defp works_in_position(flow, stage_by_id) do
    case stage_by_id[flow.works_in_stage_id] do
      nil -> -1
      stage -> stage.position
    end
  end

  # --- resume parked runs whose card sits in this flow's works-in stage (or a sub-lane) ---

  defp resume_runs(acc, flow, runs, children, card_by_id) do
    lane_ids = lane_ids(flow.works_in_stage_id, children)

    runs
    |> Enum.filter(fn run ->
      card = card_by_id[run.card_id]
      run.status == :parked and card != nil and card.stage_id in lane_ids
    end)
    |> Enum.sort_by(&card_sort_key(card_by_id[&1.card_id]))
    |> Enum.reduce(acc, fn run, acc ->
      card = card_by_id[run.card_id]

      cond do
        MapSet.member?(acc.decided, run.card_id) -> acc
        card.active_owner == :human -> acc
        card.status == :needs_input -> acc
        true -> maybe_resume(acc, run)
      end
    end)
  end

  defp maybe_resume(acc, run) do
    case take_slot(acc.capacity, run.isolation, executor_target(run)) do
      :none ->
        acc

      {executor_id, capacity} ->
        %{
          acc
          | capacity: capacity,
            decided: MapSet.put(acc.decided, run.card_id),
            dispatches: acc.dispatches ++ [{:resume, run.id, executor_id}]
        }
    end
  end

  # exclusive resumes are pinned; every other placement is greedy.
  defp executor_target(%{isolation: :exclusive, pinned_executor_id: eid}), do: {:pinned, eid}
  defp executor_target(_run), do: :any

  # --- then pull fresh from this flow's pulls-from stage ---

  defp fresh_pulls(acc, flow, stage_by_id, children, cards_by_stage, run_by_card) do
    works_in = flow.works_in_stage_id
    wip_limit = wip_limit(stage_by_id, works_in)
    base_used = used(children, cards_by_stage, works_in)

    cards_by_stage
    |> Map.get(flow.pulls_from_stage_id, [])
    |> Enum.sort_by(&card_sort_key/1)
    |> Enum.reduce_while(acc, fn card, acc ->
      cond do
        not fresh_eligible?(card, acc.decided, run_by_card) ->
          {:cont, acc}

        wip_full?(wip_limit, base_used, Map.get(acc.wip_extra, works_in, 0)) ->
          # WIP full: stop pulling fresh for this flow; remaining stay :ready (not queued).
          {:halt, acc}

        true ->
          {:cont, place_fresh(acc, card, flow, works_in)}
      end
    end)
  end

  defp place_fresh(acc, card, flow, works_in) do
    case take_slot(acc.capacity, flow.isolation, :any) do
      :none ->
        # WIP had room but no capacity → queue, keep scanning (do NOT consume WIP).
        %{acc | to_queue: acc.to_queue ++ [card.id]}

      {executor_id, capacity} ->
        %{
          acc
          | capacity: capacity,
            decided: MapSet.put(acc.decided, card.id),
            wip_extra: Map.update(acc.wip_extra, works_in, 1, &(&1 + 1)),
            dispatches: acc.dispatches ++ [{:start, card.id, flow.key, executor_id}]
        }
    end
  end

  defp fresh_eligible?(card, decided, run_by_card) do
    card.active_owner != :human and
      card.status in [:ready, :queued] and
      not Map.has_key?(run_by_card, card.id) and
      not MapSet.member?(decided, card.id)
  end

  # --- WIP accounting (column + sub-lanes, mirrors `used/1` in bin/relay) ---

  defp lane_ids(stage_id, children), do: [stage_id | Map.get(children, stage_id, [])]

  defp used(children, cards_by_stage, stage_id) do
    stage_id
    |> lane_ids(children)
    |> Enum.map(&length(Map.get(cards_by_stage, &1, [])))
    |> Enum.sum()
  end

  defp wip_limit(stage_by_id, stage_id) do
    case stage_by_id[stage_id] do
      nil -> nil
      stage -> stage.wip_limit
    end
  end

  defp wip_full?(nil, _base, _extra), do: false
  defp wip_full?(limit, base, extra), do: base + extra >= limit

  # --- capacity consumption ---

  @doc """
  Greedy slot placement: finds an executor with a free slot of `class` (the
  lowest-id executor first for `:any`; the affine executor only for
  `{:pinned, executor_id}`) and decrements it. Returns `{executor_id, updated_capacity}`
  or `:none` when nothing is free. Public because `Relay.Runs.Scheduler.Server`
  reuses this exact arithmetic to debit capacity for in-flight `:running` runs
  (the B3 accounting fix) — the two calculations must never diverge, since the
  server's subtraction is a re-derivation of a placement this function made on
  an earlier beat.
  """
  @spec take_slot(map(), atom(), :any | {:pinned, term()}) :: {term(), map()} | :none
  def take_slot(capacity, class, :any) do
    capacity
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&free?(capacity, &1, class))
    |> consume(capacity, class)
  end

  def take_slot(capacity, class, {:pinned, executor_id}) do
    if free?(capacity, executor_id, class),
      do: consume(executor_id, capacity, class),
      else: :none
  end

  defp consume(nil, _capacity, _class), do: :none

  defp consume(executor_id, capacity, class) do
    updated =
      Map.update!(capacity, executor_id, fn slots ->
        Map.update(slots, class, 0, &(&1 - 1))
      end)

    {executor_id, updated}
  end

  defp free?(capacity, executor_id, class) do
    case Map.get(capacity, executor_id) do
      nil -> false
      slots -> Map.get(slots, class, 0) > 0
    end
  end

  # --- to_unqueue: currently :queued cards no longer capacity-blocked and not dispatched ---

  defp unqueue(cards, to_queue, dispatches, run_by_card) do
    queued_now = MapSet.new(to_queue)
    dispatched = dispatched_card_ids(dispatches, run_by_card)

    for card <- cards,
        card.status == :queued,
        not MapSet.member?(queued_now, card.id),
        not MapSet.member?(dispatched, card.id),
        do: card.id
  end

  defp dispatched_card_ids(dispatches, run_by_card) do
    card_by_run = Map.new(run_by_card, fn {card_id, run} -> {run.id, card_id} end)

    Enum.reduce(dispatches, MapSet.new(), fn
      {:start, card_id, _flow_key, _executor_id}, acc ->
        MapSet.put(acc, card_id)

      {:resume, run_id, _executor_id}, acc ->
        case Map.get(card_by_run, run_id) do
          nil -> acc
          card_id -> MapSet.put(acc, card_id)
        end
    end)
  end

  # --- explain: why a given card is (not) dispatchable (RLY-177) ---

  @doc """
  The diagnosis sibling of `plan/1`: why `card_id` is or is not dispatchable on this
  snapshot. Deliberately lives in this module and reuses `plan/1`'s own decision plus the
  shared predicates (`fresh_eligible?/3`, `wip_full?/3`, `used/3`) — a separate
  reimplementation would silently drift from the scheduler it claims to explain, which is
  worse than no diagnosis at all (RLY-177).

  `:dispatchable` is decided by running `plan/1` itself, never re-derived; only the
  *reason* for a non-dispatch is walked, in the same order `plan/1` excludes cards.
  Returns `%{verdict, detail, evidence}`; `detail` is the human sentence `relay why`
  prints. Verdicts needing DB state beyond the snapshot (`:run_failed`, `:job_stranded`)
  are layered on by `Relay.Runs.diagnose/3`.
  """
  @spec explain(Snapshot.t(), term()) :: %{verdict: atom(), detail: String.t(), evidence: map()}
  def explain(%Snapshot{} = snapshot, card_id) do
    case Enum.find(snapshot.cards, &(&1.id == card_id)) do
      nil -> verdict(:unknown_card, "No card with id #{inspect(card_id)} is on this board.", %{})
      card -> do_explain(snapshot, card)
    end
  end

  defp do_explain(snapshot, card) do
    run = Enum.find(snapshot.runs, &(&1.card_id == card.id))
    flow = Enum.find(snapshot.flows, &(&1.pulls_from_stage_id == card.stage_id))
    evidence = evidence(snapshot, card, run, flow)

    cond do
      dispatched?(snapshot, card) ->
        verdict(:dispatchable, "This card would dispatch on the scheduler's next tick.", evidence)

      card.active_owner == :human ->
        verdict(:owned_by_human, "A human holds the baton on this card, so no flow will pick it up.", evidence)

      card.status == :needs_input ->
        verdict(:blocked_on_input, "This card is waiting on a human answer (status needs_input).", evidence)

      run != nil ->
        run_verdict(run, evidence)

      flow == nil ->
        verdict(
          :no_enabled_flow,
          "There is no enabled flow that pulls from this card's stage, so nothing will ever pick it up.",
          evidence
        )

      not fresh_eligible?(card, MapSet.new(), %{}) ->
        verdict(
          :not_eligible,
          "The #{flow.key} flow pulls from this card's stage, but the card's status is " <>
            "#{card.status} — only ready or queued cards are pulled.",
          evidence
        )

      wip_full?(evidence.wip_limit, evidence.wip_used, 0) ->
        verdict(
          :wip_full,
          "The #{flow.key} flow's works-in column is at its WIP limit " <>
            "(#{evidence.wip_used}/#{evidence.wip_limit}), so it is not pulling anything new.",
          evidence
        )

      true ->
        verdict(
          :awaiting_capacity,
          "The #{flow.key} flow would dispatch this card, but no executor is advertising a free " <>
            "#{flow.isolation} slot — nothing is connected to run it.",
          evidence
        )
    end
  end

  defp run_verdict(%{status: :parked} = run, evidence) do
    verdict(
      :awaiting_capacity,
      "Run #{run.id} is parked and waiting for an executor with a free #{run.isolation} slot.",
      evidence
    )
  end

  defp run_verdict(run, evidence), do: verdict(:run_active, "Run #{run.id} is live and working.", evidence)

  # `:dispatchable` is plan/1's own answer, not a re-derivation — this is the whole
  # anti-drift property the agreement test pins.
  defp dispatched?(snapshot, card) do
    plan = plan(snapshot)
    run_ids = for r <- snapshot.runs, r.card_id == card.id, do: r.id

    Enum.any?(plan.dispatches, fn
      {:start, card_id, _flow_key, _executor_id} -> card_id == card.id
      {:resume, run_id, _executor_id} -> run_id in run_ids
    end)
  end

  defp evidence(snapshot, card, run, flow) do
    stage_by_id = Map.new(snapshot.stages, &{&1.id, &1})
    children = children_index(snapshot.stages)
    cards_by_stage = Enum.group_by(snapshot.cards, & &1.stage_id)
    works_in = flow && flow.works_in_stage_id

    %{
      card_id: card.id,
      card_ref: card.ref,
      card_status: card.status,
      stage_id: card.stage_id,
      active_owner: card.active_owner,
      flow_key: flow && flow.key,
      isolation: flow && flow.isolation,
      capacity: snapshot.capacity,
      run_id: run && run.id,
      run_status: run && run.status,
      # Filled in by Relay.Runs.diagnose/3 — the Snapshot's run maps carry no
      # current_node (snapshot.ex:44-51); only the DB row has it.
      current_node: nil,
      wip_limit: works_in && wip_limit(stage_by_id, works_in),
      wip_used: works_in && used(children, cards_by_stage, works_in)
    }
  end

  defp verdict(verdict, detail, evidence), do: %{verdict: verdict, detail: detail, evidence: evidence}

  # --- misc ---

  defp children_index(stages) do
    Enum.reduce(stages, %{}, fn stage, acc ->
      if stage.parent_id,
        do: Map.update(acc, stage.parent_id, [stage.id], &[stage.id | &1]),
        else: acc
    end)
  end

  defp card_sort_key(nil), do: {0, 0}
  defp card_sort_key(card), do: {card.position, card.id}
end
