defmodule Hamaca.Runs.CardCostTest do
  use ExUnit.Case, async: true

  alias Hamaca.Runs.CardCost

  @finished ~U[2026-11-01 12:00:00Z]

  defp ne(id, cost, attrs \\ %{}) do
    Map.merge(
      %{id: id, cost: cost && Decimal.new(cost), finished_at: @finished, outcome: :succeeded},
      attrs
    )
  end

  defp run(status, stage, nes),
    do: %{status: status, flow_key: String.downcase(stage), flow: %{stage: %{name: stage}}, node_executions: nes}

  # Newest first, as `Runs.list_runs_for_card/1` returns them; D1 is the oldest run.
  defp mockup_card(c2_status \\ :running, agent_cost \\ nil) do
    [
      run(c2_status, "Code", [ne(6, "2.35"), ne(901, agent_cost), ne(902, agent_cost)]),
      run(:failed, "Code", [ne(5, "1.67")]),
      run(:done, "Spec", [ne(4, "0.35")]),
      run(:done, "Design", [ne(3, "0.27")]),
      run(:cancelled, "Design", [ne(2, "0.50")]),
      run(:done, "Design", [ne(1, "0.40")])
    ]
  end

  @agent_ids MapSet.new([901, 902])

  defp assert_dec(actual, expected), do: assert(Decimal.equal?(actual, Decimal.new(expected)), "#{actual} != #{expected}")

  defp assert_row(row, expected) do
    {cost, expected} = Map.pop!(expected, :cost)
    assert_dec(row.cost, cost)
    assert Map.delete(row, :cost) == expected
  end

  defp assert_rows(rows, expected) do
    assert length(rows) == length(expected)
    rows |> Enum.zip(expected) |> Enum.each(fn {row, exp} -> assert_row(row, exp) end)
  end

  test "1: the mockup card folds into total, unpriced, in-flight, stage rows and the failed row" do
    cost = CardCost.build(mockup_card(), @agent_ids)

    assert_dec(cost.total, "5.54")
    assert cost.runs == 6
    assert cost.in_flight? == true
    assert cost.unpriced == 2

    assert_rows(cost.by_stage, [
      %{label: "Design", runs: 3, failed: 0, cost: "1.17", bar: 29},
      %{label: "Spec", runs: 1, failed: 0, cost: "0.35", bar: 9},
      %{label: "Code", runs: 2, failed: 1, cost: "4.02", bar: 100}
    ])

    assert_row(cost.failed, %{runs: 2, cost: "2.17", bar: 54})
  end

  test "2: no active run and priced agent executions leave nothing in flight or unpriced" do
    cost = CardCost.build(mockup_card(:done, "0.00"), @agent_ids)

    assert cost.in_flight? == false
    assert cost.unpriced == 0
  end

  test "3: only finished, non-blocked agent executions with no cost are unpriced" do
    runs = [
      run(:done, "Code", [
        ne(1, "1.00"),
        ne(2, nil),
        ne(3, nil),
        ne(4, nil, %{outcome: :blocked}),
        ne(5, nil, %{finished_at: nil, outcome: nil})
      ])
    ]

    cost = CardCost.build(runs, MapSet.new([2, 4, 5]))

    assert cost.unpriced == 1
    assert_dec(cost.total, "1.00")
  end

  test "4: a card with no priced execution has no cost" do
    runs = [run(:done, "Code", [ne(1, nil), ne(2, nil)]), run(:failed, "Spec", [ne(3, nil)])]

    assert CardCost.build(runs, MapSet.new([1])) == nil
  end

  test "4: a card with no runs has no cost" do
    assert CardCost.build([], MapSet.new()) == nil
  end

  test "5: no failed or cancelled run means no failed row; a single stage is full width" do
    runs = [run(:done, "Code", [ne(2, "0.20")]), run(:done, "Code", [ne(1, "0.30")])]

    cost = CardCost.build(runs, MapSet.new())

    assert cost.failed == nil
    assert_rows(cost.by_stage, [%{label: "Code", runs: 2, failed: 0, cost: "0.50", bar: 100}])
  end

  test "6: empty runs, a deleted flow and a zero-cost failed row" do
    runs = [
      %{status: :done, flow: nil, flow_key: "triage", node_executions: [ne(3, nil)]},
      run(:done, "Code", [ne(2, "0.40")]),
      run(:cancelled, "Design", [])
    ]

    cost = CardCost.build(runs, MapSet.new())

    assert_rows(cost.by_stage, [
      %{label: "Design", runs: 1, failed: 0, cost: "0", bar: 0},
      %{label: "Code", runs: 1, failed: 0, cost: "0.40", bar: 100},
      %{label: "triage", runs: 1, failed: 0, cost: "0", bar: 0}
    ])

    assert_row(cost.failed, %{runs: 1, cost: "0", bar: 0})
  end

  test "a run whose node_executions is nil counts as a run with none" do
    runs = [run(:done, "Code", [ne(1, "0.40")]), %{run(:cancelled, "Design", []) | node_executions: nil}]

    cost = CardCost.build(runs, MapSet.new())

    assert_rows(cost.by_stage, [
      %{label: "Design", runs: 1, failed: 0, cost: "0", bar: 0},
      %{label: "Code", runs: 1, failed: 0, cost: "0.40", bar: 100}
    ])
  end

  test "7: the stage rows sum to the total; the failed row is not an extra addend" do
    cost = CardCost.build(mockup_card(), @agent_ids)

    sum = Enum.reduce(cost.by_stage, Decimal.new(0), &Decimal.add(&1.cost, &2))

    assert Decimal.equal?(sum, cost.total)
  end
end
