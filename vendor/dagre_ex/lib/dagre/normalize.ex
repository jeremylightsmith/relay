defmodule Dagre.Normalize do
  @moduledoc """
  Edge normalization — phase 3 of the pipeline — and its inverse.

  `run/1` does two jobs:

    1. Every edge spanning more than one rank is replaced by a chain of dummy
       nodes, one per intermediate rank. A dummy occupies a real slot in its
       rank's ordering, so a long edge can never be routed through a node box.
    2. Every edge carrying a `:label` (`{width, height}`) gets its label dummy on
       the middle intermediate rank, **sized to the label**. The label therefore
       reserves real estate on that rank and cannot land on a node or another
       label. A labelled edge must span at least two ranks — `Dagre.layout/1`
       guarantees that by giving every edge `minlen: 2` when any edge is labelled.

  Dummy node ids are `{:dummy, edge_id, rank}` and dummy edge ids
  `{:segment, edge_id, index}`, so they cannot collide with the integer ids
  `Dagre.layout/1` uses internally.

  `denormalize/2` runs after `Dagre.Position` and collapses every chain back
  into a polyline for its edge.
  """

  alias Dagre.Graph
  alias Dagre.Position

  @type chain :: %{from: Graph.id(), to: Graph.id(), dummies: [Graph.id()], label: Graph.id() | nil}
  @type chains :: %{Graph.id() => chain()}

  @doc "Makes every edge span exactly one rank. Returns the graph and one chain per original edge."
  @spec run(Graph.t()) :: {Graph.t(), chains()}
  def run(%Graph{} = graph) do
    graph |> Graph.edges() |> Enum.reduce({graph, %{}}, &normalize_edge/2)
  end

  @doc """
  Collapses each chain into `%{points: [{x, y}], label: {x, y} | nil}`.

  `points` runs from the source's bottom-centre, straight down through every
  dummy's slot (entering at the top of the dummy's rank band and leaving at its
  bottom), to the target's top-centre. Every segment inside a rank band is
  vertical and sits in the edge's own slot; the diagonal segments lie in the
  empty gaps between bands. `label` is the label dummy's centre.
  """
  @spec denormalize(Graph.t(), chains()) :: %{
          Graph.id() => %{points: [{integer(), integer()}], label: {integer(), integer()} | nil}
        }
  def denormalize(%Graph{} = graph, chains) do
    Map.new(chains, fn {id, chain} -> {id, %{points: points(graph, chain), label: label(graph, chain.label)}} end)
  end

  defp normalize_edge({id, from, to}, {graph, chains}) do
    label = Map.get(Graph.edge(graph, id), :label)
    from_rank = Graph.node(graph, from).rank
    to_rank = Graph.node(graph, to).rank

    cond do
      to_rank - from_rank == 1 and is_nil(label) ->
        {graph, Map.put(chains, id, %{from: from, to: to, dummies: [], label: nil})}

      to_rank - from_rank < 2 and not is_nil(label) ->
        raise ArgumentError, "labelled edge #{inspect(id)} must span at least two ranks"

      true ->
        {graph, chain} = split(graph, id, {from, from_rank}, {to, to_rank}, label)
        {graph, Map.put(chains, id, chain)}
    end
  end

  defp split(graph, id, {from, from_rank}, {to, to_rank}, label) do
    label_rank = if label, do: from_rank + div(to_rank - from_rank, 2)
    ranks = Enum.to_list((from_rank + 1)..(to_rank - 1)//1)
    dummies = Enum.map(ranks, &{:dummy, id, &1})

    graph =
      Enum.reduce(ranks, Graph.remove_edge(graph, id), fn rank, graph ->
        Graph.add_node(graph, {:dummy, id, rank}, dummy_attrs(rank, rank == label_rank, label))
      end)

    path = [from | dummies] ++ [to]

    graph =
      path
      |> Enum.zip(tl(path))
      |> Enum.with_index()
      |> Enum.reduce(graph, fn {{a, b}, i}, graph -> Graph.add_edge(graph, {:segment, id, i}, a, b) end)

    {graph, %{from: from, to: to, dummies: dummies, label: label_rank && {:dummy, id, label_rank}}}
  end

  defp dummy_attrs(rank, true, {width, height}), do: %{width: width, height: height, dummy: :label, rank: rank}
  defp dummy_attrs(rank, _label?, _label), do: %{width: 0, height: 0, dummy: :edge, rank: rank}

  defp points(graph, chain) do
    {sx, sy, sw, sh} = Position.box(Graph.node(graph, chain.from))
    {tx, ty, tw, _} = Position.box(Graph.node(graph, chain.to))
    {_, source_band_bottom} = Graph.node(graph, chain.from).band
    {target_band_top, _} = Graph.node(graph, chain.to).band
    source_x = sx + div(sw, 2)
    target_x = tx + div(tw, 2)

    through =
      Enum.flat_map(chain.dummies, fn dummy ->
        attrs = Graph.node(graph, dummy)
        {top, bottom} = attrs.band
        x = attrs.x + div(attrs.width, 2)
        [{x, top}, {x, bottom}]
      end)

    [{source_x, sy + sh}, {source_x, source_band_bottom}]
    |> Enum.concat(through)
    |> Enum.concat([{target_x, target_band_top}, {target_x, ty}])
    |> Enum.dedup()
  end

  defp label(_graph, nil), do: nil

  defp label(graph, dummy) do
    attrs = Graph.node(graph, dummy)
    {attrs.x + div(attrs.width, 2), attrs.y + div(attrs.height, 2)}
  end
end
