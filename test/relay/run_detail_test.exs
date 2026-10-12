defmodule Relay.RunDetailTest do
  use ExUnit.Case, async: true

  alias Relay.Runs
  alias Schemas.Flow

  # id + started_at are needed by Runs.last_node/2 for terminal runs (current_node nil).
  defp ne(node_key, attempt, outcome, attrs \\ %{}) do
    {duration_s, attrs} = Map.pop(attrs, :duration_s, 42)
    started = Map.get(attrs, :started_at, ~U[2026-07-20 00:00:00Z])
    finished = duration_s && DateTime.add(started, duration_s, :second)

    Map.merge(
      %{
        id: System.unique_integer([:positive]),
        node_key: node_key,
        attempt: attempt,
        outcome: outcome,
        detail: nil,
        cost: nil,
        started_at: started,
        finished_at: finished
      },
      attrs
    )
  end

  defp run(attrs),
    do:
      Map.merge(
        %{
          status: :running,
          flow_key: "code",
          flow_version: nil,
          current_node: "implement",
          started_at: ~U[2026-07-20 00:00:00Z],
          finished_at: nil,
          failure_detail: nil
        },
        attrs
      )

  defp code_flow do
    %Flow{
      nodes: [%{key: "implement", type: :agent}, %{key: "quality_review", type: :gate}],
      edges: [
        %{from: "start", on: nil, to: "implement", max_loops: nil},
        %{from: "implement", on: :succeeded, to: "quality_review", max_loops: nil},
        %{from: "quality_review", on: :failed, to: "implement", max_loops: 3},
        %{from: "quality_review", on: :succeeded, to: "done", max_loops: nil}
      ]
    }
  end

  # RE437 task 5's region flow: prep → fo ⇉ {a, b1 ⇄ b2} → fi → after → done.
  defp region_flow do
    %Flow{
      nodes: [
        %{key: "prep", type: :shell},
        %{key: "fo", type: :fan_out},
        %{key: "a", type: :shell},
        %{key: "b1", type: :agent},
        %{key: "b2", type: :agent},
        %{key: "fi", type: :fan_in},
        %{key: "after", type: :shell}
      ],
      edges: [
        %{from: "start", on: nil, to: "prep", max_loops: nil},
        %{from: "prep", on: :succeeded, to: "fo", max_loops: nil},
        %{from: "fo", on: nil, to: "a", max_loops: nil},
        %{from: "fo", on: nil, to: "b1", max_loops: nil},
        %{from: "a", on: :succeeded, to: "fi", max_loops: nil},
        %{from: "b1", on: :failed, to: "b2", max_loops: nil},
        %{from: "b2", on: :succeeded, to: "b1", max_loops: nil},
        %{from: "b1", on: :succeeded, to: "fi", max_loops: nil},
        %{from: "fi", on: :succeeded, to: "after", max_loops: nil},
        %{from: "after", on: :succeeded, to: "done", max_loops: nil}
      ]
    }
  end

  # A run with an open region: `fo` fanned out to `a` (branch 1) and `b1` (branch 2), both in flight.
  defp region_run(attrs \\ %{}) do
    run(
      Map.merge(
        %{
          status: :running,
          flow_key: "region",
          current_node: "fo",
          run_branches: [%{id: 1, state: :running}, %{id: 2, state: :running}],
          node_executions: [
            ne("prep", 1, :succeeded),
            ne("fo", 1, :succeeded),
            ne("a", 1, nil, %{run_branch_id: 1, duration_s: nil}),
            ne("b1", 1, nil, %{run_branch_id: 2, duration_s: nil})
          ]
        },
        attrs
      )
    )
  end

  defp node_rows(detail), do: Enum.filter(detail.timeline, &(&1.kind == :node))

  defp node_row(detail, key), do: Enum.find(node_rows(detail), &(&1.node_key == key))

  describe "run_detail/2 with an open fan-out region (RE437)" do
    test "every in-flight branch node is an active row, in execution order" do
      detail = Runs.run_detail(region_run(), region_flow())

      assert Enum.map(node_rows(detail), & &1.node_key) == ["prep", "fo", "a", "b1"]
      assert node_row(detail, "a").state == :active
      assert node_row(detail, "b1").state == :active
    end

    test "no synthetic active row is added for the fan_out the run's current_node names" do
      detail = Runs.run_detail(region_run(), region_flow())

      assert length(node_rows(detail)) == 4
      assert Enum.count(node_rows(detail), &(&1.node_key == "fo")) == 1
    end

    test "no synthetic active row for a control-node current_node even when every execution has settled" do
      for {current, nes} <- [
            {"fo", [ne("prep", 1, :succeeded), ne("fo", 1, :succeeded)]},
            {"fi", [ne("prep", 1, :succeeded), ne("fo", 1, :succeeded), ne("a", 1, :succeeded), ne("b1", 1, :succeeded)]}
          ] do
        detail = Runs.run_detail(region_run(%{current_node: current, node_executions: nes}), region_flow())

        assert Enum.map(node_rows(detail), & &1.node_key) == Enum.map(nes, & &1.node_key)
      end
    end

    test "control-node rows carry their type tag" do
      detail = Runs.run_detail(region_run(), region_flow())

      assert node_row(detail, "fo").type == :fan_out
    end

    test "a branch waiting on a human is paused while its running sibling stays active on a parked run" do
      r =
        region_run(%{
          status: :parked,
          run_branches: [%{id: 1, state: :parked}, %{id: 2, state: :running}],
          node_executions: [
            ne("prep", 1, :succeeded),
            ne("fo", 1, :succeeded),
            ne("a", 1, :needs_input, %{run_branch_id: 1}),
            ne("b1", 1, nil, %{run_branch_id: 2, duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, region_flow())

      assert node_row(detail, "a").state == :paused
      assert node_row(detail, "b1").state == :active
    end

    test "a parked run with no run_branches loaded keeps today's paused rows" do
      for branches <- [:absent, nil, %Ecto.Association.NotLoaded{}] do
        base = region_run(%{status: :parked})
        r = if branches == :absent, do: Map.delete(base, :run_branches), else: %{base | run_branches: branches}

        detail = Runs.run_detail(r, region_flow())

        assert node_row(detail, "a").state == :paused
        assert node_row(detail, "b1").state == :paused
      end
    end

    test "the pending tail lists the fan_in and what follows, never the fan_out or branch nodes" do
      detail = Runs.run_detail(region_run(), region_flow())

      assert %{kind: :pending, nodes: ["fi", "after"]} in detail.timeline
    end
  end

  describe "breaker_tripped?/1" do
    test "true only on the engine's circuit_breaker token" do
      assert Runs.breaker_tripped?(run(%{status: :failed, failure_detail: "circuit_breaker: repeated 3 times"}))

      assert Runs.breaker_tripped?(
               run(%{status: :failed, failure_detail: "The same failure repeated. (circuit_breaker: ...)"})
             )

      refute Runs.breaker_tripped?(run(%{status: :failed, failure_detail: "(no_route_for_outcome: fixit → failed)"}))
      refute Runs.breaker_tripped?(run(%{status: :failed, failure_detail: nil}))
      refute Runs.breaker_tripped?(run(%{status: :running}))
      refute Runs.breaker_tripped?(Map.delete(run(%{status: :failed}), :failure_detail))
    end

    test "attempts >= 3 does NOT fabricate a breaker" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          failure_detail: "(no_route_for_outcome: fixit → failed)",
          node_executions: [ne("q", 1, :failed), ne("q", 2, :failed), ne("q", 3, :failed)]
        })

      detail = Runs.run_detail(r, nil)
      refute detail.breaker_tripped?
    end
  end

  describe "run_detail/2 timeline" do
    test "review-failed loop emits a structured :loop row with max_loops, never resumed?" do
      r =
        run(%{
          node_executions: [
            ne("implement", 1, :succeeded),
            ne("quality_review", 1, :failed, %{detail: "no"}),
            ne("implement", 2, nil, %{duration_s: nil})
          ]
        })

      detail = Runs.run_detail(r, code_flow())

      loop = Enum.find(detail.timeline, &(&1.kind == :loop))
      assert loop == %{kind: :loop, from_node: "quality_review", to_node: "implement", attempt: 2, max_loops: 3}
      refute Enum.any?(detail.timeline, &(&1[:kind] == :node and &1[:resumed?]))
    end

    test "needs-input re-entry is the only state that sets resumed?" do
      r =
        run(%{
          flow_key: "spec",
          current_node: "brainstorm",
          node_executions: [ne("brainstorm", 1, :needs_input), ne("brainstorm", 2, nil, %{duration_s: nil})]
        })

      detail = Runs.run_detail(r, nil)

      assert Enum.any?(
               detail.timeline,
               &(&1.kind == :node and &1.node_key == "brainstorm" and &1.attempt == 2 and &1.resumed?)
             )
    end

    test "row_state maps outcome × run-status; partial? is flagged separately" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          node_executions: [ne("a", 1, :succeeded), ne("b", 1, :partial), ne("c", 1, :failed), ne("d", 1, nil)]
        })

      states =
        for row <- r.node_executions do
          Enum.find(Runs.run_detail(r, nil).timeline, &(&1[:node_key] == row.node_key))
        end

      assert Enum.map(states, & &1.state) == [:done, :done, :failed, :stopped]
      assert Enum.at(states, 1).partial?
    end

    test "synthetic active row appears when the run is between nodes" do
      r = run(%{status: :running, current_node: "quality_review", node_executions: [ne("implement", 1, :succeeded)]})
      detail = Runs.run_detail(r, code_flow())
      assert Enum.any?(detail.timeline, &(&1.kind == :node and &1.node_key == "quality_review" and &1.state == :active))
    end

    test "pending tail lists the unrun happy-path nodes" do
      r = run(%{status: :running, current_node: "implement", node_executions: []})
      detail = Runs.run_detail(r, code_flow())
      assert %{kind: :pending, nodes: ["quality_review"]} in detail.timeline
    end

    test "pending tail is empty for a terminal status, even with unrun happy-path nodes" do
      r = run(%{status: :done, current_node: "implement", node_executions: []})
      detail = Runs.run_detail(r, code_flow())
      refute Enum.any?(detail.timeline, &(&1.kind == :pending))
    end
  end

  describe "run_detail/2 scalars" do
    test "tripped node/repeats, last failure detail, totals, parked attempt" do
      r =
        run(%{
          status: :failed,
          current_node: nil,
          node_executions: [
            ne("implement", 1, :succeeded, %{duration_s: 100, cost: Decimal.new("0.90")}),
            ne("quality_review", 1, :failed, %{duration_s: 40, cost: Decimal.new("0.30"), detail: "same"}),
            ne("quality_review", 2, :failed, %{duration_s: 40, cost: Decimal.new("0.30"), detail: "same again"})
          ]
        })

      detail = Runs.run_detail(r, nil)

      assert detail.tripped_node == "quality_review"
      assert detail.tripped_repeats == 2
      assert detail.last_failure_detail == "same again"
      assert detail.totals == %{duration_s: 180, cost: Decimal.new("1.50"), nodes: 2, attempts: 3}
    end

    test "last_failure_detail names the parking :partial, not an earlier :failed (RE253/A9)" do
      # A :partial degrades onto the node's :failed edge and parks (Engine.degrade_to_failed).
      # The run parked on attempt 2, so the drawer's failure text must be attempt 2's detail —
      # matching the question, which also comes from the parking execution. Keeping only :failed
      # here surfaced attempt 1 instead, so the escalation panel disagreed with its own question.
      r =
        run(%{
          status: :parked,
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :failed, %{detail: "3 credo warnings"}),
            ne("implement", 2, :partial, %{detail: "2 of 5 plan tasks left unimplemented"})
          ]
        })

      detail = Runs.run_detail(r, nil)

      assert detail.last_failure_detail == "2 of 5 plan tasks left unimplemented"
    end

    test "parked attempt reflects the paused node's highest attempt" do
      r =
        run(%{
          status: :parked,
          current_node: "brainstorm",
          node_executions: [ne("brainstorm", 1, :failed), ne("brainstorm", 2, :failed), ne("brainstorm", 3, :needs_input)]
        })

      assert Runs.run_detail(r, nil).parked_attempt == 3
    end

    test "failure_reason is the engine sentence, else a neutral fallback" do
      assert Runs.run_detail(run(%{status: :failed, failure_detail: "boom"}), nil).failure_reason == "boom"

      assert Runs.run_detail(run(%{status: :failed, failure_detail: nil}), nil).failure_reason ==
               "The run stopped before reaching the end of the flow."
    end
  end

  describe "steered attempts (RE358)" do
    test "a steered row reads :steered and is not a spent attempt; its restart reads resumed" do
      r =
        run(%{
          flow_key: "plan",
          current_node: "write_plan",
          node_executions: [
            ne("write_plan", 1, :steered, %{visit: 1, session_id: "s"}),
            ne("write_plan", 2, nil, %{visit: 1, session_id: nil, duration_s: nil})
          ]
        })

      assert [row1, row2] = Enum.filter(Runs.run_detail(r, nil).timeline, &(&1.kind == :node))

      assert %{state: :steered, steered?: true, attempt: 1} = row1
      assert %{state: :active, steered?: false, resumed?: true, attempt: 1} = row2
    end

    test "a restart after a steer with no known session is not resumed" do
      r =
        run(%{
          current_node: "write_plan",
          node_executions: [
            ne("write_plan", 1, :steered, %{visit: 1, session_id: nil}),
            ne("write_plan", 2, nil, %{visit: 1, session_id: nil, duration_s: nil})
          ]
        })

      assert [_row1, row2] = Enum.filter(Runs.run_detail(r, nil).timeline, &(&1.kind == :node))
      assert row2.resumed? == false
    end
  end

  describe "attempt numbers skip :blocked attempts (RE267)" do
    test "a node that waited out a usage limit twice reads as its first attempt" do
      r =
        run(%{
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 2, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 3, nil, %{visit: 1, duration_s: nil})
          ]
        })

      rows = Enum.filter(Runs.run_detail(r, code_flow()).timeline, &(&1.kind == :node and &1.node_key == "implement"))
      assert rows |> Enum.map(& &1.attempt) |> Enum.take(3) == [1, 1, 1]
    end

    test "the escalation's attempt count counts only attempts that actually ran" do
      r =
        run(%{
          status: :parked,
          current_node: "implement",
          node_executions: [
            ne("implement", 1, :failed, %{visit: 1}),
            ne("implement", 2, :blocked, %{visit: 1, resume_at: ~U[2100-01-01 00:00:00Z]}),
            ne("implement", 3, :failed, %{visit: 1})
          ]
        })

      assert Runs.run_detail(r, code_flow()).parked_attempt == 2
    end
  end
end
