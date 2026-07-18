defmodule Relay.Runs.SchedulerTest do
  use ExUnit.Case, async: true

  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Plan
  alias Relay.Runs.Scheduler.Snapshot

  # --- fixture builders (plain maps, matching the Snapshot field shapes) ---

  defp snap(fields) do
    struct(Snapshot, fields)
  end

  defp stage(id, opts \\ []) do
    %{
      id: id,
      position: Keyword.get(opts, :position, id),
      parent_id: Keyword.get(opts, :parent_id),
      wip_limit: Keyword.get(opts, :wip_limit)
    }
  end

  defp card(id, stage_id, opts \\ []) do
    %{
      id: id,
      ref: "RLY-#{id}",
      stage_id: stage_id,
      status: Keyword.get(opts, :status, :ready),
      active_owner: Keyword.get(opts, :active_owner),
      position: Keyword.get(opts, :position, id)
    }
  end

  defp flow(key, pulls_from, works_in, opts \\ []) do
    %{
      key: key,
      pulls_from_stage_id: pulls_from,
      works_in_stage_id: works_in,
      isolation: Keyword.get(opts, :isolation, :shared_clean)
    }
  end

  defp run(id, card_id, opts \\ []) do
    %{
      id: id,
      card_id: card_id,
      status: Keyword.get(opts, :status, :parked),
      flow_key: Keyword.get(opts, :flow_key, "f"),
      isolation: Keyword.get(opts, :isolation, :shared_clean),
      pinned_executor_id: Keyword.get(opts, :pinned_executor_id)
    }
  end

  # one executor with n free shared_clean and m free exclusive slots
  defp cap(entries), do: Map.new(entries)
  defp slots(shared, excl), do: %{shared_clean: shared, exclusive: excl}

  # The real board shape: Next up(1) → Spec(2) → Spec:Done(3) → Plan(4).
  defp spec_and_plan_stages do
    [stage(1, position: 1), stage(2, position: 2), stage(3, position: 3), stage(4, position: 4)]
  end

  defp spec_and_plan_flows do
    [flow("spec", 1, 2, isolation: :shared_clean), flow("plan", 3, 4, isolation: :shared_clean)]
  end

  describe "fresh pulls" do
    test "pulls a ready card onto a named executor, consuming its slot" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:start, 10, "f", 7}], to_queue: [], to_unqueue: []} =
               Scheduler.plan(s)
    end

    test "pulls in card position order" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1, position: 2), card(11, 1, position: 1)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(2, 0)}])
        )

      assert %Plan{dispatches: [{:start, 11, "f", 7}, {:start, 10, "f", 7}]} = Scheduler.plan(s)
    end

    test "human-owned and needs_input cards are skipped" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [
            card(10, 1, active_owner: :human),
            card(11, 1, status: :needs_input),
            card(12, 1, active_owner: :ai)
          ],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(3, 0)}])
        )

      assert %Plan{dispatches: [{:start, 12, "f", 7}]} = Scheduler.plan(s)
    end
  end

  describe "priority: rightmost works-in first, resume before fresh" do
    test "processes flows by works-in stage position, descending" do
      # flow B works in stage 4 (rightmost) → its fresh pull wins the only slot
      s =
        snap(
          stages: [stage(1), stage(2, position: 2), stage(3, position: 3), stage(4, position: 4)],
          cards: [card(10, 1), card(20, 3)],
          flows: [flow("a", 1, 2), flow("b", 3, 4)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:start, 20, "b", 7}], to_queue: [10]} = Scheduler.plan(s)
    end

    test "a resumable parked run is dispatched before a fresh pull of the same flow" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1), card(20, 2, status: :working)],
          flows: [flow("f", 1, 2)],
          runs: [run(99, 20)],
          capacity: cap([{7, slots(1, 0)}])
        )

      # only one slot → the resume takes it, the fresh card is capacity-queued
      assert %Plan{dispatches: [{:resume, 99, 7}], to_queue: [10]} = Scheduler.plan(s)
    end
  end

  # RLY-138 / W12: the first time two flows are enabled at once. Spec and Plan are both
  # :shared_clean, so from the Plan cutover they draw from ONE per-isolation-class budget
  # (Capacity keys executor_id => %{shared_clean: n, exclusive: n} — never per flow). Combined
  # with rightmost-works_in-first (scheduler.ex:38-45), Plan preempts Spec for shared slots.
  # That is intended WIP discipline — drain the right of the board first — and these cases pin
  # it as a decision rather than an emergent surprise on a scarce-capacity day.
  describe "two flows sharing one shared_clean budget (spec + plan)" do
    test "with one shared slot, the Plan card preempts the Spec card" do
      # Same shape as "processes flows by works-in stage position, descending" above (4 stages,
      # 2 cards, 1 slot) — this instance names the real board's spec/plan flows specifically, so
      # a regression there reads as "Plan lost its board seat" rather than an abstract flow "b".
      s =
        snap(
          stages: spec_and_plan_stages(),
          # 10 sits in Next up (spec's pulls_from); 20 sits in Spec:Done (plan's pulls_from)
          cards: [card(10, 1), card(20, 3)],
          flows: spec_and_plan_flows(),
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:start, 20, "plan", 7}], to_queue: [10], to_unqueue: []} =
               Scheduler.plan(s)
    end

    test "with two shared slots, both flows dispatch once and the budget is spent, not double-spent" do
      s =
        snap(
          stages: spec_and_plan_stages(),
          # a third eligible card (11) sits behind 10 in Next up
          cards: [card(10, 1, position: 1), card(11, 1, position: 2), card(20, 3)],
          flows: spec_and_plan_flows(),
          capacity: cap([{7, slots(2, 0)}])
        )

      assert %Plan{dispatches: [{:start, 20, "plan", 7}, {:start, 10, "spec", 7}], to_queue: [11]} =
               Scheduler.plan(s)
    end

    test "all eligible cards across both flows dispatch when capacity is ample, in rightmost-flow-first order" do
      # 3 slots, 3 eligible cards spread across the two flows → nothing is scarce, so this does
      # NOT distinguish a shared budget from a per-flow one (see the 2-slot/3-card case above for
      # that). What it pins is dispatch order under a real multi-flow snapshot: plan (rightmost
      # works-in) goes first, then spec in card order.
      s =
        snap(
          stages: spec_and_plan_stages(),
          cards: [card(10, 1, position: 1), card(11, 1, position: 2), card(20, 3)],
          flows: spec_and_plan_flows(),
          capacity: cap([{7, slots(3, 0)}])
        )

      assert %Plan{
               dispatches: [{:start, 20, "plan", 7}, {:start, 10, "spec", 7}, {:start, 11, "spec", 7}],
               to_queue: []
             } = Scheduler.plan(s)
    end

    test "a parked Plan run resumes ahead of a fresh Spec pull for the one shared slot" do
      s =
        snap(
          stages: spec_and_plan_stages(),
          cards: [card(10, 1), card(20, 4, status: :working)],
          flows: spec_and_plan_flows(),
          runs: [run(99, 20, flow_key: "plan", isolation: :shared_clean)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:resume, 99, 7}], to_queue: [10]} = Scheduler.plan(s)
    end

    test "exclusive capacity is a separate budget and is not consumed by the shared flows" do
      # Code is :exclusive; a full shared_clean budget must not starve it, nor vice versa.
      s =
        snap(
          stages: spec_and_plan_stages() ++ [stage(5, position: 5), stage(6, position: 6)],
          cards: [card(10, 1), card(20, 3), card(30, 5)],
          flows: spec_and_plan_flows() ++ [flow("code", 5, 6, isolation: :exclusive)],
          capacity: cap([{7, slots(1, 1)}])
        )

      assert %Plan{dispatches: dispatches, to_queue: [10]} = Scheduler.plan(s)
      assert {:start, 30, "code", 7} in dispatches
      assert {:start, 20, "plan", 7} in dispatches
      assert length(dispatches) == 2
    end
  end

  describe "resume rules" do
    test "a parked run whose card just left :needs_input resumes (criterion 3)" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(20, 2, status: :working)],
          flows: [flow("f", 1, 2)],
          runs: [run(99, 20)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:resume, 99, 7}]} = Scheduler.plan(s)
    end

    test "a parked run whose card is still :needs_input stays parked" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(20, 2, status: :needs_input)],
          flows: [flow("f", 1, 2)],
          runs: [run(99, 20)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: []} = Scheduler.plan(s)
    end

    test "a parked run whose card is human-owned stays parked" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(20, 2, status: :working, active_owner: :human)],
          flows: [flow("f", 1, 2)],
          runs: [run(99, 20)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: []} = Scheduler.plan(s)
    end

    test "resume counts a card in a sub-lane of the works-in stage" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2), stage(3, position: 3, parent_id: 2)],
          cards: [card(20, 3, status: :working)],
          flows: [flow("f", 1, 2)],
          runs: [run(99, 20)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:resume, 99, 7}]} = Scheduler.plan(s)
    end
  end

  describe "executor affinity (exclusive)" do
    test "an exclusive resume parks when its pinned executor has no free exclusive slot" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(20, 2, status: :working)],
          flows: [flow("f", 1, 2, isolation: :exclusive)],
          runs: [run(99, 20, isolation: :exclusive, pinned_executor_id: 5)],
          # executor 5 is full on exclusive; executor 7 has room but is NOT the pin
          capacity: cap([{5, slots(0, 0)}, {7, slots(0, 1)}])
        )

      assert %Plan{dispatches: []} = Scheduler.plan(s)
    end

    test "an exclusive resume goes only to its pinned executor when it has a slot" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(20, 2, status: :working)],
          flows: [flow("f", 1, 2, isolation: :exclusive)],
          runs: [run(99, 20, isolation: :exclusive, pinned_executor_id: 5)],
          capacity: cap([{5, slots(0, 1)}, {7, slots(0, 1)}])
        )

      assert %Plan{dispatches: [{:resume, 99, 5}]} = Scheduler.plan(s)
    end

    test "fresh exclusive work is placed greedily on any executor with a free exclusive slot" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1)],
          flows: [flow("f", 1, 2, isolation: :exclusive)],
          # executor 5 exclusive-full, executor 7 has a slot → greedy lands on 7
          capacity: cap([{5, slots(9, 0)}, {7, slots(0, 1)}])
        )

      assert %Plan{dispatches: [{:start, 10, "f", 7}]} = Scheduler.plan(s)
    end
  end

  describe "WIP limits" do
    test "WIP counts the works-in column plus its sub-lanes" do
      # works-in stage 2 has wip_limit 2; one card sits in stage 2, one in its sub-lane 3 →
      # column already at 2 → no room, fresh card stays :ready (WIP-blocked, not queued)
      s =
        snap(
          stages: [
            stage(1),
            stage(2, position: 2, wip_limit: 2),
            stage(3, position: 3, parent_id: 2)
          ],
          cards: [card(10, 1), card(30, 2, status: :working), card(31, 3, status: :working)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(5, 0)}])
        )

      assert %Plan{dispatches: [], to_queue: [], to_unqueue: []} = Scheduler.plan(s)
    end

    test "fresh pulls consume WIP so one pass never exceeds the limit" do
      # limit 2, column empty → at most 2 fresh even with capacity and cards for 3
      s =
        snap(
          stages: [stage(1), stage(2, position: 2, wip_limit: 2)],
          cards: [card(10, 1, position: 1), card(11, 1, position: 2), card(12, 1, position: 3)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(5, 0)}])
        )

      assert %Plan{dispatches: [{:start, 10, "f", 7}, {:start, 11, "f", 7}], to_queue: []} =
               Scheduler.plan(s)
    end
  end

  describe "capacity budget" do
    test "no over-dispatch: capacity is consumed per decision" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1, position: 1), card(11, 1, position: 2)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(1, 0)}])
        )

      # only one shared_clean slot → one start, the other card is capacity-queued
      assert %Plan{dispatches: [{:start, 10, "f", 7}], to_queue: [11]} = Scheduler.plan(s)
    end

    test "greedy fresh placement spreads across executors in id order" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1, position: 1), card(11, 1, position: 2)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(1, 0)}, {3, slots(1, 0)}])
        )

      # executor ids ascending: 3 fills first, then 7
      assert %Plan{dispatches: [{:start, 10, "f", 3}, {:start, 11, "f", 7}]} = Scheduler.plan(s)
    end
  end

  describe "to_queue / to_unqueue reconciliation" do
    test "a WIP-had-room but capacity-blocked card is queued" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(0, 0)}])
        )

      assert %Plan{dispatches: [], to_queue: [10], to_unqueue: []} = Scheduler.plan(s)
    end

    test "an already-:queued card whose flow was disabled is unqueued" do
      # no enabled flows reference stage 1 → the queued card resets to :ready
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1, status: :queued)],
          flows: [],
          capacity: cap([])
        )

      assert %Plan{dispatches: [], to_queue: [], to_unqueue: [10]} = Scheduler.plan(s)
    end

    test "a :queued card that now dispatches is neither re-queued nor unqueued" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2)],
          cards: [card(10, 1, status: :queued)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(1, 0)}])
        )

      assert %Plan{dispatches: [{:start, 10, "f", 7}], to_queue: [], to_unqueue: []} =
               Scheduler.plan(s)
    end

    test "a WIP-blocked :queued card unqueues (queued means capacity-blocked, not WIP-blocked)" do
      s =
        snap(
          stages: [stage(1), stage(2, position: 2, wip_limit: 1)],
          cards: [card(10, 1, status: :queued), card(30, 2, status: :working)],
          flows: [flow("f", 1, 2)],
          capacity: cap([{7, slots(5, 0)}])
        )

      assert %Plan{dispatches: [], to_queue: [], to_unqueue: [10]} = Scheduler.plan(s)
    end
  end
end
