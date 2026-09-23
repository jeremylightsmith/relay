defmodule Dagre.Acyclic do
  @moduledoc """
  Cycle breaking — phase 1 of the pipeline.

  A greedy feedback-arc-set by depth-first walk (dagre's default `"dfs"`
  acyclicer): nodes are visited in insertion order, and any edge pointing at a
  node still on the current DFS stack is a back-edge and gets reversed. The
  reversed edge keeps its id and attrs and gains `reversed: true`.

  Once cycles are broken, a loop-back is just another edge: it is ranked,
  normalized, ordered and positioned like any other, and `undo/2` flips its
  routed points back into the caller's direction at the end.
  """

  alias Dagre.Graph

  @doc "Reverses every back-edge. Returns the now-acyclic graph and the set of reversed edge ids."
  @spec run(Graph.t()) :: {Graph.t(), MapSet.t()}
  def run(%Graph{} = graph) do
    {_visited, reversed} =
      graph
      |> Graph.nodes()
      |> Enum.reduce({MapSet.new(), []}, &dfs(graph, &1, MapSet.new(), &2))

    reversed = Enum.reverse(reversed)
    {Enum.reduce(reversed, graph, &reverse_edge(&2, &1)), MapSet.new(reversed)}
  end

  @doc """
  Flips routed edges back into the caller's direction.

  `edges` maps edge id to a map carrying `:points`. Every edge gains
  `:reversed?`; the reversed ones also get their `:points` reversed.
  """
  @spec undo(%{Graph.id() => map()}, MapSet.t()) :: %{Graph.id() => map()}
  def undo(edges, reversed) do
    Map.new(edges, fn {id, edge} ->
      if MapSet.member?(reversed, id) do
        {id, edge |> Map.update!(:points, &Enum.reverse/1) |> Map.put(:reversed?, true)}
      else
        {id, Map.put(edge, :reversed?, false)}
      end
    end)
  end

  defp dfs(graph, v, stack, {visited, reversed} = acc) do
    if MapSet.member?(visited, v) do
      acc
    else
      stack = MapSet.put(stack, v)

      graph
      |> Graph.out_edges(v)
      |> Enum.reduce({MapSet.put(visited, v), reversed}, &follow(graph, stack, &1, &2))
    end
  end

  # An edge into a node still on the DFS stack closes a cycle: it is a back-edge.
  defp follow(graph, stack, {id, _, w}, {visited, reversed} = acc) do
    if MapSet.member?(stack, w), do: {visited, [id | reversed]}, else: dfs(graph, w, stack, acc)
  end

  defp reverse_edge(graph, id) do
    attrs = Graph.edge(graph, id)
    {from, to} = Graph.endpoints(graph, id)

    graph
    |> Graph.remove_edge(id)
    |> Graph.add_edge(id, to, from, Map.put(attrs, :reversed, true))
  end
end
