defmodule Relay.Runs.EngineTest do
  use ExUnit.Case, async: true

  alias Relay.Runs.Engine
  alias Schemas.Flow

  # Pure-data builders: Engine.decide/4 needs only nodes/edges off the flow
  # and node_key/visit/outcome/failure_signature off each history row.
  defp flow(nodes, edges) do
    %Flow{
      nodes: Enum.map(nodes, &struct!(Flow.Node, &1)),
      edges: Enum.map(edges, &struct!(Flow.Edge, &1))
    }
  end

  defp execution(attrs) do
    Map.merge(
      %{node_key: "work", visit: 1, attempt: 1, outcome: :succeeded, failure_signature: nil, sub_task_id: nil},
      Map.new(attrs)
    )
  end

  defp failed(attrs) do
    detail = Keyword.get(attrs, :detail, "boom")

    execution(Keyword.merge([outcome: :failed, failure_signature: Engine.failure_signature(detail)], attrs))
  end

  defp two_node_flow(opts \\ []) do
    flow(
      [
        Keyword.merge([key: "work", type: :agent], Keyword.get(opts, :work, [])),
        [key: "fallback", type: :agent]
      ],
      [
        [from: "start", to: "work"],
        Keyword.merge([from: "work", to: "done", on: :succeeded], Keyword.get(opts, :success_edge, [])),
        [from: "work", to: "fallback", on: :failed],
        [from: "fallback", to: "done", on: :succeeded]
      ]
    )
  end

  test "succeeded routes along the matching edge" do
    flow =
      flow([[key: "a", type: :agent], [key: "b", type: :agent]], [
        [from: "start", to: "a"],
        [from: "a", to: "b", on: :succeeded]
      ])

    current = execution(node_key: "a")
    assert Engine.decide(flow, [current], current) == {:transition, "b"}
  end

  test "an edge to done finishes the run" do
    current = execution([])
    assert Engine.decide(two_node_flow(), [current], current) == {:finish, :done}
  end

  # Post-RLY-179 a non-:failed outcome with no matching edge degrades to the :failed
  # edge first; this flow has neither, so it still fails outright.
  test "no edge for the outcome and none to degrade to fails the run — even for succeeded" do
    flow = flow([[key: "gate", type: :gate]], [[from: "start", to: "gate"]])
    current = execution(node_key: "gate")
    assert {:fail, reason} = Engine.decide(flow, [current], current)
    assert reason =~ "no_route_for_outcome:"
  end

  test "needs_input parks without consulting any edge" do
    flow =
      flow([[key: "work", type: :agent]], [
        [from: "start", to: "work"],
        [from: "work", to: "done", on: :needs_input]
      ])

    current = execution(outcome: :needs_input)
    assert Engine.decide(flow, [current], current) == {:park, :needs_input}
  end

  test "failed retries the same node while the current visit has budget" do
    flow = two_node_flow(work: [max_retries: 1])
    current = failed(detail: "boom-1")
    assert Engine.decide(flow, [current], current) == {:retry, "work"}
  end

  test "failed with retries exhausted follows the failed edge" do
    flow = two_node_flow(work: [max_retries: 1])
    first = failed(detail: "boom-1")
    second = failed(detail: "boom-2", attempt: 2)
    assert Engine.decide(flow, [first, second], second) == {:transition, "fallback"}
  end

  test "max_retries nil means zero retries" do
    current = failed([])
    assert Engine.decide(two_node_flow(), [current], current) == {:transition, "fallback"}
  end

  test "the circuit breaker fails the run on the Nth identical failure even with retry budget left" do
    flow = two_node_flow(work: [max_retries: 10])
    history = for attempt <- 1..3, do: failed(detail: "same boom", attempt: attempt)
    current = List.last(history)
    assert {:fail, "circuit_breaker:" <> _} = Engine.decide(flow, history, current)
  end

  test "distinct failure signatures never trip the breaker" do
    flow = two_node_flow(work: [max_retries: 10])
    history = for attempt <- 1..3, do: failed(detail: "boom-#{attempt}", attempt: attempt)
    current = List.last(history)
    assert Engine.decide(flow, history, current) == {:retry, "work"}
  end

  test "an exhausted max_loops edge fails the run" do
    flow = two_node_flow(success_edge: [], work: [])

    flow = %{
      flow
      | edges:
          Enum.map(flow.edges, fn
            %{from: "work", on: :failed} = edge -> %{edge | max_loops: 2}
            edge -> edge
          end)
    }

    # Two prior traversals of work --failed--> fallback already happened.
    history = [
      failed(detail: "a"),
      execution(node_key: "fallback"),
      failed(detail: "b", visit: 2),
      execution(node_key: "fallback", visit: 2),
      failed(detail: "c", visit: 3)
    ]

    current = List.last(history)
    assert {:fail, reason} = Engine.decide(flow, history, current)
    assert reason =~ "loop_budget_exhausted:"
  end

  test "the visit cap fails a transition into an over-visited node" do
    flow =
      flow([[key: "a", type: :agent], [key: "b", type: :agent]], [
        [from: "start", to: "a"],
        [from: "a", to: "b", on: :succeeded],
        [from: "b", to: "a", on: :succeeded]
      ])

    history =
      Enum.flat_map(1..2, fn visit ->
        [execution(node_key: "a", visit: visit), execution(node_key: "b", visit: visit)]
      end)

    current = List.last(history)
    assert {:fail, reason} = Engine.decide(flow, history, current, visit_cap: 2)
    assert reason =~ "visit_cap_exceeded:"
  end

  test "failure_signature normalizes: trim and truncate to 500 chars" do
    assert Engine.failure_signature("  boom  ") == Engine.failure_signature("boom")
    long = String.duplicate("x", 600)
    assert Engine.failure_signature(long) == Engine.failure_signature(String.slice(long, 0, 500))
    refute Engine.failure_signature("a") == Engine.failure_signature("b")
  end

  # --- foreach: guarded edge selection (W13) ---

  # head --succeeded--> head (when: remaining) | tail (when: exhausted), plus an
  # unguarded failed edge, i.e. the reconciled Code flow's shape in miniature.
  defp foreach_flow do
    flow(
      [
        [key: "head", type: :agent, foreach: "card.sub_tasks"],
        [key: "tail", type: :gate]
      ],
      [
        [from: "start", to: "head"],
        [from: "head", to: "head", on: :succeeded, when: :foreach_remaining],
        [from: "head", to: "tail", on: :succeeded, when: :foreach_exhausted],
        [from: "tail", to: "done", on: :succeeded]
      ]
    )
  end

  test "a foreach_remaining guard routes back into the loop head while items remain" do
    current = execution(node_key: "head", sub_task_id: 1)

    assert Engine.decide(foreach_flow(), [current], current, foreach_remaining: 2) ==
             {:transition, "head"}
  end

  test "a foreach_exhausted guard leaves the loop when no items remain" do
    current = execution(node_key: "head", sub_task_id: 1)

    assert Engine.decide(foreach_flow(), [current], current, foreach_remaining: 0) ==
             {:transition, "tail"}
  end

  test "an unguarded edge is the fallback when no guard is satisfied" do
    flow =
      flow(
        [[key: "head", type: :agent, foreach: "card.sub_tasks"], [key: "other", type: :agent]],
        [
          [from: "start", to: "head"],
          [from: "head", to: "head", on: :succeeded, when: :foreach_remaining],
          [from: "head", to: "other", on: :succeeded]
        ]
      )

    current = execution(node_key: "head", sub_task_id: 1)
    assert Engine.decide(flow, [current], current, foreach_remaining: 0) == {:transition, "other"}
  end

  # --- per-iteration budgets (decision 8) ---

  # head --failed--> head, max_loops 3, inside a foreach: the Code flow's
  # implement <-> review lap, in miniature.
  defp lap_flow do
    flow(
      [[key: "head", type: :agent, foreach: "card.sub_tasks"], [key: "tail", type: :gate]],
      [
        [from: "start", to: "head"],
        [from: "head", to: "head", on: :failed, max_loops: 3],
        [from: "head", to: "tail", on: :succeeded, when: :foreach_exhausted]
      ]
    )
  end

  defp lap(sub_task_id, n) do
    failed(node_key: "head", visit: n, sub_task_id: sub_task_id, detail: "finding #{sub_task_id}-#{n}")
  end

  test "max_loops resets across foreach iterations — task 1's churn does not spend task 2's budget" do
    # Task 1 burned its full 3 laps; task 2's FIRST refusal must still loop back.
    history = [lap(1, 1), lap(1, 2), lap(1, 3), lap(2, 4)]
    current = List.last(history)

    assert Engine.decide(lap_flow(), history, current, sub_task_id: 2, foreach_remaining: 1) ==
             {:transition, "head"}
  end

  test "max_loops still fires WITHIN one foreach iteration" do
    history = [lap(1, 1), lap(1, 2), lap(1, 3), lap(1, 4)]
    current = List.last(history)

    assert {:fail, reason} = Engine.decide(lap_flow(), history, current, sub_task_id: 1, foreach_remaining: 1)
    assert reason =~ "loop_budget_exhausted:"
  end

  test "the visit cap is iteration-scoped the same way" do
    # Two visits of "head" on task 1, then task 2's first visit: under a cap of 2 the
    # global count (3) would fail, the iteration-scoped count (1) must not.
    flow =
      flow(
        [[key: "head", type: :agent, foreach: "card.sub_tasks"], [key: "mid", type: :agent]],
        [
          [from: "start", to: "head"],
          [from: "head", to: "mid", on: :succeeded],
          [from: "mid", to: "head", on: :succeeded]
        ]
      )

    history = [
      execution(node_key: "head", visit: 1, sub_task_id: 1),
      execution(node_key: "mid", visit: 1, sub_task_id: 1),
      execution(node_key: "head", visit: 2, sub_task_id: 1),
      execution(node_key: "mid", visit: 2, sub_task_id: 1),
      execution(node_key: "head", visit: 3, sub_task_id: 2),
      execution(node_key: "mid", visit: 3, sub_task_id: 2)
    ]

    current = List.last(history)
    assert Engine.decide(flow, history, current, visit_cap: 2, sub_task_id: 2) == {:transition, "head"}
  end

  test "the circuit breaker stays GLOBAL across foreach iterations (deliberate asymmetry)" do
    history = [
      failed(node_key: "head", visit: 1, sub_task_id: 1, detail: "same boom"),
      failed(node_key: "head", visit: 2, sub_task_id: 2, detail: "same boom"),
      failed(node_key: "head", visit: 3, sub_task_id: 3, detail: "same boom")
    ]

    current = List.last(history)

    assert {:fail, "circuit_breaker:" <> _} =
             Engine.decide(lap_flow(), history, current, sub_task_id: 3, foreach_remaining: 1)
  end

  test "sub_task_id nil scopes to the whole run — nodes outside a foreach are untouched" do
    # Identical history to the max_loops-within-one-iteration case, but unkeyed: the
    # global count must still fail the run, proving scope_to_iteration(h, nil) is identity.
    history = [
      failed(node_key: "head", visit: 1, detail: "a"),
      failed(node_key: "head", visit: 2, detail: "b"),
      failed(node_key: "head", visit: 3, detail: "c"),
      failed(node_key: "head", visit: 4, detail: "d")
    ]

    current = List.last(history)
    assert {:fail, reason} = Engine.decide(lap_flow(), history, current)
    assert reason =~ "loop_budget_exhausted:"
  end

  describe "unrouted outcome degrades to the node's :failed edge (RLY-179)" do
    @describetag :capture_log

    test "an outcome with no edge follows the node's :failed edge instead of failing the run" do
      flow =
        flow([[key: "spec_review", type: :agent], [key: "implement", type: :agent]], [
          [from: "start", to: "implement"],
          [from: "implement", to: "spec_review", on: :succeeded],
          [from: "spec_review", to: "implement", on: :failed, max_loops: 3]
        ])

      current = execution(node_key: "spec_review", outcome: :partial)
      assert Engine.decide(flow, [current], current) == {:transition, "implement"}
    end

    test "the degrade spends the :failed edge's max_loops budget rather than resetting it" do
      flow =
        flow([[key: "spec_review", type: :agent], [key: "implement", type: :agent]], [
          [from: "start", to: "implement"],
          [from: "implement", to: "spec_review", on: :succeeded],
          [from: "spec_review", to: "implement", on: :failed, max_loops: 1]
        ])

      # One prior :partial at spec_review already degraded onto (and spent) the
      # :failed edge, so a second traversal — degraded or real — is over budget.
      prior = execution(node_key: "spec_review", visit: 1, outcome: :partial)
      current = execution(node_key: "spec_review", visit: 2, outcome: :failed)

      assert {:fail, reason} = Engine.decide(flow, [prior, current], current)
      assert reason =~ "loop_budget_exhausted:"
    end

    test "with no :failed edge at all the run still fails" do
      flow = flow([[key: "solo", type: :agent]], [[from: "start", to: "solo"]])
      current = execution(node_key: "solo", outcome: :partial)

      assert {:fail, reason} = Engine.decide(flow, [current], current)
      assert reason =~ "no_route_for_outcome: solo → partial"
    end

    test "a :failed outcome with no edge is NOT degraded — it has nowhere left to go" do
      flow = flow([[key: "final_fix", type: :agent]], [[from: "start", to: "final_fix"]])
      current = execution(node_key: "final_fix", outcome: :failed)

      assert {:fail, reason} = Engine.decide(flow, [current], current)
      assert reason =~ "no_route_for_outcome: final_fix → failed"
    end

    test "the degrade honors guard preference, taking the satisfied :failed edge" do
      flow =
        flow(
          [[key: "quality_review", type: :agent], [key: "implement", type: :agent], [key: "precommit", type: :gate]],
          [
            [from: "start", to: "implement"],
            [from: "implement", to: "quality_review", on: :succeeded],
            [from: "quality_review", to: "implement", on: :failed, when: :foreach_remaining],
            [from: "quality_review", to: "precommit", on: :failed, when: :foreach_exhausted]
          ]
        )

      current = execution(node_key: "quality_review", outcome: :partial)

      assert Engine.decide(flow, [current], current, foreach_remaining: 2) == {:transition, "implement"}
      assert Engine.decide(flow, [current], current, foreach_remaining: 0) == {:transition, "precommit"}
    end

    test "a parked (:needs_input) execution in history does not spend the :failed edge's budget" do
      flow =
        flow([[key: "review", type: :agent], [key: "fix", type: :agent]], [
          [from: "start", to: "review"],
          [from: "review", to: "fix", on: :failed, max_loops: 1]
        ])

      # The park at visit 1 must not count as a :failed traversal, else the real
      # :failed at visit 2 would already be over the max_loops 1 budget.
      parked = execution(node_key: "review", visit: 1, outcome: :needs_input)
      current = execution(node_key: "review", visit: 2, outcome: :failed)

      assert Engine.decide(flow, [parked, current], current) == {:transition, "fix"}
    end
  end

  describe "failure reasons read as English (RLY-179)" do
    test "no-route leads with a sentence and keeps the machine token in parentheses" do
      flow = flow([[key: "gate", type: :gate]], [[from: "start", to: "gate"]])
      current = execution(node_key: "gate", outcome: :succeeded)

      assert {:fail, reason} = Engine.decide(flow, [current], current)
      assert reason =~ "The flow has nowhere to go after `gate` reported `succeeded`."
      assert reason =~ "(no_route_for_outcome: gate → succeeded)"
    end

    test "loop-budget failure leads with a sentence and keeps its token" do
      flow =
        flow([[key: "a", type: :agent], [key: "b", type: :agent]], [
          [from: "start", to: "a"],
          [from: "a", to: "b", on: :succeeded, max_loops: 1]
        ])

      prior = execution(node_key: "a", visit: 1, outcome: :succeeded)
      current = execution(node_key: "a", visit: 2, outcome: :succeeded)

      assert {:fail, reason} = Engine.decide(flow, [prior, current], current)
      assert reason =~ "looped back to `b` too many times"
      assert reason =~ "(loop_budget_exhausted: a → b on succeeded (max_loops 1))"
    end
  end

  # RLY-189 — a human retry buys exactly ONE more move on every cap the engine
  # consults, uniformly. `bonus: 0` must reproduce today's behaviour byte for byte.
  describe "bonus (RLY-189 retry allowance)" do
    test "bonus: 0 changes nothing" do
      flow = two_node_flow(work: [max_retries: 0])
      current = failed(node_key: "work")

      assert Engine.decide(flow, [current], current, bonus: 0) ==
               Engine.decide(flow, [current], current)
    end

    test "bonus raises the node's max_retries by exactly the bonus" do
      flow = two_node_flow(work: [max_retries: 0])
      current = failed(node_key: "work")

      assert Engine.decide(flow, [current], current) == {:transition, "fallback"}
      assert Engine.decide(flow, [current], current, bonus: 1) == {:retry, "work"}
    end

    test "bonus raises the breaker threshold by exactly the bonus" do
      flow = two_node_flow(work: [max_retries: 0])
      first = failed(node_key: "work", detail: "same")
      current = failed(node_key: "work", detail: "same")
      history = [first, current]

      assert {:fail, reason} = Engine.decide(flow, history, current, breaker_threshold: 2)
      assert reason =~ "circuit_breaker:"

      assert Engine.decide(flow, history, current, breaker_threshold: 2, bonus: 1) ==
               {:transition, "fallback"}
    end

    test "bonus raises an edge's max_loops by exactly the bonus" do
      flow =
        flow([[key: "work", type: :agent, max_retries: 0], [key: "fix", type: :agent]], [
          [from: "start", to: "work"],
          [from: "work", to: "fix", on: :failed, max_loops: 2],
          [from: "fix", to: "work", on: :succeeded],
          [from: "work", to: "done", on: :succeeded]
        ])

      first = failed(node_key: "work", visit: 1, detail: "one")
      second = failed(node_key: "work", visit: 2, detail: "two")
      current = failed(node_key: "work", visit: 2, attempt: 2, detail: "three")
      history = [first, second, current]

      assert {:fail, reason} = Engine.decide(flow, history, current)
      assert reason =~ "loop_budget_exhausted:"
      assert Engine.decide(flow, history, current, bonus: 1) == {:transition, "fix"}
    end

    test "bonus raises the visit cap by exactly the bonus" do
      flow =
        flow([[key: "work", type: :agent, max_retries: 0], [key: "fix", type: :agent]], [
          [from: "start", to: "work"],
          [from: "work", to: "fix", on: :failed],
          [from: "fix", to: "work", on: :succeeded],
          [from: "work", to: "done", on: :succeeded]
        ])

      fixed = execution(node_key: "fix", visit: 1)
      first = failed(node_key: "work", visit: 1, detail: "one")
      current = failed(node_key: "work", visit: 1, attempt: 2, detail: "two")
      history = [fixed, first, current]

      assert {:fail, reason} = Engine.decide(flow, history, current, visit_cap: 1)
      assert reason =~ "visit_cap_exceeded:"
      assert Engine.decide(flow, history, current, visit_cap: 1, bonus: 1) == {:transition, "fix"}
    end

    test "an unlimited edge stays unlimited under a bonus" do
      flow =
        flow([[key: "work", type: :agent, max_retries: 0], [key: "fix", type: :agent]], [
          [from: "start", to: "work"],
          [from: "work", to: "fix", on: :failed],
          [from: "fix", to: "work", on: :succeeded],
          [from: "work", to: "done", on: :succeeded]
        ])

      # More failures than even the bonus-inflated retry budget (max_retries 0 + bonus
      # 3 = 3) allows, so `work` is forced to ROUTE onto the failed edge rather than
      # retry in place -- that's the case this test actually needs to exercise the
      # edge's nil max_loops under a bonus.
      history = for attempt <- 1..4, do: failed(node_key: "work", attempt: attempt, detail: "one")
      current = List.last(history)

      assert Engine.decide(flow, history, current, bonus: 3) == {:transition, "fix"}
    end
  end
end
