defmodule Dagre.PositionTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph
  alias Dagre.Order
  alias Dagre.Position

  @opts [ranksep: 68, nodesep: 24, edgesep: 12]

  # rank 0: a(150) d(dummy) b(118) g(24, a label-sized dummy)
  # rank 1: c(150) e(118) f(dummy)
  defp graph do
    [
      {:a, %{width: 150, height: 56, dummy: nil, rank: 0, order: 0}},
      {:d, %{width: 0, height: 0, dummy: :edge, rank: 0, order: 1}},
      {:b, %{width: 118, height: 40, dummy: nil, rank: 0, order: 2}},
      {:g, %{width: 24, height: 16, dummy: :label, rank: 0, order: 3}},
      {:c, %{width: 150, height: 56, dummy: nil, rank: 1, order: 0}},
      {:e, %{width: 118, height: 56, dummy: nil, rank: 1, order: 1}},
      {:f, %{width: 0, height: 0, dummy: :edge, rank: 1, order: 2}}
    ]
    |> Enum.reduce(Graph.new(), fn {v, attrs}, g -> Graph.add_node(g, v, attrs) end)
    |> Graph.add_edge(1, :a, :c)
    |> Graph.add_edge(2, :d, :f)
    |> Graph.add_edge(3, :b, :e)
    |> Graph.add_edge(4, :g, :e)
  end

  defp gap(attrs, nodesep, edgesep), do: if(attrs.dummy, do: edgesep, else: nodesep)

  test "keeps at least the minimum separation between neighbours, respecting variable widths" do
    g = Position.run(graph(), @opts)

    for layer <- Order.layering(g), {u, v} <- Enum.zip(layer, tl(layer)) do
      a = Graph.node(g, u)
      b = Graph.node(g, v)
      min_gap = div(gap(a, 24, 12) + gap(b, 24, 12), 2)
      assert b.x - (a.x + a.width) >= min_gap, "#{u} and #{v} are only #{b.x - (a.x + a.width)}px apart"
    end
  end

  test "stacks rank bands ranksep apart and centres each node in its band" do
    g = Position.run(graph(), @opts)
    assert Graph.node(g, :a).band == {0, 56}
    assert Graph.node(g, :c).band == {124, 180}
    assert Graph.node(g, :a).y == 0
    assert Graph.node(g, :b).y == 8
    assert Graph.node(g, :c).y == 124
  end

  test "translates so the leftmost box starts at x = 0, with integer coordinates" do
    g = Position.run(graph(), @opts)
    xs = Enum.map(Graph.nodes(g), &Graph.node(g, &1).x)
    assert Enum.min(xs) == 0
    assert Enum.all?(xs, &is_integer/1)
  end

  test "a straight chain is vertically aligned" do
    g =
      Graph.new()
      |> Graph.add_node(:a, %{width: 150, height: 56, dummy: nil, rank: 0, order: 0})
      |> Graph.add_node(:b, %{width: 150, height: 56, dummy: nil, rank: 1, order: 0})
      |> Graph.add_edge(1, :a, :b)
      |> Position.run(@opts)

    assert Graph.node(g, :a).x == Graph.node(g, :b).x
  end

  test "box/1 is the caller's box inside a wider layout box" do
    attrs = %{x: 10, y: 20, width: 200, height: 40, box: {150, 30}}
    assert Position.box(attrs) == {10, 25, 150, 30}
    assert Position.box(%{x: 1, y: 2, width: 3, height: 4}) == {1, 2, 3, 4}
  end
end
