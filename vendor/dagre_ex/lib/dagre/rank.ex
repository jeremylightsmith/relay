defmodule Dagre.Rank do
  @moduledoc """
  Rank assignment — phase 2 of the pipeline.

  Longest-path ranking top-down (every node sits one `minlen` below its lowest
  predecessor), then a single tightening pass in reverse topological order that
  pulls a node down toward its successors when it has more out-edges than
  in-edges — shortening more edges than it lengthens. Sources always qualify, so
  a source feeding only a late node sits just above it rather than on row 0.

  Each edge may carry a `:minlen` attr (default 1). Ranks are normalized so the
  smallest is 0 and written to every node's `:rank` attr.

  **Known future improvement:** dagre's default ranker is network simplex, which
  minimises total weighted edge length globally and gives tighter layouts on
  wide graphs. It is deliberately *not* implemented here; longest-path plus
  tightening is correct (every edge spans at least its `minlen`) and good enough
  for the narrow, mostly-sequential graphs this port was written for. Edge
  `:weight` is honoured downstream (by `Dagre.Position`) but not here, which is
  deliberate: network simplex is where dagre's ranker would read it.
  """

  alias Dagre.Graph

  @doc "Assigns `:rank` to every node of an acyclic graph. Raises `ArgumentError` on a cycle."
  @spec run(Graph.t()) :: Graph.t()
  def run(%Graph{} = graph) do
    order = topological(graph)

    ranks =
      Enum.reduce(order, %{}, fn v, ranks ->
        rank =
          graph
          |> Graph.in_edges(v)
          |> Enum.map(fn {id, u, _} -> Map.fetch!(ranks, u) + minlen(graph, id) end)
          |> Enum.max(fn -> 0 end)

        Map.put(ranks, v, rank)
      end)

    ranks = order |> Enum.reverse() |> Enum.reduce(ranks, &tighten(graph, &1, &2))
    low = ranks |> Map.values() |> Enum.min(fn -> 0 end)

    Enum.reduce(order, graph, fn v, graph -> Graph.put_node_attr(graph, v, :rank, Map.fetch!(ranks, v) - low) end)
  end

  defp tighten(graph, v, ranks) do
    outs = Graph.out_edges(graph, v)

    if length(outs) > length(Graph.in_edges(graph, v)) do
      limit = outs |> Enum.map(fn {id, _, w} -> Map.fetch!(ranks, w) - minlen(graph, id) end) |> Enum.min()
      Map.update!(ranks, v, &max(&1, limit))
    else
      ranks
    end
  end

  defp minlen(graph, id), do: Map.get(Graph.edge(graph, id), :minlen, 1)

  defp topological(graph) do
    nodes = Graph.nodes(graph)
    indegree = Map.new(nodes, &{&1, length(Graph.in_edges(graph, &1))})
    order = kahn(graph, Enum.filter(nodes, &(indegree[&1] == 0)), indegree, [])

    if length(order) != length(nodes), do: raise(ArgumentError, "graph has a cycle; run Dagre.Acyclic first")
    order
  end

  defp kahn(_graph, [], _indegree, acc), do: Enum.reverse(acc)

  defp kahn(graph, [v | rest], indegree, acc) do
    {indegree, ready} =
      graph
      |> Graph.out_edges(v)
      |> Enum.reduce({indegree, []}, fn {_, _, w}, {indegree, ready} ->
        indegree = Map.update!(indegree, w, &(&1 - 1))
        if indegree[w] == 0, do: {indegree, [w | ready]}, else: {indegree, ready}
      end)

    kahn(graph, rest ++ Enum.reverse(ready), indegree, [v | acc])
  end
end
