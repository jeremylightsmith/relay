defmodule Dagre.Order do
  @moduledoc """
  Crossing reduction — phase 4 of the pipeline.

  Works on a normalized graph (every edge spans exactly one rank). The initial
  order comes from a depth-first walk from the nodes in rank order, appending
  each node to its rank's layer as it is first reached. Then, as in dagre:
  sweep down (reorder each layer by the median position of its upper
  neighbours) and up (by its lower neighbours) alternately, run a transpose
  (adjacent-swap) pass after each sweep, and keep whichever layering had the
  fewest crossings. It stops after four consecutive sweeps without an
  improvement — dagre's bound — or as soon as the layering has no crossings.

  Crossings are counted with the accumulator tree of Barth, Jünger & Mutzel.

  A *layering* is a list of layers indexed by rank; each layer is a list of node
  ids, left to right. `run/1` writes each node's index within its layer to its
  `:order` attr.
  """

  alias Dagre.Graph

  @max_stale_sweeps 4

  @type layering :: [[Graph.id()]]

  @doc "Orders every layer to reduce crossings and writes `:order` onto every node."
  @spec run(Graph.t()) :: Graph.t()
  def run(%Graph{} = graph) do
    initial = init_order(graph)
    best = improve(graph, initial, 0, 0, {initial, crossings(graph, initial)})

    best
    |> Enum.flat_map(&Enum.with_index/1)
    |> Enum.reduce(graph, fn {v, i}, graph -> Graph.put_node_attr(graph, v, :order, i) end)
  end

  @doc "The initial layering: a depth-first walk from the nodes in rank order."
  @spec init_order(Graph.t()) :: layering()
  def init_order(%Graph{} = graph) do
    {_seen, layers} =
      graph
      |> Graph.nodes()
      |> Enum.sort_by(&rank(graph, &1))
      |> Enum.reduce({MapSet.new(), %{}}, &visit(graph, &1, &2))

    for r <- 0..max_rank(graph)//1, do: layers |> Map.get(r, []) |> Enum.reverse()
  end

  @doc "The layering recorded in the nodes' `:rank` and `:order` attrs."
  @spec layering(Graph.t()) :: layering()
  def layering(%Graph{} = graph) do
    by_rank = Enum.group_by(Graph.nodes(graph), &rank(graph, &1))

    for r <- 0..max_rank(graph)//1 do
      by_rank |> Map.get(r, []) |> Enum.sort_by(&Graph.node(graph, &1).order)
    end
  end

  @doc "The total number of edge crossings between every pair of adjacent layers."
  @spec crossings(Graph.t(), layering()) :: non_neg_integer()
  def crossings(%Graph{} = graph, layering) do
    layering
    |> Enum.zip(Enum.drop(layering, 1))
    |> Enum.map(fn {north, south} -> bilayer_crossings(graph, north, south) end)
    |> Enum.sum()
  end

  defp improve(_graph, _layering, _i, _stale, {best, 0}), do: best
  defp improve(_graph, _layering, _i, stale, {best, _}) when stale >= @max_stale_sweeps, do: best

  defp improve(graph, layering, i, stale, {_, best_count} = best) do
    layering = graph |> sweep(layering, rem(i, 2) == 0, rem(i, 4) >= 2) |> transpose(graph)
    count = crossings(graph, layering)

    if count < best_count do
      improve(graph, layering, i + 1, 0, {layering, count})
    else
      improve(graph, layering, i + 1, stale + 1, best)
    end
  end

  defp visit(graph, v, {seen, layers} = acc) do
    if MapSet.member?(seen, v) do
      acc
    else
      acc = {MapSet.put(seen, v), Map.update(layers, rank(graph, v), [v], &[v | &1])}
      graph |> Graph.successors(v) |> Enum.reduce(acc, &visit(graph, &1, &2))
    end
  end

  # One sweep. Downward, each layer is reordered against the (already reordered)
  # layer above; upward, against the layer below.
  defp sweep(_graph, [], _down?, _bias_right?), do: []

  defp sweep(graph, layering, down?, bias_right?) do
    [first | rest] = if down?, do: layering, else: Enum.reverse(layering)
    neighbours = if down?, do: &upper_neighbours/2, else: &lower_neighbours/2

    {swept, _} =
      Enum.map_reduce(rest, first, fn layer, fixed ->
        layer = reorder(graph, layer, position_map(fixed), neighbours, bias_right?)
        {layer, layer}
      end)

    swept = [first | swept]
    if down?, do: swept, else: Enum.reverse(swept)
  end

  # Nodes with no neighbours in the fixed layer keep their slot; the rest are
  # sorted by median neighbour position (ties broken by current position, to the
  # left or right depending on the sweep's bias) and poured into the other slots.
  defp reorder(graph, layer, fixed_pos, neighbours, bias_right?) do
    keyed =
      layer
      |> Enum.with_index()
      |> Enum.map(fn {v, i} ->
        {v, i, graph |> neighbours.(v) |> Enum.map(&Map.fetch!(fixed_pos, &1)) |> median()}
      end)

    movable =
      keyed
      |> Enum.reject(fn {_, _, m} -> is_nil(m) end)
      |> Enum.sort_by(fn {_, i, m} -> {m, if(bias_right?, do: -i, else: i)} end)

    {layer, []} =
      Enum.map_reduce(keyed, movable, fn
        {v, _, nil}, movable -> {v, movable}
        _, [{w, _, _} | movable] -> {w, movable}
      end)

    layer
  end

  defp median([]), do: nil

  defp median(positions) do
    sorted = Enum.sort(positions)
    n = length(sorted)
    m = div(n, 2)

    cond do
      rem(n, 2) == 1 -> Enum.at(sorted, m) / 1
      n == 2 -> (Enum.at(sorted, 0) + Enum.at(sorted, 1)) / 2
      true -> weighted_median(sorted, m)
    end
  end

  defp weighted_median(sorted, m) do
    left = Enum.at(sorted, m - 1) - hd(sorted)
    right = List.last(sorted) - Enum.at(sorted, m)

    if left + right == 0 do
      (Enum.at(sorted, m - 1) + Enum.at(sorted, m)) / 2
    else
      (Enum.at(sorted, m - 1) * right + Enum.at(sorted, m) * left) / (left + right)
    end
  end

  # Repeats adjacent swaps on every layer until no swap reduces crossings. Each
  # swap strictly lowers the crossing count, so this terminates.
  defp transpose(layering, graph) do
    {layering, swapped?} =
      Enum.reduce(0..(length(layering) - 1)//1, {layering, false}, fn r, {layering, swapped?} ->
        above = if r > 0, do: position_map(Enum.at(layering, r - 1)), else: %{}
        below = position_map(Enum.at(layering, r + 1, []))
        {layer, layer_swapped?} = swap_pass(graph, Enum.at(layering, r), {above, below}, [], false)
        {List.replace_at(layering, r, layer), swapped? or layer_swapped?}
      end)

    if swapped?, do: transpose(layering, graph), else: layering
  end

  defp swap_pass(graph, [v, w | rest], positions, acc, swapped?) do
    if pair_crossings(graph, v, w, positions) > pair_crossings(graph, w, v, positions) do
      swap_pass(graph, [v | rest], positions, [w | acc], true)
    else
      swap_pass(graph, [w | rest], positions, [v | acc], swapped?)
    end
  end

  defp swap_pass(_graph, rest, _positions, acc, swapped?), do: {Enum.reverse(acc, rest), swapped?}

  # Crossings among the edges of `v` and `w` when `v` sits immediately left of `w`.
  defp pair_crossings(graph, v, w, {above, below}) do
    inversions(positions_of(upper_neighbours(graph, v), above), positions_of(upper_neighbours(graph, w), above)) +
      inversions(positions_of(lower_neighbours(graph, v), below), positions_of(lower_neighbours(graph, w), below))
  end

  defp inversions(lefts, rights), do: Enum.sum(for a <- lefts, b <- rights, a > b, do: 1)

  defp positions_of(nodes, positions), do: Enum.map(nodes, &Map.fetch!(positions, &1))

  defp bilayer_crossings(graph, north, south) do
    south_pos = position_map(south)

    entries =
      Enum.flat_map(north, fn v ->
        graph |> lower_neighbours(v) |> positions_of(south_pos) |> Enum.sort()
      end)

    first_leaf = leaf_offset(length(south), 1)

    {_tree, count} =
      Enum.reduce(entries, {%{}, 0}, fn pos, {tree, count} ->
        index = pos + first_leaf
        {tree, larger} = climb(Map.update(tree, index, 1, &(&1 + 1)), index, 0)
        {tree, count + larger}
      end)

    count
  end

  defp leaf_offset(size, power) when power < size, do: leaf_offset(size, power * 2)
  defp leaf_offset(_size, power), do: power - 1

  # Walks from a leaf to the root, summing every right sibling passed (the
  # entries already seen at a larger position) and counting this entry in.
  defp climb(tree, 0, larger), do: {tree, larger}

  defp climb(tree, index, larger) do
    larger = if rem(index, 2) == 1, do: larger + Map.get(tree, index + 1, 0), else: larger
    parent = div(index - 1, 2)
    climb(Map.update(tree, parent, 1, &(&1 + 1)), parent, larger)
  end

  defp upper_neighbours(graph, v), do: graph |> Graph.in_edges(v) |> Enum.map(fn {_, u, _} -> u end)
  defp lower_neighbours(graph, v), do: graph |> Graph.out_edges(v) |> Enum.map(fn {_, _, w} -> w end)

  defp position_map(layer), do: layer |> Enum.with_index() |> Map.new()

  defp rank(graph, v), do: Graph.node(graph, v).rank

  defp max_rank(graph), do: graph |> Graph.nodes() |> Enum.map(&rank(graph, &1)) |> Enum.max(fn -> -1 end)
end
