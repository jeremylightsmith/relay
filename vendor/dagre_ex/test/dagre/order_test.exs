defmodule Dagre.OrderTest do
  use ExUnit.Case, async: true

  alias Dagre.Graph
  alias Dagre.Order

  defp graph(ranked, edges) do
    g = Enum.reduce(ranked, Graph.new(), fn {v, rank}, g -> Graph.add_node(g, v, %{rank: rank}) end)
    Enum.reduce(edges, g, fn {id, from, to}, g -> Graph.add_edge(g, id, from, to) end)
  end

  test "crossings/2 counts crossings between adjacent layers" do
    g = graph([a: 0, b: 0, c: 0, x: 1, y: 1, z: 1], [{1, :a, :z}, {2, :b, :y}, {3, :c, :x}])
    assert Order.crossings(g, [[:a, :b, :c], [:x, :y, :z]]) == 3
    assert Order.crossings(g, [[:a, :b, :c], [:z, :y, :x]]) == 0
  end

  test "crossings/2 counts parallel edges once each" do
    g = graph([a: 0, b: 0, x: 1, y: 1], [{1, :a, :y}, {2, :a, :y}, {3, :b, :x}])
    assert Order.crossings(g, [[:a, :b], [:x, :y]]) == 2
  end

  test "init_order/1 walks depth-first from the nodes in rank order" do
    g = graph([a: 0, b: 0, c: 1, d: 1], [{1, :a, :c}, {2, :a, :d}, {3, :b, :c}])
    assert Order.init_order(g) == [[:a, :b], [:c, :d]]
    assert Order.crossings(g, Order.init_order(g)) == 1
  end

  test "run/1 removes an avoidable crossing and writes :order" do
    g = graph([a: 0, b: 0, c: 1, d: 1], [{1, :a, :c}, {2, :a, :d}, {3, :b, :c}]) |> Order.run()
    layering = Order.layering(g)
    assert Order.crossings(g, layering) == 0
    assert layering |> List.flatten() |> Enum.sort() == [:a, :b, :c, :d]

    for layer <- layering, {v, i} <- Enum.with_index(layer), do: assert(Graph.node(g, v).order == i)
  end

  test "run/1 never increases the crossing count" do
    :rand.seed(:exsss, {3, 4, 5})

    for _ <- 1..20 do
      ranked = for i <- 1..12, do: {i, rem(i, 3)}

      edges =
        for {u, 0} <- ranked, {v, 1} <- ranked, :rand.uniform() < 0.4, do: {{u, v}, u, v}

      edges = edges ++ for {u, 1} <- ranked, {v, 2} <- ranked, :rand.uniform() < 0.4, do: {{u, v}, u, v}
      g = graph(ranked, edges)
      before = Order.crossings(g, Order.init_order(g))
      ordered = Order.run(g)
      assert Order.crossings(ordered, Order.layering(ordered)) <= before
    end
  end
end
