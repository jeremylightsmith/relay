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
      %{node_key: "work", visit: 1, attempt: 1, outcome: :succeeded, failure_signature: nil},
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

  test "no edge for the outcome fails the run — even for succeeded (gates never silently pass)" do
    flow = flow([[key: "gate", type: :gate]], [[from: "start", to: "gate"]])
    current = execution(node_key: "gate")
    assert {:fail, "no_route_for_outcome:" <> _} = Engine.decide(flow, [current], current)
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
    assert {:fail, "loop_budget_exhausted:" <> _} = Engine.decide(flow, history, current)
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
    assert {:fail, "visit_cap_exceeded:" <> _} = Engine.decide(flow, history, current, visit_cap: 2)
  end

  test "failure_signature normalizes: trim and truncate to 500 chars" do
    assert Engine.failure_signature("  boom  ") == Engine.failure_signature("boom")
    long = String.duplicate("x", 600)
    assert Engine.failure_signature(long) == Engine.failure_signature(String.slice(long, 0, 500))
    refute Engine.failure_signature("a") == Engine.failure_signature("b")
  end
end
