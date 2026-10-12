defmodule Storybook.RunComponents.RunRegionGroup do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  alias Schemas.Flow

  # Rendered through the timeline so the waiting / resolved `fan_in` and the row after it show
  # around the group (RE440, card mockup "Run view — branches grouped under the fan-out").
  def function, do: &RelayWeb.RunComponents.run_node_timeline/1
  def render_source, do: :function

  @t0 ~U[2026-07-20 00:00:00Z]

  # prep → review_panel ⇉ {review_security, review_correctness ⇄ fix_correctness,
  # review_conventions} → review_join → fix_findings → precommit → browser → final_review.
  defp flow(max_parallel) do
    agent = fn key -> %Flow.Node{key: key, type: :agent, run: key} end
    edge = fn from, on, to -> %Flow.Edge{from: from, on: on, to: to} end

    %Flow{
      nodes: [
        agent.("implement"),
        %Flow.Node{key: "review_panel", type: :fan_out, max_parallel: max_parallel},
        agent.("review_security"),
        agent.("review_correctness"),
        agent.("fix_correctness"),
        agent.("review_conventions"),
        %Flow.Node{key: "review_join", type: :fan_in},
        agent.("fix_findings"),
        %Flow.Node{key: "precommit", type: :shell, run: "mix precommit"},
        %Flow.Node{key: "browser", type: :shell, run: "mix test.browser"},
        agent.("final_review")
      ],
      edges: [
        edge.("start", nil, "implement"),
        edge.("implement", :succeeded, "review_panel"),
        edge.("review_panel", nil, "review_security"),
        edge.("review_panel", nil, "review_correctness"),
        edge.("review_panel", nil, "review_conventions"),
        edge.("review_security", :succeeded, "review_join"),
        %Flow.Edge{from: "review_correctness", on: :failed, to: "fix_correctness", max_loops: 2},
        edge.("fix_correctness", :succeeded, "review_correctness"),
        edge.("review_correctness", :succeeded, "review_join"),
        edge.("review_conventions", :succeeded, "review_join"),
        edge.("review_join", :succeeded, "fix_findings"),
        edge.("fix_findings", :succeeded, "precommit"),
        edge.("precommit", :succeeded, "browser"),
        edge.("browser", :succeeded, "final_review"),
        edge.("final_review", :succeeded, "done")
      ]
    }
  end

  defp at(seconds), do: DateTime.add(@t0, seconds, :second)

  # One execution from `from` to `to` seconds after @t0 (`to` nil = still in flight).
  defp ne(id, node_key, attempt, outcome, {from, to}, attrs \\ %{}) do
    Map.merge(
      %{
        id: id,
        node_key: node_key,
        attempt: attempt,
        outcome: outcome,
        detail: nil,
        cost: nil,
        started_at: at(from),
        finished_at: to && at(to)
      },
      attrs
    )
  end

  defp branch(id, key, position, state, outcome \\ nil),
    do: %{id: id, fan_out_execution_id: 100, branch: key, position: position, state: state, outcome: outcome}

  defp cost(amount), do: %{cost: Decimal.new(amount)}

  defp detail(run_attrs, nes, flow) do
    run =
      Map.merge(
        %{status: :running, flow_key: "code", current_node: "review_panel", started_at: @t0, finished_at: nil},
        run_attrs
      )

    Relay.Runs.run_detail(Map.put(run, :node_executions, nes), flow)
  end

  defp head,
    do: [ne(10, "implement", 1, :succeeded, {-408, 0}, cost("1.42")), ne(100, "review_panel", 1, :succeeded, {0, 0})]

  def variations do
    [
      %Variation{
        id: :in_flight,
        description: "In flight — one branch done, one looping back through its fix, one running",
        attributes: %{
          detail:
            detail(
              %{
                run_branches: [
                  branch(1, "review_security", 0, :ended, :succeeded),
                  branch(2, "review_correctness", 1, :running),
                  branch(3, "review_conventions", 2, :running)
                ]
              },
              head() ++
                [
                  ne(101, "review_security", 1, :succeeded, {1, 101}, Map.put(cost("0.31"), :run_branch_id, 1)),
                  ne(102, "review_correctness", 1, :failed, {1, 126}, %{
                    run_branch_id: 2,
                    cost: Decimal.new("0.38"),
                    detail: "runs.ex:412 cancels only the first in-flight branch"
                  }),
                  ne(103, "review_conventions", 1, nil, {1, nil}, %{run_branch_id: 3}),
                  ne(104, "fix_correctness", 2, :succeeded, {130, 202}, Map.put(cost("0.22"), :run_branch_id, 2)),
                  ne(105, "review_correctness", 2, nil, {254, nil}, %{run_branch_id: 2})
                ],
              flow(nil)
            )
        }
      },
      %Variation{
        id: :queued_max_parallel,
        description: "max_parallel: 2 — the third branch is queued, waiting for a free slot (not pending)",
        attributes: %{
          detail:
            detail(
              %{
                run_branches: [
                  branch(1, "review_security", 0, :running),
                  branch(2, "review_correctness", 1, :running),
                  branch(3, "review_conventions", 2, :queued)
                ]
              },
              head() ++
                [
                  ne(101, "review_security", 1, nil, {1, nil}, %{run_branch_id: 1}),
                  ne(102, "review_correctness", 1, nil, {1, nil}, %{run_branch_id: 2})
                ],
              flow(2)
            )
        }
      },
      %Variation{
        id: :joined_with_failure,
        description: "Joined with a failure — the join fails and fix_findings gets every branch's result",
        attributes: %{
          detail:
            detail(
              %{
                current_node: "fix_findings",
                run_branches: [
                  branch(1, "review_security", 0, :ended, :succeeded),
                  branch(2, "review_correctness", 1, :ended, :failed),
                  branch(3, "review_conventions", 2, :ended, :succeeded)
                ]
              },
              head() ++
                [
                  ne(101, "review_security", 1, :succeeded, {1, 101}, Map.put(cost("0.31"), :run_branch_id, 1)),
                  ne(102, "review_correctness", 1, :failed, {1, 126}, %{
                    run_branch_id: 2,
                    cost: Decimal.new("0.38"),
                    detail: "runs.ex:412 cancels only the first in-flight branch"
                  }),
                  ne(104, "fix_correctness", 2, :succeeded, {130, 202}, Map.put(cost("0.22"), :run_branch_id, 2)),
                  ne(105, "review_correctness", 2, :failed, {210, 361}, %{
                    run_branch_id: 2,
                    cost: Decimal.new("0.44"),
                    detail: "Loop budget spent (max 2). Findings:\n- runs.ex:412 cancels only the first in-flight branch"
                  }),
                  ne(103, "review_conventions", 1, :succeeded, {1, 311}, Map.put(cost("0.29"), :run_branch_id, 3)),
                  ne(110, "review_join", 1, :failed, {420, 461}),
                  ne(111, "fix_findings", 1, nil, {462, nil})
                ],
              flow(nil)
            )
        }
      }
    ]
  end
end
