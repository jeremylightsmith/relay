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

  defp take_slot(capacity, class, :any) do
    capacity
    |> Map.keys()
    |> Enum.sort()
    |> Enum.find(&free?(capacity, &1, class))
    |> consume(capacity, class)
  end

  defp take_slot(capacity, class, {:pinned, executor_id}) do
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
