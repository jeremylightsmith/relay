defmodule Dagre.AcyclicTest do
  use ExUnit.Case, async: true

  alias Dagre.Acyclic
  alias Dagre.Graph

  defp graph(nodes, edges) do
    g = Enum.reduce(nodes, Graph.new(), &Graph.add_node(&2, &1))
    Enum.reduce(edges, g, fn {id, from, to}, g -> Graph.add_edge(g, id, from, to, %{label: {id, 1}}) end)
  end

  # Peels off sources until nothing is left (acyclic) or nothing can be peeled (a cycle).
  defp acyclic?(g), do: peel(g, Graph.nodes(g))

  defp peel(_g, []), do: true

  defp peel(g, remaining) do
    left = MapSet.new(remaining)
    sources = Enum.filter(remaining, fn v -> g |> Graph.predecessors(v) |> Enum.all?(&(&1 not in left)) end)
    if sources == [], do: false, else: peel(g, remaining -- sources)
  end

  test "reverses the back-edge of a cycle and leaves a DAG" do
    g = graph([:a, :b, :c, :d], [{1, :a, :b}, {2, :b, :c}, {3, :c, :a}, {4, :c, :d}])
    refute acyclic?(g)

    {dag, reversed} = Acyclic.run(g)

    assert acyclic?(dag)
    assert reversed == MapSet.new([3])
    assert Graph.endpoints(dag, 3) == {:a, :c}
    assert Graph.edge(dag, 3) == %{label: {3, 1}, reversed: true}
    assert Graph.endpoints(dag, 1) == {:a, :b}
  end

  test "breaks nested loops and parallel back-edges" do
    g =
      graph([:a, :b, :c, :d], [
        {1, :a, :b},
        {2, :b, :c},
        {3, :c, :d},
        {4, :c, :b},
        {5, :d, :a},
        {6, :d, :a}
      ])

    {dag, reversed} = Acyclic.run(g)
    assert acyclic?(dag)
    assert reversed == MapSet.new([4, 5, 6])
  end

  test "leaves an acyclic graph untouched" do
    g = graph([:a, :b, :c], [{1, :a, :b}, {2, :a, :c}, {3, :b, :c}])
    assert Acyclic.run(g) == {g, MapSet.new()}
  end

  test "undo/2 restores the caller's direction of reversed edges only" do
    routed = %{
      1 => %{points: [{0, 0}, {0, 10}], label: nil},
      3 => %{points: [{0, 0}, {5, 5}, {0, 10}], label: {5, 5}}
    }

    assert Acyclic.undo(routed, MapSet.new([3])) == %{
             1 => %{points: [{0, 0}, {0, 10}], label: nil, reversed?: false},
             3 => %{points: [{0, 10}, {5, 5}, {0, 0}], label: {5, 5}, reversed?: true}
           }
  end
end
