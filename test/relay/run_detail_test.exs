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
end
