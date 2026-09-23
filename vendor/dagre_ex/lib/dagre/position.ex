defmodule Dagre.Position do
  @moduledoc """
  Coordinate assignment — phase 5 of the pipeline.

  **y** is simple: each rank is a horizontal *band* as tall as its tallest
  member, bands are stacked `ranksep` apart, and every node is centred
  vertically in its band.

  **x** is Brandes–Köpf ("Fast and Simple Horizontal Coordinate Assignment",
  2001), ported from dagre's `position/bk.js`:

    1. mark type-1 conflicts — a non-inner segment crossing an inner segment
       (one between two dummies), so long edges stay straight;
    2. for each of the four directions (up/down × left/right), align every node
       with its median neighbour into vertical *blocks*, then compact the blocks
       horizontally over a block graph whose edge weights are the minimum
       separation between neighbours;
    3. shift the four candidates onto the narrowest one and take, per node, the
       average of the two middle candidate x's.

  Separation respects variable widths: two neighbours on a rank are kept at least
  `width_a / 2 + sep_a / 2 + sep_b / 2 + width_b / 2` apart (centre to centre),
  where `sep` is `edgesep` for a dummy and `nodesep` for a real node.

  Writes `:x` / `:y` (the top-left of the node's `width × height` box, integers,
  translated so the leftmost box starts at 0) and `:band` (`{top, bottom}` of the
  node's rank band) onto every node.
  """

  alias Dagre.Graph
  alias Dagre.Order

  @doc "Positions every node of an ordered, normalized graph. Options: `:ranksep`, `:nodesep`, `:edgesep`."
  @spec run(Graph.t(), keyword()) :: Graph.t()
  def run(%Graph{} = graph, opts) do
    layering = Order.layering(graph)
    centres = x_coordinates(graph, layering, Keyword.fetch!(opts, :nodesep), Keyword.fetch!(opts, :edgesep))
    lefts = Map.new(centres, fn {v, x} -> {v, x - width(graph, v) / 2} end)
    shift = lefts |> Map.values() |> Enum.min(fn -> 0 end)
    bands = bands(graph, layering, Keyword.fetch!(opts, :ranksep))

    layering
    |> Enum.zip(bands)
    |> Enum.reduce(graph, fn {layer, {top, bottom} = band}, graph ->
      Enum.reduce(layer, graph, fn v, graph ->
        attrs = Graph.node(graph, v)
        placed = %{x: floor(lefts[v] - shift), y: top + div(bottom - top - attrs.height, 2), band: band}
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
    conflicts = type1_conflicts(graph, layering)
    sep = &separation(graph, &1, &2, {nodesep, edgesep})

    candidates =
      for vertical <- [:up, :down], horizontal <- [:left, :right] do
        candidate(graph, layering, conflicts, sep, {vertical, horizontal})
      end

    balance(align_to_narrowest(graph, candidates))
  end

  # One of the four Brandes–Köpf candidates. `:down` walks the layers bottom-up
  # aligning with successors; `:right` walks each layer right-to-left and negates
  # the result.
  defp candidate(graph, layering, conflicts, sep, {vertical, horizontal}) do
    layers = if vertical == :up, do: layering, else: Enum.reverse(layering)
    layers = if horizontal == :left, do: layers, else: Enum.map(layers, &Enum.reverse/1)
    neighbours = if vertical == :up, do: &Graph.predecessors/2, else: &Graph.successors/2
    {root, _align} = vertical_alignment(graph, layers, conflicts, neighbours)
    xs = horizontal_compaction(layers, root, sep)
    xs = if horizontal == :right, do: Map.new(xs, fn {v, x} -> {v, -x} end), else: xs
    {horizontal, xs}
  end

  # A type-1 conflict is a non-inner segment crossing an inner segment (both ends
  # dummies). Marking it lets the inner segment win the alignment, which keeps
  # long edges straight.
  defp type1_conflicts(graph, layering) do
    layering
    |> Enum.zip(Enum.drop(layering, 1))
    |> Enum.reduce(MapSet.new(), fn {previous, layer}, conflicts ->
      scan_layer(graph, previous, layer, conflicts)
    end)
  end

  defp scan_layer(graph, previous, layer, conflicts) do
    prev_pos = layer_positions(previous)
    last = List.last(layer)

    {conflicts, _k0, _scan} =
      layer
      |> Enum.with_index()
      |> Enum.reduce({conflicts, 0, 0}, &scan_node(graph, {previous, layer, prev_pos, last}, &1, &2))

    conflicts
  end

  # Scans up to each inner-segment node (and the layer's last node), marking the
  # segments that cross outside the window between two inner segments.
  defp scan_node(graph, {previous, layer, prev_pos, last}, {v, i}, {conflicts, k0, scan} = acc) do
    inner = inner_segment_source(graph, v)

    if inner || v == last do
      k1 = if inner, do: prev_pos[inner], else: length(previous)
      scanned = Enum.slice(layer, scan..i//1)
      {mark_conflicts(graph, scanned, prev_pos, {k0, k1}, conflicts), k1, i + 1}
    else
      acc
    end
  end

  defp mark_conflicts(graph, scanned, prev_pos, {k0, k1}, conflicts) do
    for v <- scanned, u <- Graph.predecessors(graph, v), reduce: conflicts do
      conflicts ->
        pos = prev_pos[u]
        both_dummies? = dummy?(graph, u) and dummy?(graph, v)
        if (pos < k0 or k1 < pos) and not both_dummies?, do: MapSet.put(conflicts, pair(u, v)), else: conflicts
    end
  end

  defp inner_segment_source(graph, v) do
    if dummy?(graph, v), do: graph |> Graph.predecessors(v) |> Enum.find(&dummy?(graph, &1))
  end

  defp vertical_alignment(graph, layers, conflicts, neighbours) do
    pos = for layer <- layers, {v, i} <- Enum.with_index(layer), into: %{}, do: {v, i}
    ids = List.flatten(layers)
    identity = Map.new(ids, &{&1, &1})
    context = %{graph: graph, pos: pos, conflicts: conflicts, neighbours: neighbours}

    Enum.reduce(layers, {identity, identity}, fn layer, acc ->
      {acc, _prev} = Enum.reduce(layer, {acc, -1}, &align_node(context, &1, &2))
      acc
    end)
  end

  # Aligns `v` with its median neighbour(s) in the previous layer, left to right,
  # never crossing an alignment already made on this layer (`prev`).
  defp align_node(context, v, {alignment, prev}) do
    ws = context.graph |> context.neighbours.(v) |> Enum.sort_by(&context.pos[&1])
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

  # Places blocks as far left as separation allows (pass 1, topological order of
  # the block graph), then pulls each block right toward its successors to
  # remove unused space (pass 2, reverse order).
  defp horizontal_compaction(layers, root, sep) do
    weights =
      for layer <- layers, {u, v} <- Enum.zip(layer, Enum.drop(layer, 1)), reduce: %{} do
        weights -> Map.update(weights, {root[u], root[v]}, sep.(u, v), &max(&1, sep.(u, v)))
      end

    blocks = layers |> List.flatten() |> Enum.map(&root[&1]) |> Enum.uniq()
    preds = Enum.group_by(weights, fn {{_, v}, _} -> v end, fn {{u, _}, w} -> {u, w} end)
    succs = Enum.group_by(weights, fn {{u, _}, _} -> u end, fn {{_, v}, w} -> {v, w} end)
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
    width(graph, u) / 2 + gap.(u) / 2 + gap.(v) / 2 + width(graph, v) / 2
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
        half = width(graph, v) / 2
        {min_of(lo, x - half), max_of(hi, x + half)}
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

  defp width(graph, v), do: Graph.node(graph, v).width

  defp pair(a, b) when a <= b, do: {a, b}
  defp pair(a, b), do: {b, a}

  defp layer_positions(layer), do: layer |> Enum.with_index() |> Map.new()
end
