defmodule Dagre.Position do
  @moduledoc """
  Coordinate assignment — phase 5 of the pipeline.

  **y** is simple: each rank is a horizontal *band* as tall as its tallest
  member, bands are stacked `ranksep` apart, and every node is centred
  vertically in its band.

  **x** is Brandes–Köpf ("Fast and Simple Horizontal Coordinate Assignment",
  2001), ported from dagre's `position/bk.js`:

    1. mark conflicts — a segment crossing a segment of strictly higher
       *priority* `{weight, inner?}` (compared in that order; *inner* means both
       ends are dummies) is never used for alignment. With equal weights this
       is exactly Brandes–Köpf's type-1 rule — a non-inner segment crossing an
       inner one — so long edges stay straight; a heavier edge beats both;
    2. for each of the four directions (up/down × left/right), align every node
       with its median neighbour into vertical *blocks*, then compact the blocks
       horizontally over a block graph whose edges carry the minimum separation
       between neighbours. A node considers only the neighbours
       joined to it by a segment that is among its own heaviest in the sweep
       direction AND among the neighbour's heaviest in the opposite direction,
       so a light edge can never claim a node its heavy edge needs; with equal
       weights that is every neighbour;
    3. shift the four candidates onto the narrowest one and take, per node, the
       average of the two middle candidate x's.

  Together, rules 1 and 2 make a heavy path straight: when the edges heavier
  than all their neighbours form a single directed path, that path is one block
  in all four candidates, so every node and dummy on it gets the same x-centre.

  A node is aligned on the centre of its caller box (`:box`, see `box/1`), not
  of its layout box: extra layout width — a self-loop's room — extends to the
  right of the box. Separation respects variable widths: two neighbours on a
  rank are kept at least `right_a + sep_a / 2 + sep_b / 2 + left_b` apart
  (centre to centre), where `left`/`right` are the node's extents either side of
  its centre (half its width, unless it carries a narrower `:box`) and `sep` is
  `edgesep` for a dummy and `nodesep` for a real node.

  Centres are rounded to integers before the box is placed, so `x + div(width, 2)`
  reads back exactly the centre and an aligned path stays straight to the pixel.
  Writes `:x` / `:y` (the top-left of the node's `width × height` box, integers,
  translated so the leftmost box starts at 0) and `:band` (`{top, bottom}` of the
  node's rank band) onto every node. Segment weights come from each edge's
  `:weight` attr (default 1).
  """

  alias Dagre.Graph
  alias Dagre.Order

  @doc "Positions every node of an ordered, normalized graph. Options: `:ranksep`, `:nodesep`, `:edgesep`."
  @spec run(Graph.t(), keyword()) :: Graph.t()
  def run(%Graph{} = graph, opts) do
    layering = Order.layering(graph)
    centres = x_coordinates(graph, layering, Keyword.fetch!(opts, :nodesep), Keyword.fetch!(opts, :edgesep))
    lefts = Map.new(centres, fn {v, x} -> {v, round(x) - div(anchor_width(graph, v), 2)} end)
    shift = lefts |> Map.values() |> Enum.min(fn -> 0 end)
    bands = bands(graph, layering, Keyword.fetch!(opts, :ranksep))

    layering
    |> Enum.zip(bands)
    |> Enum.reduce(graph, fn {layer, {top, bottom} = band}, graph ->
      Enum.reduce(layer, graph, fn v, graph ->
        attrs = Graph.node(graph, v)
        placed = %{x: lefts[v] - shift, y: top + div(bottom - top - attrs.height, 2), band: band}
        Graph.add_node(graph, v, placed)
      end)
    end)
  end

  @doc """
  The `{x, y, width, height}` box of a positioned node.

  A node may carry a `:box` of `{width, height}` smaller than its layout
  `width × height` (the layout size reserves extra room beside it). The box sits
  at the layout box's left edge, centred vertically.
  """
  @spec box(map()) :: {integer(), integer(), non_neg_integer(), non_neg_integer()}
  def box(%{box: {w, h}} = attrs), do: {attrs.x, attrs.y + div(attrs.height - h, 2), w, h}
  def box(attrs), do: {attrs.x, attrs.y, attrs.width, attrs.height}

  defp bands(graph, layering, ranksep) do
    {bands, _} =
      Enum.map_reduce(layering, 0, fn layer, top ->
        height = layer |> Enum.map(&Graph.node(graph, &1).height) |> Enum.max(fn -> 0 end)
        {{top, top + height}, top + height + ranksep}
      end)

    bands
  end

  defp x_coordinates(graph, layering, nodesep, edgesep) do
    weights = segment_weights(graph)
    conflicts = conflicts(graph, layering, weights)
    sep = &separation(graph, &1, &2, {nodesep, edgesep})

    candidates =
      for vertical <- [:up, :down], horizontal <- [:left, :right] do
        candidate(graph, layering, {conflicts, weights}, sep, {vertical, horizontal})
      end

    balance(align_to_narrowest(graph, candidates))
  end

  # One of the four Brandes–Köpf candidates. `:down` walks the layers bottom-up
  # aligning with successors; `:right` walks each layer right-to-left and negates
  # the result.
  defp candidate(graph, layering, {conflicts, weights}, sep, {vertical, horizontal}) do
    layers = if vertical == :up, do: layering, else: Enum.reverse(layering)
    layers = if horizontal == :left, do: layers, else: Enum.map(layers, &Enum.reverse/1)

    directions =
      if vertical == :up,
        do: {&Graph.predecessors/2, &Graph.successors/2},
        else: {&Graph.successors/2, &Graph.predecessors/2}

    {root, _align} = vertical_alignment(graph, layers, {conflicts, weights}, directions)
    xs = horizontal_compaction(layers, root, sep)
    xs = if horizontal == :right, do: Map.new(xs, fn {v, x} -> {v, -x} end), else: xs
    {horizontal, xs}
  end

  # The weight of every segment, keyed by its unordered endpoint pair. Parallel
  # edges between the same two nodes count as their heaviest.
  defp segment_weights(graph) do
    for {id, u, v} <- Graph.edges(graph), reduce: %{} do
      weights -> Map.update(weights, pair(u, v), weight(graph, id), &max(&1, weight(graph, id)))
    end
  end

  defp weight(graph, id), do: Map.get(Graph.edge(graph, id), :weight, 1)

  # Generalised type-1 conflicts: a segment crossing a segment of strictly higher
  # priority `{weight, inner?}` (inner = both ends dummies) is marked and never
  # used for alignment. With equal weights this is exactly Brandes–Köpf's type-1
  # rule — a non-inner segment crossing an inner one.
  defp conflicts(graph, layering, weights) do
    layering
    |> Enum.zip(Enum.drop(layering, 1))
    |> Enum.reduce(MapSet.new(), fn {upper, lower}, conflicts ->
      upper_pos = layer_positions(upper)

      segments =
        for {v, j} <- Enum.with_index(lower),
            u <- Graph.predecessors(graph, v),
            do: {upper_pos[u], j, priority(graph, weights, u, v), pair(u, v)}

      for {u1, v1, p1, s1} <- segments,
          {u2, v2, p2, _} <- segments,
          p1 < p2,
          (u1 - u2) * (v1 - v2) < 0,
          reduce: conflicts do
        conflicts -> MapSet.put(conflicts, s1)
      end
    end)
  end

  defp priority(graph, weights, u, v), do: {weights[pair(u, v)], dummy?(graph, u) and dummy?(graph, v)}

  defp vertical_alignment(graph, layers, {conflicts, weights}, {neighbours, opposite}) do
    pos = for layer <- layers, {v, i} <- Enum.with_index(layer), into: %{}, do: {v, i}
    ids = List.flatten(layers)
    identity = Map.new(ids, &{&1, &1})

    context = %{
      graph: graph,
      pos: pos,
      conflicts: conflicts,
      weights: weights,
      neighbours: neighbours,
      opposite: opposite
    }

    Enum.reduce(layers, {identity, identity}, fn layer, acc ->
      {acc, _prev} = Enum.reduce(layer, {acc, -1}, &align_node(context, &1, &2))
      acc
    end)
  end

  # Aligns `v` with its median neighbour(s) in the previous layer, left to right,
  # never crossing an alignment already made on this layer (`prev`).
  defp align_node(context, v, {alignment, prev}) do
    ws = context |> heaviest(v) |> Enum.sort_by(&context.pos[&1])
    n = length(ws)
    medians = if n == 0, do: [], else: Enum.slice(ws, div(n - 1, 2)..div(n, 2)//1)

    Enum.reduce(medians, {alignment, prev}, fn w, {{root, align}, prev} = acc ->
      if align[v] == v and prev < context.pos[w] and not MapSet.member?(context.conflicts, pair(v, w)) do
        {{Map.put(root, v, root[w]), align |> Map.put(w, v) |> Map.put(v, root[w])}, context.pos[w]}
      else
        acc
      end
    end)
  end

  # The neighbours `v` may align with: those joined to it by a segment that is
  # among the heaviest of `v`'s segments in the sweep direction AND among the
  # heaviest of the neighbour's segments in the opposite direction.
  defp heaviest(context, v) do
    top = top_weight(context, v, context.neighbours)

    Enum.filter(context.neighbours.(context.graph, v), fn w ->
      weight = context.weights[pair(v, w)]
      weight == top and weight == top_weight(context, w, context.opposite)
    end)
  end

  defp top_weight(context, v, neighbours) do
    context.graph |> neighbours.(v) |> Enum.map(&context.weights[pair(v, &1)]) |> Enum.max(fn -> nil end)
  end

  # Places blocks as far left as separation allows (pass 1, topological order of
  # the block graph), then pulls each block right toward its successors to
  # remove unused space (pass 2, reverse order).
  defp horizontal_compaction(layers, root, sep) do
    seps =
      for layer <- layers, {u, v} <- Enum.zip(layer, Enum.drop(layer, 1)), reduce: %{} do
        seps -> Map.update(seps, {root[u], root[v]}, sep.(u, v), &max(&1, sep.(u, v)))
      end

    blocks = layers |> List.flatten() |> Enum.map(&root[&1]) |> Enum.uniq()
    preds = Enum.group_by(seps, fn {{_, v}, _} -> v end, fn {{u, _}, w} -> {u, w} end)
    succs = Enum.group_by(seps, fn {{u, _}, _} -> u end, fn {{_, v}, w} -> {v, w} end)
    order = block_order(blocks, preds, succs)

    xs =
      Enum.reduce(order, %{}, fn block, xs ->
        x = preds |> Map.get(block, []) |> Enum.map(fn {u, w} -> xs[u] + w end) |> Enum.max(fn -> 0 end)
        Map.put(xs, block, x)
      end)

    xs =
      order
      |> Enum.reverse()
      |> Enum.reduce(xs, &pull_right(&1, &2, Map.get(succs, &1, [])))

    Map.new(root, fn {v, r} -> {v, xs[r]} end)
  end

  defp pull_right(_block, xs, []), do: xs

  defp pull_right(block, xs, out) do
    limit = out |> Enum.map(fn {v, w} -> xs[v] - w end) |> Enum.min()
    Map.update!(xs, block, &max(&1, limit))
  end

  defp block_order(blocks, preds, succs) do
    indegree = Map.new(blocks, &{&1, length(Map.get(preds, &1, []))})
    order = kahn(Enum.filter(blocks, &(indegree[&1] == 0)), succs, indegree, [])
    if length(order) != length(blocks), do: raise("Dagre.Position: block graph has a cycle")
    order
  end

  defp kahn([], _succs, _indegree, acc), do: Enum.reverse(acc)

  defp kahn([block | rest], succs, indegree, acc) do
    {indegree, ready} =
      succs
      |> Map.get(block, [])
      |> Enum.reduce({indegree, []}, fn {v, _}, {indegree, ready} ->
        indegree = Map.update!(indegree, v, &(&1 - 1))
        if indegree[v] == 0, do: {indegree, [v | ready]}, else: {indegree, ready}
      end)

    kahn(rest ++ Enum.reverse(ready), succs, indegree, [block | acc])
  end

  defp separation(graph, u, v, {nodesep, edgesep}) do
    gap = fn node -> if dummy?(graph, node), do: edgesep, else: nodesep end
    right_extent(graph, u) + gap.(u) / 2 + gap.(v) / 2 + left_extent(graph, v)
  end

  # Shifts every candidate onto the narrowest one: left candidates share its
  # minimum x, right candidates its maximum.
  defp align_to_narrowest(_graph, [{_, xs} | _] = candidates) when map_size(xs) == 0, do: candidates

  defp align_to_narrowest(graph, candidates) do
    {_, narrowest} = Enum.min_by(candidates, fn {_, xs} -> extent(graph, xs) end)
    low = narrowest |> Map.values() |> Enum.min()
    high = narrowest |> Map.values() |> Enum.max()

    Enum.map(candidates, fn
      {:left, xs} -> {:left, shift(xs, low - (xs |> Map.values() |> Enum.min()))}
      {:right, xs} -> {:right, shift(xs, high - (xs |> Map.values() |> Enum.max()))}
    end)
  end

  defp extent(graph, xs) do
    {lo, hi} =
      Enum.reduce(xs, {nil, nil}, fn {v, x}, {lo, hi} ->
        {min_of(lo, x - left_extent(graph, v)), max_of(hi, x + right_extent(graph, v))}
      end)

    hi - lo
  end

  defp min_of(nil, x), do: x
  defp min_of(a, x), do: min(a, x)
  defp max_of(nil, x), do: x
  defp max_of(a, x), do: max(a, x)

  defp shift(xs, delta), do: Map.new(xs, fn {v, x} -> {v, x + delta} end)

  defp balance([{_, first} | _] = candidates) do
    Map.new(first, fn {v, _} ->
      [_, a, b, _] = candidates |> Enum.map(fn {_, xs} -> xs[v] end) |> Enum.sort()
      {v, (a + b) / 2}
    end)
  end

  defp dummy?(graph, v), do: not is_nil(Map.get(Graph.node(graph, v), :dummy))

  # A node is aligned on the centre of its caller box (`:box`), which sits at the
  # left edge of its layout box; any extra layout width (self-loop room) extends
  # to the right. Without a `:box` the two coincide.
  defp anchor_width(graph, v) do
    case Graph.node(graph, v) do
      %{box: {w, _}} -> w
      attrs -> attrs.width
    end
  end

  defp left_extent(graph, v), do: anchor_width(graph, v) / 2
  defp right_extent(graph, v), do: Graph.node(graph, v).width - anchor_width(graph, v) / 2

  defp pair(a, b) when a <= b, do: {a, b}
  defp pair(a, b), do: {b, a}

  defp layer_positions(layer), do: layer |> Enum.with_index() |> Map.new()
end
