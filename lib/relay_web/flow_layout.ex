defmodule RelayWeb.FlowLayout do
  @moduledoc """
  Deterministic, pure vertical layout for a flow graph — no stored coordinates, no dragging.
  Derives the shape from graph structure alone: the `:succeeded` spine runs straight down a
  single column, off-spine rework nodes sit in a second column on their partner's row, anything
  unreachable is parked below, and every backward edge (loop or failure) is packed into a
  right-hand gutter lane so they stop piling on top of each other.

  Consumed by the flow editor (`RelayWeb.FlowEditorLive`) and the storybook story. It is NOT
  reused by the run panel today.

  Reference: the layout has intentionally diverged from
  `docs/designs/Relay Flow Editor.dc.html` as of RLY-186 — the artboard shows the old
  serpentine shape, so its node positions and edge paths are stale and must not be chased. The
  artboard remains authoritative for node card shapes/sizes per type, the `@type_meta` colour
  tokens, edge stroke colours, the dashed `:failed` stroke, arrowheads and label-pill styling
  (all owned by `RelayWeb.FlowGraphComponents`).
  """

  # No `use Boundary` — this is a pure web-layer helper inside the RelayWeb boundary, like
  # CoreComponents/FlowSettingsComponents. Declaring a nested sub-boundary here would fail
  # compilation.

  @spine_col 0
  @side_col 1
  # Column pitch. The gap between a spine node and its side (fix) node is @col_w − @node_w =
  # 120px for a full-width reviewer; it must stay wide enough for the "failed · max N" edge label
  # (~92px) to sit in it fully legible, clear of both opaque node boxes (RLY-186 acceptance #3).
  @col_w 270
  @row_h 124
  @node_w 150
  @node_h 56
  @gate_w 118
  @gate_h 76
  @gutter_gap 24
  @lane_w 22
  @origin_x 8
  @origin_y 44

  @doc """
  Box `{w, h}` for a node type — the single source of node dimensions for both this layout and
  the renderer. Gate nodes are the diamond (118×76); everything else is the default box (150×56).
  """
  def node_size(:gate), do: {@gate_w, @gate_h}
  def node_size(_type), do: {@node_w, @node_h}

  @spec layout([map], [map]) :: %{
          positions: %{optional(String.t()) => {integer, integer}},
          size: {integer, integer},
          routes: %{optional(integer) => map},
          start_point: {integer, integer},
          done_point: {integer, integer}
        }
  def layout(nodes, edges) do
    types = Map.new(nodes, fn n -> {key(n), node_type(n)} end)
    node_keys = MapSet.new(Map.keys(types))
    spine = spine_order(edges, node_keys)
    grid = place(nodes, edges, spine)

    positions =
      Map.new(grid, fn {k, {r, c}} ->
        {w, _h} = node_size(Map.fetch!(types, k))
        {k, {col_center(c) - div(w, 2), @origin_y + r * @row_h}}
      end)

    kinds =
      edges
      |> Enum.with_index()
      |> Map.new(fn {e, i} -> {i, route_kind(e, grid)} end)

    max_right = Enum.max([col_center(@spine_col) + div(@node_w, 2) | rights(grid, types)])
    max_bottom = Enum.max([@origin_y | bottoms(grid, types)])
    gutter_base = max_right + @gutter_gap

    lane_of = assign_lanes(back_intervals(edges, kinds, grid))
    max_lane = Enum.max([-1 | Map.values(lane_of)])

    routes =
      Map.new(kinds, fn {i, kind} ->
        lane = Map.get(lane_of, i)
        {i, %{kind: kind, lane: lane, lane_x: lane && gutter_base + lane * @lane_w}}
      end)

    done_pt = done_point(spine, types)

    width = if(max_lane >= 0, do: gutter_base + max_lane * @lane_w, else: max_right) + @gutter_gap
    height = Enum.max([max_bottom, elem(done_pt, 1)]) + @gutter_gap

    %{
      positions: positions,
      size: {width, height},
      routes: routes,
      start_point: start_point(),
      done_point: done_pt
    }
  end

  # ---- node placement ----

  defp place(nodes, edges, spine) do
    spine_grid = spine |> Enum.with_index() |> Map.new(fn {k, i} -> {k, {i, @spine_col}} end)
    spine_set = MapSet.new(spine)
    side = nodes |> Enum.map(&key/1) |> Enum.reject(&MapSet.member?(spine_set, &1))

    {placed, _taken} =
      Enum.reduce(side, {spine_grid, MapSet.new(Map.values(spine_grid))}, fn k, {grid, taken} ->
        case partner_row(k, edges, grid) do
          nil ->
            {grid, taken}

          r ->
            cell = first_free(r, @side_col, taken)
            {Map.put(grid, k, cell), MapSet.put(taken, cell)}
        end
      end)

    parked = nodes |> Enum.map(&key/1) |> Enum.reject(&Map.has_key?(placed, &1))
    base = 1 + max_row(placed)

    parked
    |> Enum.with_index()
    |> Enum.reduce(placed, fn {k, i}, acc -> Map.put(acc, k, {base + i, @side_col}) end)
  end

  # A side node's partner is the node it fails INTO (entry, preferred) else the node its
  # `:succeeded` edge returns to. We use the partner's row; the entry partner wins when both
  # exist and their rows differ (the node that fails into it defines its row).
  defp partner_row(key, edges, grid) do
    entry =
      Enum.find_value(edges, fn
        %{to: ^key, from: from, on: :failed} -> Map.get(grid, from)
        _ -> nil
      end)

    ret =
      Enum.find_value(edges, fn
        %{from: ^key, to: to, on: :succeeded} -> Map.get(grid, to)
        _ -> nil
      end)

    case entry || ret do
      {r, _c} -> r
      _ -> nil
    end
  end

  defp first_free(r, c, taken) do
    if MapSet.member?(taken, {r, c}), do: first_free(r, c + 1, taken), else: {r, c}
  end

  # ---- spine discovery (unchanged behaviour) ----

  # Follow the single start edge's target, then first-unvisited :succeeded edges to "done".
  defp spine_order(edges, node_keys) do
    start = Enum.find(edges, &(&1.from == "start"))
    walk(start && start.to, edges, node_keys, MapSet.new(), [])
  end

  defp walk(nil, _edges, _keys, _seen, acc), do: Enum.reverse(acc)
  defp walk("done", _edges, _keys, _seen, acc), do: Enum.reverse(acc)

  defp walk(key, edges, node_keys, seen, acc) do
    cond do
      MapSet.member?(seen, key) ->
        Enum.reverse(acc)

      not MapSet.member?(node_keys, key) ->
        Enum.reverse(acc)

      true ->
        seen = MapSet.put(seen, key)
        next = next_spine_target(edges, key, seen)
        walk(next, edges, node_keys, seen, [key | acc])
    end
  end

  # A `foreach` loop head may leave TWO :succeeded edges — one guarded `foreach_remaining` back
  # to itself, one guarded `foreach_exhausted` onward — so the first-listed edge is not
  # necessarily the spine's next step. Prefer whichever candidate does NOT loop back to an
  # already-visited node (`seen` already includes `key`, so a self-loop is excluded too); the
  # spine should keep moving forward.
  defp next_spine_target(edges, key, seen) do
    candidates = for %{from: ^key, to: to} = e <- edges, Map.get(e, :on) == :succeeded, do: to
    Enum.find(candidates, &(not MapSet.member?(seen, &1))) || List.first(candidates)
  end

  # ---- edge route kinds ----

  defp route_kind(%{from: "start"}, _grid), do: :enter
  defp route_kind(%{to: "done"}, _grid), do: :exit

  defp route_kind(e, grid) do
    {fr, fc} = Map.fetch!(grid, e.from)
    {tr, tc} = Map.fetch!(grid, e.to)

    cond do
      tr > fr -> :drop
      tr == fr and tc > fc -> :side_out
      tr == fr and tc < fc -> :side_back
      true -> :gutter
    end
  end

  # ---- back-edge lane packing ----

  # Row interval of every :gutter edge, keyed by edge index.
  defp back_intervals(edges, kinds, grid) do
    edges
    |> Enum.with_index()
    |> Enum.filter(fn {_e, i} -> Map.get(kinds, i) == :gutter end)
    |> Enum.map(fn {e, i} ->
      {fr, _} = Map.fetch!(grid, e.from)
      {tr, _} = Map.fetch!(grid, e.to)
      {i, {min(fr, tr), max(fr, tr)}}
    end)
  end

  # Greedy interval pack: sort by span ascending (tie-break source row then edge index for
  # determinism), assign each edge the lowest lane whose members' intervals don't overlap it.
  # Nested edges get distinct lanes with the longest outermost; row-disjoint edges share a lane.
  defp assign_lanes(intervals) do
    intervals
    |> Enum.sort_by(fn {i, {lo, hi}} -> {hi - lo, lo, i} end)
    |> Enum.reduce({%{}, %{}}, fn {i, iv}, {lane_of, lanes} ->
      lane = lowest_free_lane(iv, lanes, 0)
      {Map.put(lane_of, i, lane), Map.update(lanes, lane, [iv], &[iv | &1])}
    end)
    |> elem(0)
  end

  defp lowest_free_lane(iv, lanes, n) do
    if Enum.any?(Map.get(lanes, n, []), &overlap?(&1, iv)),
      do: lowest_free_lane(iv, lanes, n + 1),
      else: n
  end

  defp overlap?({lo1, hi1}, {lo2, hi2}), do: lo1 <= hi2 and lo2 <= hi1

  # ---- endpoints & canvas geometry ----

  defp start_point, do: {col_center(@spine_col), @origin_y - 24}

  defp done_point([], _types), do: {col_center(@spine_col), @origin_y}

  defp done_point(spine, types) do
    last = List.last(spine)
    row = length(spine) - 1
    {_w, h} = node_size(Map.fetch!(types, last))
    {col_center(@spine_col), @origin_y + row * @row_h + h + 24}
  end

  defp rights(grid, types) do
    for {k, {_r, c}} <- grid, do: col_center(c) + div(elem(node_size(Map.fetch!(types, k)), 0), 2)
  end

  defp bottoms(grid, types) do
    for {k, {r, _c}} <- grid, do: @origin_y + r * @row_h + elem(node_size(Map.fetch!(types, k)), 1)
  end

  defp col_center(c), do: @origin_x + c * @col_w + div(@node_w, 2)

  defp max_row(grid) when map_size(grid) == 0, do: -1
  defp max_row(grid), do: grid |> Map.values() |> Enum.map(&elem(&1, 0)) |> Enum.max()

  defp key(%{key: k}), do: k
  defp node_type(%{type: t}), do: t
  defp node_type(_), do: :agent
end
