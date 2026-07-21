defmodule Relay.Runs.SchedulerExplainTest do
  use ExUnit.Case, async: true

  alias Relay.Runs
  alias Relay.Runs.Scheduler
  alias Relay.Runs.Scheduler.Snapshot

  # Fixture builders mirror test/relay/runs/scheduler_test.exs:10-56 exactly, so a
  # snapshot that exercises plan/1 there exercises explain/2 here unchanged.
  defp snap(fields), do: struct(Snapshot, fields)

  defp stage(id, opts) do
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

  defp run(id, card_id, opts) do
    %{
      id: id,
      card_id: card_id,
      status: Keyword.get(opts, :status, :parked),
      flow_key: Keyword.get(opts, :flow_key, "f"),
      isolation: Keyword.get(opts, :isolation, :shared_clean),
      pinned_executor_id: Keyword.get(opts, :pinned_executor_id),
      pinned_executor_name: Keyword.get(opts, :pinned_executor_name),
      parked_reason: Keyword.get(opts, :parked_reason)
    }
  end

  defp slots(shared, excl), do: %{shared_clean: shared, exclusive: excl}

  defp exec(id, opts \\ []) do
    {id,
     %{
       name: Keyword.get(opts, :name, "e#{id}"),
       version: Keyword.get(opts, :version, 1),
       outdated: Keyword.get(opts, :outdated, false),
       freshness: Keyword.get(opts, :freshness, :fresh)
     }}
  end

  defp base(opts) do
    snap(
      stages: [stage(1, position: 1), stage(2, position: 2)],
      cards: Keyword.fetch!(opts, :cards),
      flows: Keyword.get(opts, :flows, []),
      runs: Keyword.get(opts, :runs, []),
      capacity: Keyword.get(opts, :capacity, %{})
    )
  end

  test "a card a flow would pull with free capacity is dispatchable" do
    s = base(cards: [card(10, 1)], flows: [flow("code", 1, 2)], capacity: %{"e1" => slots(1, 0)})

    assert %{verdict: :dispatchable} = Scheduler.explain(s, 10)
  end

  test "no enabled flow pulling from the card's stage names that reason" do
    s = base(cards: [card(10, 1)], capacity: %{"e1" => slots(1, 0)})

    assert %{verdict: :no_enabled_flow, detail: detail, evidence: evidence} = Scheduler.explain(s, 10)
    assert detail =~ "no enabled flow"
    assert evidence.flow_key == nil
  end

  test "a flow that would pull but no executor at all is no_executor" do
    s = base(cards: [card(10, 1)], flows: [flow("code", 1, 2)], capacity: %{})

    assert %{verdict: :no_executor, detail: detail, evidence: evidence} = Scheduler.explain(s, 10)
    assert detail =~ "no executor"
    assert evidence.flow_key == "code"
    assert evidence.capacity == %{}
  end

  test "a full works-in column is wip_full" do
    s =
      snap(
        stages: [stage(1, position: 1), stage(2, position: 2, wip_limit: 1)],
        cards: [card(10, 1), card(11, 2)],
        flows: [flow("code", 1, 2)],
        capacity: %{"e1" => slots(5, 0)}
      )

    assert %{verdict: :wip_full, evidence: %{wip_limit: 1, wip_used: 1}} = Scheduler.explain(s, 10)
  end

  test "a human-owned card is owned_by_human" do
    s =
      base(
        cards: [card(10, 1, active_owner: :human)],
        flows: [flow("code", 1, 2)],
        capacity: %{"e1" => slots(1, 0)}
      )

    assert %{verdict: :owned_by_human} = Scheduler.explain(s, 10)
  end

  test "a needs_input card is blocked_on_input" do
    s =
      base(
        cards: [card(10, 1, status: :needs_input)],
        flows: [flow("code", 1, 2)],
        capacity: %{"e1" => slots(1, 0)}
      )

    assert %{verdict: :blocked_on_input} = Scheduler.explain(s, 10)
  end

  test "a live run names its run id" do
    s =
      base(
        cards: [card(10, 2)],
        flows: [flow("code", 1, 2)],
        runs: [run(5, 10, status: :running)],
        capacity: %{"e1" => slots(1, 0)}
      )

    assert %{verdict: :run_active, evidence: %{run_id: 5}} = Scheduler.explain(s, 10)
  end

  test "a parked :executor_gone run is awaiting_capacity" do
    s =
      base(
        cards: [card(10, 2)],
        flows: [flow("code", 1, 2)],
        runs: [run(5, 10, status: :parked, parked_reason: :executor_gone)],
        # zero capacity, not slots(1, 0): with a free slot advertised the run would actually
        # resume on plan/1's next pass, making explain/2 correctly answer :dispatchable instead
        # (see "a flow that would pull but zero advertised capacity is awaiting_capacity" above
        # for the same zero-capacity pattern).
        capacity: %{}
      )

    assert %{verdict: :awaiting_capacity, evidence: %{run_id: 5}} = Scheduler.explain(s, 10)
  end

  test "a parked :executor_gone run pinned to a machine names that machine" do
    s =
      base(
        cards: [card(10, 2, status: :working)],
        flows: [flow("f", 1, 2, isolation: :exclusive)],
        runs: [
          run(5, 10,
            status: :parked,
            parked_reason: :executor_gone,
            isolation: :exclusive,
            pinned_executor_name: "exec-a"
          )
        ],
        capacity: %{}
      )

    assert %{verdict: :awaiting_capacity, detail: detail, evidence: evidence} = Scheduler.explain(s, 10)
    assert detail =~ ~s(executor "exec-a")
    assert detail =~ "exclusive affinity"
    assert evidence.pinned_executor_name == "exec-a"
  end

  test "a parked :needs_input run (already answered) is awaiting_listener_resume, not awaiting_capacity" do
    s =
      base(
        cards: [card(10, 2, status: :working)],
        flows: [flow("code", 1, 2)],
        runs: [run(5, 10, status: :parked, parked_reason: :needs_input)],
        capacity: %{"e1" => slots(1, 0)}
      )

    assert %{verdict: :awaiting_listener_resume, detail: detail, evidence: %{run_id: 5}} =
             Scheduler.explain(s, 10)

    assert detail =~ "Listener"
  end

  test "a card in a trigger stage with a non-pullable status is not_eligible, not no_enabled_flow" do
    s =
      base(
        cards: [card(10, 1, status: :in_review)],
        flows: [flow("code", 1, 2)],
        capacity: %{"e1" => slots(1, 0)}
      )

    assert %{verdict: :not_eligible, detail: detail} = Scheduler.explain(s, 10)
    assert detail =~ "in_review"
  end

  test "an unknown card id is reported, not raised" do
    assert %{verdict: :unknown_card} = Scheduler.explain(base(cards: []), 999)
  end

  describe "the terminal capacity branch (RLY-191)" do
    # A card a flow would pull, but no free slot — the branch that used to be one
    # undifferentiated :awaiting_capacity now splits on the roster.
    defp blocked(executors) do
      snap(
        stages: [stage(1, position: 1), stage(2, position: 2)],
        cards: [card(10, 1)],
        flows: [flow("code", 1, 2)],
        capacity: %{},
        executors: executors
      )
    end

    test "an empty roster is :no_executor, not :awaiting_capacity" do
      assert %{verdict: :no_executor, detail: detail} = Scheduler.explain(blocked(%{}), 10)
      assert detail =~ "no executor is connected"
    end

    test "every live executor outdated is :executor_outdated with the version pair" do
      execs = Map.new([exec(1, outdated: true, version: nil), exec(2, outdated: true, version: 0)])

      assert %{verdict: :executor_outdated, detail: detail, evidence: evidence} =
               Scheduler.explain(blocked(execs), 10)

      assert detail =~ "running old code"
      assert detail =~ "requires v#{Runs.min_executor_version()}"
      assert evidence.required_version == Runs.min_executor_version()
      assert %{name: _, version: nil} = Enum.find(evidence.running_versions, &(&1.version == nil))
      assert Enum.any?(evidence.running_versions, &(&1.version == 0))
    end

    test "a current-but-full roster stays :awaiting_capacity" do
      execs = Map.new([exec(1, outdated: false, version: 1, freshness: :fresh)])

      assert %{verdict: :awaiting_capacity, detail: detail} = Scheduler.explain(blocked(execs), 10)
      assert detail =~ "busy"
    end

    test "a roster whose only executor has gone silent is :no_executor" do
      execs = Map.new([exec(1, freshness: :gone)])

      assert %{verdict: :no_executor} = Scheduler.explain(blocked(execs), 10)
    end
  end

  describe "capacity_diagnosis/1" do
    test "returns the reason atom and the version evidence" do
      execs = Map.new([exec(1, outdated: true, version: 2)])
      s = snap(cards: [], executors: execs)

      assert {:executor_outdated, %{required_version: required, running_versions: [%{version: 2}]}} =
               Scheduler.capacity_diagnosis(s)

      assert required == Runs.min_executor_version()
      assert {:no_executor, _} = Scheduler.capacity_diagnosis(snap(cards: [], executors: %{}))

      assert {:executor_gone, _} =
               Scheduler.capacity_diagnosis(snap(cards: [], executors: Map.new([exec(1, freshness: :gone)])))

      assert {:awaiting_capacity, _} = Scheduler.capacity_diagnosis(snap(cards: [], executors: Map.new([exec(1)])))
    end
  end

  describe "agreement with plan/1" do
    # The anti-drift guard the spec requires: across a matrix of snapshots, every card
    # plan/1 dispatches must explain as :dispatchable, and every card it does not must
    # explain as something else.
    defp matrix do
      stages = [stage(1, position: 1), stage(2, position: 2, wip_limit: 2)]

      for cap <- [%{}, %{"e1" => slots(1, 0)}, %{"e1" => slots(5, 0)}],
          status <- [:ready, :queued, :working, :needs_input],
          owner <- [nil, :human],
          flows <- [[], [flow("code", 1, 2)]],
          runs <- [
            [],
            [run(5, 11, status: :running)],
            [run(5, 11, status: :parked, parked_reason: :executor_gone)],
            [run(5, 11, status: :parked, parked_reason: :needs_input)]
          ] do
        snap(
          stages: stages,
          cards: [card(10, 1, status: status, active_owner: owner), card(11, 2)],
          flows: flows,
          runs: runs,
          capacity: cap
        )
      end
    end

    test "explain/2 says dispatchable exactly when plan/1 dispatches" do
      for s <- matrix(), card <- s.cards do
        plan = Scheduler.plan(s)

        dispatched? =
          Enum.any?(plan.dispatches, fn
            {:start, card_id, _flow_key, _executor_id} ->
              card_id == card.id

            {:resume, run_id, _executor_id} ->
              Enum.any?(s.runs, &(&1.id == run_id and &1.card_id == card.id))
          end)

        %{verdict: verdict} = Scheduler.explain(s, card.id)

        assert dispatched? == (verdict == :dispatchable),
               "card #{card.id} dispatched?=#{dispatched?} but verdict=#{verdict}"
      end
    end
  end
end
