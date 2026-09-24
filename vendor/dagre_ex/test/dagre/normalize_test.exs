defmodule Dagre.NormalizeTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph
  alias Dagre.Normalize
  alias Dagre.Order
  alias Dagre.Position

  # a (rank 0) -> b (rank 3), labelled; a -> c (rank 1), a unit edge.
  defp graph do
    Graph.new()
    |> Graph.add_node(:a, %{width: 100, height: 40, dummy: nil, rank: 0})
    |> Graph.add_node(:b, %{width: 80, height: 30, dummy: nil, rank: 3})
    |> Graph.add_node(:c, %{width: 60, height: 30, dummy: nil, rank: 1})
    |> Graph.add_edge(1, :a, :b, %{label: {40, 10}})
    |> Graph.add_edge(2, :a, :c, %{label: nil})
  end

  test "splits a long edge into a unit-span chain with a label dummy sized to the label" do
    {g, chains} = Normalize.run(graph())

    assert chains[1] == %{
             from: :a,
             to: :b,
             dummies: [{:dummy, 1, 1}, {:dummy, 1, 2}],
             label: {:dummy, 1, 1}
           }

    assert chains[2] == %{from: :a, to: :c, dummies: [], label: nil}
    assert Graph.node(g, {:dummy, 1, 1}) == %{width: 40, height: 10, dummy: :label, rank: 1}
    assert Graph.node(g, {:dummy, 1, 2}) == %{width: 0, height: 0, dummy: :edge, rank: 2}

    for {_, from, to} <- Graph.edges(g) do
      assert Graph.node(g, to).rank - Graph.node(g, from).rank == 1
    end
  end

  test "rejects a labelled edge that spans a single rank" do
    g = Graph.add_edge(graph(), 3, :a, :c, %{label: {10, 10}})
    assert_raise ArgumentError, ~r/at least two ranks/, fn -> Normalize.run(g) end
  end

  test "denormalize round-trips each chain into a polyline from source to target through its dummies" do
    {g, chains} = Normalize.run(graph())
    g = g |> Order.run() |> Position.run(ranksep: 20, nodesep: 10, edgesep: 5)
    routed = Normalize.denormalize(g, chains)

    assert Map.keys(routed) == [1, 2]

    {ax, ay, aw, ah} = Position.box(Graph.node(g, :a))
    {bx, by, bw, _} = Position.box(Graph.node(g, :b))
    %{points: points, label: label} = routed[1]

    assert hd(points) == {ax + div(aw, 2), ay + ah}
    assert List.last(points) == {bx + div(bw, 2), by}
    assert points |> Enum.map(&elem(&1, 1)) |> Enum.chunk_every(2, 1, :discard) |> Enum.all?(fn [a, b] -> a <= b end)

    for dummy <- chains[1].dummies do
      d = Graph.node(g, dummy)
      {top, bottom} = d.band
      x = d.x + div(d.width, 2)
      assert {x, top} in points and {x, bottom} in points
    end

    label_dummy = Graph.node(g, {:dummy, 1, 1})
    assert label == {label_dummy.x + 20, label_dummy.y + 5}
    assert routed[2].label == nil
  end

  test "every segment of a long edge's chain carries the edge's weight" do
    g = Graph.put_edge_attr(graph(), 1, :weight, 3)
    {g, _chains} = Normalize.run(g)

    for i <- 0..2, do: assert(Graph.edge(g, {:segment, 1, i}).weight == 3)
    assert Graph.edge(g, 2) == %{label: nil}
  end

  test "a chain of an edge with no weight gets the default weight of 1" do
    {g, _chains} = Normalize.run(graph())
    for i <- 0..2, do: assert(Graph.edge(g, {:segment, 1, i}).weight == 1)
  end
end
