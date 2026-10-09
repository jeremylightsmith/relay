defmodule Relay.FlowsNeighboursTest do
  use ExUnit.Case, async: true

  alias Relay.Flows
  alias Schemas.Stage

  # The live RE board's columns, as plain structs (no DB), ordered by `Stage.order_stages/1`.
  @re_stages [
    {1, "Suggested", 1, nil, :queue},
    {2, "Someday maybe", 2, nil, :queue},
    {3, "Backlog", 3, nil, :queue},
    {4, "Ready for Design", 4, nil, :queue},
    {5, "Design", 5, nil, :planning},
    {51, "Design:Review", 13, 5, :review},
    {6, "Ready for Spec", 6, nil, :queue},
    {7, "Spec", 7, nil, :planning},
    {71, "Spec:Review", 14, 7, :review},
    {72, "Spec:Done", 15, 7, :done},
    {8, "Plan", 8, nil, :planning},
    {81, "Plan:Done", 16, 8, :done},
    {9, "Code", 9, nil, :work},
    {91, "Code:Done", 17, 9, :done},
    {10, "Deploy", 10, nil, :work},
    {11, "Review", 11, nil, :review},
    {12, "Done", 12, nil, :done}
  ]

  defp re do
    @re_stages
    |> Enum.map(fn {id, name, position, parent_id, type} ->
      %Stage{id: id, name: name, position: position, parent_id: parent_id, type: type}
    end)
    |> Enum.shuffle()
    |> Stage.order_stages()
  end

  defp id_of(stages, name), do: Enum.find(stages, &(&1.name == name)).id

  defp names(stages, name) do
    %{pulls_from: from, lands_on: on} = Flows.neighbours(id_of(stages, name), stages)
    {from && from.name, on && on.name}
  end

  test "a stage with Review and Done lands on its Review" do
    assert names(re(), "Spec") == {"Ready for Spec", "Spec:Review"}
  end

  test "pulls from the previous main's last substage; a Done-only stage lands on its Done" do
    assert names(re(), "Plan") == {"Spec:Done", "Plan:Done"}
  end

  test "Code pulls from Plan:Done and lands on Code:Done" do
    assert names(re(), "Code") == {"Plan:Done", "Code:Done"}
  end

  test "a stage with no substage lands on the next main stage" do
    assert names(re(), "Deploy") == {"Code:Done", "Review"}
  end

  test "a Review-only stage lands on its Review" do
    assert names(re(), "Design") == {"Ready for Design", "Design:Review"}
  end

  test "the first column pulls from nothing" do
    stages = re()

    assert %{pulls_from: nil, lands_on: %Stage{name: "Someday maybe"}} =
             Flows.neighbours(id_of(stages, "Suggested"), stages)
  end

  test "the last column lands on nothing" do
    stages = re()
    assert %{pulls_from: %Stage{name: "Review"}, lands_on: nil} = Flows.neighbours(id_of(stages, "Done"), stages)
  end

  test "a stage id not on the board has no neighbours" do
    assert Flows.neighbours(-1, re()) == %{pulls_from: nil, lands_on: nil}
    assert Flows.neighbours(1, []) == %{pulls_from: nil, lands_on: nil}
  end

  test "works on narrow maps" do
    list =
      Stage.order_stages([
        %{id: 3, parent_id: nil, position: 3, type: :done},
        %{id: 1, parent_id: nil, position: 1, type: :queue},
        %{id: 2, parent_id: nil, position: 2, type: :work}
      ])

    assert %{pulls_from: %{id: 1}, lands_on: %{id: 3}} = Flows.neighbours(2, list)
  end
end
