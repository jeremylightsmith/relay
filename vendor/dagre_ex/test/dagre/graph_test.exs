defmodule Dagre.GraphTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph

  defp graph do
    Graph.new()
    |> Graph.add_node(:a, %{width: 10})
    |> Graph.add_node(:b)
    |> Graph.add_node(:c)
    |> Graph.add_edge(1, :a, :b, %{label: "x"})
    |> Graph.add_edge(2, :a, :c)
    |> Graph.add_edge(3, :a, :b)
  end

  test "lists nodes and edges in insertion order" do
    g = graph()
    assert Graph.nodes(g) == [:a, :b, :c]
    assert Graph.edges(g) == [{1, :a, :b}, {2, :a, :c}, {3, :a, :b}]
    assert Graph.has_node?(g, :a)
    refute Graph.has_node?(g, :z)
  end

  test "is a multigraph: parallel edges are kept apart by id" do
    g = graph()
    assert Graph.out_edges(g, :a) == [{1, :a, :b}, {2, :a, :c}, {3, :a, :b}]
    assert Graph.in_edges(g, :b) == [{1, :a, :b}, {3, :a, :b}]
    assert Graph.successors(g, :a) == [:b, :c]
    assert Graph.predecessors(g, :b) == [:a]
    assert Graph.predecessors(g, :a) == []
  end

  test "reads and writes node and edge attrs" do
    g = graph() |> Graph.put_node_attr(:a, :rank, 0) |> Graph.put_edge_attr(1, :weight, 2)
    assert Graph.node(g, :a) == %{width: 10, rank: 0}
    assert Graph.edge(g, 1) == %{label: "x", weight: 2}
    assert Graph.endpoints(g, 1) == {:a, :b}
  end

  test "re-adding a node merges its attrs" do
    g = Graph.add_node(graph(), :a, %{height: 5})
    assert Graph.node(g, :a) == %{width: 10, height: 5}
    assert Graph.nodes(g) == [:a, :b, :c]
  end

  test "remove_edge drops one edge and leaves its parallel twin" do
    g = Graph.remove_edge(graph(), 1)
    assert Graph.edges(g) == [{2, :a, :c}, {3, :a, :b}]
    assert Graph.in_edges(g, :b) == [{3, :a, :b}]
    assert Graph.remove_edge(g, 99) == g
  end

  test "rejects a duplicate edge id and an unknown endpoint" do
    assert_raise ArgumentError, ~r/already exists/, fn -> Graph.add_edge(graph(), 1, :b, :c) end
    assert_raise ArgumentError, ~r/unknown node/, fn -> Graph.add_edge(graph(), 9, :a, :z) end
  end
end
