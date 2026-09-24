defmodule Dagre.WeightTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph
  alias Dagre.Position

  @opts [ranksep: 68, nodesep: 24, edgesep: 12]

  defp n(id, width \\ 150, height \\ 56), do: %{id: id, width: width, height: height}
  defp e(from, to, weight), do: %{id: {from, to}, from: from, to: to, weight: weight}

  defp lay_out(nodes, edges), do: Dagre.layout([nodes: nodes, edges: edges] ++ @opts)

  defp centre(layout, id), do: layout.nodes[id].x + div(layout.nodes[id].width, 2)

  defp centres(layout, ids), do: ids |> Enum.map(&centre(layout, &1)) |> Enum.uniq()

  # A path a → b → c → d, where side nodes feed b and c from the right and hang off
  # them on the right, so each unweighted median pulls the path sideways.
  defp pulled_path(path_weight) do
    nodes = [n("a"), n("x"), n("y"), n("b"), n("p"), n("c"), n("q"), n("d"), n("r")]

    edges = [
      e("a", "b", path_weight),
      e("b", "c", path_weight),
      e("c", "d", path_weight),
      e("x", "b", 1),
      e("y", "b", 1),
      e("x", "p", 1),
      e("p", "c", 1),
      e("y", "q", 1),
      e("q", "c", 1),
      e("c", "r", 1),
      e("b", "r", 1)
    ]

    {nodes, edges}
  end

  describe "a heavy path" do
    test "lays out as one vertical line, every path edge a single vertical segment" do
      {nodes, edges} = pulled_path(2)
      layout = lay_out(nodes, edges)

      assert [x] = centres(layout, ~w(a b c d))

      for edge <- [{"a", "b"}, {"b", "c"}, {"c", "d"}] do
        assert layout.edges[edge].points |> Enum.map(&elem(&1, 0)) |> Enum.uniq() == [x]
      end
    end

    test "is not straight with equal weights — the weights are what straighten it" do
      {nodes, edges} = pulled_path(1)
      assert length(centres(lay_out(nodes, edges), ~w(a b c d))) > 1
    end

    test "stays straight through labelled edges, whose label dummies sit on the line" do
      {nodes, edges} = pulled_path(2)
      edges = Enum.map(edges, &Map.put(&1, :label, %{width: 61, height: 16}))
      layout = lay_out(nodes, edges)

      assert [x] = centres(layout, ~w(a b c d))
      assert {^x, _} = layout.edges[{"b", "c"}].label
    end
  end

  test "explicit weight 1 on every edge is the same layout as omitting weight" do
    {nodes, edges} = pulled_path(1)
    omitted = Enum.map(edges, &Map.delete(&1, :weight))
    assert lay_out(nodes, edges) == lay_out(nodes, omitted)
  end

  test "an odd-width node on a straight chain shares its neighbours' centre to the pixel" do
    layout = lay_out([n("a"), n("b", 117), n("c")], [e("a", "b", 1), e("b", "c", 1)])
    assert [_] = centres(layout, ~w(a b c))
  end

  test "a self-loop's room does not pull its node's box off a straight path" do
    nodes = [n("a"), n("b"), n("c")]
    edges = [e("a", "b", 2), e("b", "c", 2), %{id: :loop, from: "b", to: "b", label: %{width: 80, height: 16}}]
    layout = lay_out(nodes, edges)

    assert [_] = centres(layout, ~w(a b c))
  end

  describe "Dagre.Position with weighted segments" do
    defp place(nodes, edges) do
      graph = Enum.reduce(nodes, Graph.new(), fn {v, attrs}, g -> Graph.add_node(g, v, attrs) end)

      edges
      |> Enum.reduce(graph, fn {id, u, v, weight}, g -> Graph.add_edge(g, id, u, v, %{weight: weight}) end)
      |> Position.run(@opts)
    end

    defp real(rank, order, width \\ 150), do: %{width: width, height: 56, dummy: nil, rank: rank, order: order}
    defp dummy(rank, order), do: %{width: 0, height: 0, dummy: :edge, rank: rank, order: order}

    defp centre_of(graph, v), do: Graph.node(graph, v).x + div(Graph.node(graph, v).width, 2)

    # rank 0: a  d1        a → b is a real segment; d1 → d2 is an inner (dummy–dummy)
    # rank 1: d2 b         segment crossing it.
    defp crossed(ab_weight) do
      place(
        [{:a, real(0, 0)}, {:d1, dummy(0, 1)}, {:d2, dummy(1, 0)}, {:b, real(1, 1)}],
        [{1, :a, :b, ab_weight}, {2, :d1, :d2, 1}]
      )
    end

    test "a heavy segment wins a crossing against a lighter inner segment" do
      g = crossed(2)
      assert centre_of(g, :a) == centre_of(g, :b)
    end

    test "with equal weights the inner segment wins, as in plain Brandes–Köpf" do
      g = crossed(1)
      refute centre_of(g, :a) == centre_of(g, :b)
      assert centre_of(g, :d1) == centre_of(g, :d2)
    end

    # rank 0:   p
    # rank 1: r   q        p → q is heavy; its light sibling p → r sits to the left and would
    #                      claim p first in a left-to-right sweep.
    defp siblings(pq_weight) do
      place(
        [{:p, real(0, 0)}, {:r, real(1, 0)}, {:q, real(1, 1)}],
        [{1, :p, :r, 1}, {2, :p, :q, pq_weight}]
      )
    end

    test "a light sibling cannot claim the node its heavy sibling aligns with" do
      g = siblings(2)
      assert centre_of(g, :p) == centre_of(g, :q)
    end

    test "with equal weights the node balances between its two children" do
      g = siblings(1)
      refute centre_of(g, :p) == centre_of(g, :q)
      refute centre_of(g, :p) == centre_of(g, :r)
    end
  end
end
