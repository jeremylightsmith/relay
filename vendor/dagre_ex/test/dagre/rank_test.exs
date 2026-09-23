defmodule Dagre.RankTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph
  alias Dagre.Rank

  defp graph(nodes, edges, minlen \\ 1) do
    g = Enum.reduce(nodes, Graph.new(), &Graph.add_node(&2, &1))
    Enum.reduce(edges, g, fn {id, from, to}, g -> Graph.add_edge(g, id, from, to, %{minlen: minlen}) end)
  end

  defp ranks(g), do: Map.new(Graph.nodes(g), &{&1, Graph.node(g, &1).rank})

  test "ranks a chain 0, 1, 2, …" do
    g = graph([:a, :b, :c], [{1, :a, :b}, {2, :b, :c}]) |> Rank.run()
    assert ranks(g) == %{a: 0, b: 1, c: 2}
  end

  test "every edge runs strictly forward by at least its minlen" do
    edges = [{1, :a, :b}, {2, :a, :c}, {3, :b, :d}, {4, :c, :d}, {5, :a, :d}, {6, :d, :e}]

    for minlen <- [1, 2] do
      g = graph([:a, :b, :c, :d, :e], edges, minlen) |> Rank.run()
      r = ranks(g)
      for {_, from, to} <- edges, do: assert(r[to] - r[from] >= minlen)
      assert r |> Map.values() |> Enum.min() == 0
    end
  end

  test "tightening pulls a source down next to its only successor" do
    g = graph([:a, :b, :c, :d, :s], [{1, :a, :b}, {2, :b, :c}, {3, :c, :d}, {4, :s, :d}]) |> Rank.run()
    assert ranks(g) == %{a: 0, b: 1, c: 2, d: 3, s: 2}
  end

  test "an isolated node sits on rank 0" do
    g = graph([:a, :b, :z], [{1, :a, :b}]) |> Rank.run()
    assert ranks(g).z == 0
  end

  test "raises on a cycle" do
    g = graph([:a, :b], [{1, :a, :b}, {2, :b, :a}])
    assert_raise ArgumentError, ~r/cycle/, fn -> Rank.run(g) end
  end
end
