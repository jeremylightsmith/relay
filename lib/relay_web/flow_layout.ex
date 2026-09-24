defmodule RelayWeb.FlowLayout do
  @moduledoc """
  Deterministic, pure layout for a flow graph — no stored coordinates, no dragging. A thin adapter
  over the vendored `dagre_ex` (`Dagre`, `vendor/dagre_ex`, RE332), which owns the layout
  algorithm (RE333): every flow node becomes a dagre node sized by `node_size/1`; `start` and
  `done` join as real, small nodes so they are ranked, ordered and routed like anything else; and
  every edge except a start edge carries its label's measured size, so dagre reserves real room
  for the pill and no label can land on a node or another label.

  The **spine** — the happy path a reader traces first — is weighted heavier than every other edge
  (`spine/1`, RE341), and dagre lays a heavy path out as one vertical line. The spine is the walk
  from the start edge along each node's `:succeeded` edge until `done`. The foreach loop-back
  (`when: :foreach_remaining`) is never a step, since it points back up the flow; and the walk
  follows only ONE `:succeeded` edge per node. A fix node's `:succeeded` edge back into the main
  line (`sync_fix → precommit`) is left light on purpose: weighting it too would give the rejoin
  node two heavy in-edges, and dagre can straighten a heavy path but not a heavy fork.

  `layout/2` returns:

    * `positions` — flow node key → top-left `{x, y}` (the flow's own nodes only; `start` and
      `done` are internal to the layout)
    * `size` — the canvas `{w, h}`
    * `routes` — edge index (position in the input `edges` list) → `%{points:, label:}`.
      `points` is an axis-aligned polyline from the source node to the target node; `label` is
      the centre of the edge's pill, or `nil` for a start edge (which carries no pill). Where
      several edges meet one side of a node, each gets its own port on that border, spread
      left→right in the order the lines head off (RE340, `port_span/2`); a lone edge keeps the
      side's centre
    * `start_point` — where the entry edge leaves; `done_point` — done's top-centre, where a
      sole exit edge lands (several exit edges spread along done's top border)
    * `parks` — the source of every edge into the `needs_input` park. Those edges have no
      geometry and are left out of `routes`; the renderer badges their source instead (RE330)

  Consumed by the flow editor (`RelayWeb.FlowEditorLive`) and the storybook story. It is NOT
  reused by the run panel today.

  Reference: `dagre_ex` owns layout. The layout has intentionally diverged from
  `docs/designs/Relay Flow Editor.dc.html` since RLY-186 — the artboard shows the old serpentine
  shape, so its node positions and edge paths are stale and must not be chased. The artboard
  remains authoritative for node card shapes/sizes per type, the `@type_meta` colour tokens, edge
  stroke colours, the dashed `:failed` stroke, arrowheads and label-pill styling (all owned by
  `RelayWeb.FlowGraphComponents`).
  """

  # No `use Boundary` — this is a pure web-layer helper inside the RelayWeb boundary, like
  # CoreComponents/FlowSettingsComponents. Declaring a nested sub-boundary here would fail
  # compilation.

  @node_w 150
  @node_h 56
  @gate_w 118
  @gate_h 76

  # `start` is an invisible anchor the entry edge leaves from. `done` is wide and tall enough to
  # hold the renderer's "lands → <stage>" pill, which sits just below `done_point` (its top edge).
  @start_w 16
  @start_h 16
  @done_w 180
  @done_h 40

  # dagre separation constants, tuned by eye against the storybook. When any edge has a label,
  # dagre gives labels their own layer and halves `ranksep` per gap.
  @ranksep 68
  @nodesep 24
  @edgesep 12

  # dagre weight of a spine edge; every other edge keeps dagre's default of 1. dagre compares
  # weights strictly, so any value above 1 lays the spine out identically.
  @spine_weight 2

  # dagre's bounding box starts at {0, 0}; pad every side so selection rings, park badges and
  # arrowheads never clip against the canvas edge.
  @pad 16

  # Port spreading (RE340) — see `port_span/2`. @human_shoulder_pct mirrors the 14%/86% vertices
  # of the `:human` hexagon's clip-path in `RelayWeb.FlowGraphComponents`.
  @port_inset 18
  @human_shoulder_pct 14
  @human_port_inset 6

  # Edge-label measurement. dagre needs each label's size BEFORE layout, but text width is a
  # browser fact. The pill is a fixed 9.5px ui-monospace face (FlowGraphComponents'
  # `edge_label_style/2`) with 6px horizontal padding, so width ≈ characters × advance width +
  # padding. This is an APPROXIMATION — accurate to a pixel or two for the ASCII labels the flow
  # vocabulary produces, looser for wide glyphs — and deliberately so: a browser round-trip to
  # measure exactly is not worth it for a diagram whose labels come from a tiny fixed vocabulary.
  # @label_h is the pill's rendered height (a 9.5px line plus 2 × 2px vertical padding, rounded up).
  @label_char_w 5.7
  @label_pad_x 12
  @label_h 16

  # RLY-194's `to`-only edge-endpoint sentinel. It is a park, not a terminal: an edge to it has
  # no geometry and is left out of `routes` entirely (RE330).
  @park "needs_input"

  @doc """
  Box `{w, h}` for a node type — the single source of node dimensions for both this layout and
  the renderer. Gate nodes are the diamond (118×76); everything else is the default box (150×56).
  """
  def node_size(:gate), do: {@gate_w, @gate_h}
  def node_size(_type), do: {@node_w, @node_h}

  @doc """
  The text of an edge's label pill — outcome, then the foreach guard's human wording, then
  `max N`, joined with " · " (a start edge's is `""`). Lives here rather than in the renderer
  because the layout measures exactly this text; the renderer draws it.
  """
  def edge_label(edge) do
    [to_string(Map.get(edge, :on)), when_label(Map.get(edge, :when)), max_loops_label(Map.get(edge, :max_loops))]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  # Human wording for the foreach guard on the diagram pill. This is a presentation label, not
  # a second copy of Schemas.Flow.Edge.when_values/0 — the closed set is owned there.
  defp when_label(:foreach_remaining), do: "while tasks remain"
  defp when_label(:foreach_exhausted), do: "all tasks done"
  defp when_label(_), do: nil

  defp max_loops_label(max) when is_integer(max), do: "max #{max}"
  defp max_loops_label(_), do: nil

  @doc """
  Approximate rendered `{w, h}` of an edge's label pill — see the measurement note above
  `@label_char_w`. Used by `layout/2` to reserve room and by the tests to check collisions.
  """
  def label_size(edge) do
    {ceil(String.length(edge_label(edge)) * @label_char_w) + @label_pad_x, @label_h}
  end

  @spec layout([map], [map]) :: %{
          positions: %{optional(String.t()) => {integer, integer}},
          size: {integer, integer},
          routes: %{optional(integer) => %{points: [{integer, integer}], label: {integer, integer} | nil}},
          start_point: {integer, integer},
          done_point: {integer, integer},
          parks: MapSet.t(String.t())
        }
  def layout(nodes, edges) do
    # The editor's working copy is laid out on every keystroke, so it can transiently hold
    # duplicate keys (mid-rename) or edges to nodes that don't exist. Dagre raises on both, so
    # keep the first node per key and leave dangling edges out of the routes (as parks are).
    nodes = Enum.uniq_by(nodes, &key/1)
    known = MapSet.new(nodes, &key/1)

    drawn =
      edges
      |> Enum.with_index()
      |> Enum.reject(fn {edge, _i} ->
        edge.to == @park or not known_endpoint?(edge.from, known) or not known_endpoint?(edge.to, known)
      end)

    spine = spine(edges)

    result =
      Dagre.layout(
        nodes: dagre_nodes(nodes),
        edges: Enum.map(drawn, &dagre_edge(&1, spine)),
        rankdir: :tb,
        ranksep: @ranksep,
        nodesep: @nodesep,
        edgesep: @edgesep
      )

    {w, h} = result.size
    types = Map.new(nodes, &{{:node, key(&1)}, node_type(&1)})

    routes =
      drawn
      |> Map.new(fn {edge, i} -> {i, shifted(Map.fetch!(result.edges, i), edge)} end)
      |> spread_ports(result.nodes, types, spine)
      |> Map.new(fn {i, route} -> {i, %{points: orthogonal(route.points), label: route.label}} end)

    %{
      positions: Map.new(nodes, fn node -> {key(node), top_left(Map.fetch!(result.nodes, {:node, key(node)}))} end),
      size: {w + 2 * @pad, h + 2 * @pad},
      routes: routes,
      start_point: bottom_center(Map.fetch!(result.nodes, :start)),
      done_point: top_center(Map.fetch!(result.nodes, :done)),
      parks: for(%{to: @park, from: from} <- edges, into: MapSet.new(), do: from)
    }
  end

  @doc """
  The spine of a flow: indexes into `edges` of the walk from the start edge along each node's
  `:succeeded` edge (never the foreach loop-back), stopping at a node with no such edge or one the
  walk already visited. When a node has several, the first in `edges` order is taken.
  """
  @spec spine([map]) :: MapSet.t(non_neg_integer)
  def spine(edges), do: walk_spine(Enum.with_index(edges), "start", MapSet.new(["start"]), MapSet.new())

  defp walk_spine(indexed, from, visited, spine) do
    case Enum.find(indexed, fn {edge, _i} -> edge.from == from and spine_step?(edge) end) do
      {edge, i} ->
        if MapSet.member?(visited, edge.to),
          do: spine,
          else: walk_spine(indexed, edge.to, MapSet.put(visited, edge.to), MapSet.put(spine, i))

      nil ->
        spine
    end
  end

  defp spine_step?(%{from: "start"}), do: true
  defp spine_step?(edge), do: Map.get(edge, :on) == :succeeded and Map.get(edge, :when) != :foreach_remaining

  defp known_endpoint?(key, known), do: key in ["start", "done"] or MapSet.member?(known, key)

  defp dagre_nodes(nodes) do
    real =
      Enum.map(nodes, fn node ->
        {w, h} = node_size(node_type(node))
        %{id: {:node, key(node)}, width: w, height: h}
      end)

    real ++ [%{id: :start, width: @start_w, height: @start_h}, %{id: :done, width: @done_w, height: @done_h}]
  end

  # A start edge draws no pill (the renderer never labels it), so it reserves no label room.
  defp dagre_edge({%{from: "start"} = edge, i}, spine),
    do: weighted(%{id: i, from: endpoint(edge.from), to: endpoint(edge.to)}, i, spine)

  defp dagre_edge({edge, i}, spine) do
    {w, h} = label_size(edge)
    weighted(%{id: i, from: endpoint(edge.from), to: endpoint(edge.to), label: %{width: w, height: h}}, i, spine)
  end

  defp weighted(dagre_edge, i, spine),
    do: if(MapSet.member?(spine, i), do: Map.put(dagre_edge, :weight, @spine_weight), else: dagre_edge)

  # `start` and `done` are the edge-endpoint sentinels; dagre ids are namespaced so a node an
  # author transiently names "done" (the editor blocks saving it) still lays out instead of
  # colliding with the sentinel.
  defp endpoint("start"), do: :start
  defp endpoint("done"), do: :done
  defp endpoint(key), do: {:node, key}

  # A drawn edge's dagre route shifted onto the padded canvas, tagged with its dagre endpoint ids
  # so `spread_ports/3` can find the node boxes it touches.
  defp shifted(%{points: points, label: label}, edge) do
    %{points: Enum.map(points, &shift/1), label: label && shift(label), from: endpoint(edge.from), to: endpoint(edge.to)}
  end

  defp shift({x, y}), do: {x + @pad, y + @pad}

  @doc """
  The usable `{left, right}` x-span for edge ports on the top/bottom border of a node of `type`
  whose laid-out box is `{x, y, w, h}` (RE340). Inset so a port never sits on a rounded corner,
  the accent border or a slanted face:

    * default box (and `done`) — #{@port_inset}px in from each side, clearing the 11px corner
      radius and the 4px accent border;
    * `:human` hexagon — its flat top/bottom (14%–86% of the width, the renderer's clip-path),
      a further #{@human_port_inset}px in;
    * `:gate` diamond — the middle half of the width; its top/bottom is a vertex, so ports fan
      out along the faces beside it (`layout/2` moves each port's y onto the face);
    * `:start` — a 16px invisible anchor, too small to spread: both ends are its centre.
  """
  def port_span(:gate, {x, _y, w, _h}), do: {x + div(w, 4), x + w - div(w, 4)}
  def port_span(:start, {x, _y, w, _h}), do: {x + div(w, 2), x + div(w, 2)}

  def port_span(:human, {x, _y, w, _h}) do
    flat = div(w * @human_shoulder_pct, 100) + @human_port_inset
    {x + flat, x + w - flat}
  end

  def port_span(_type, {x, _y, w, _h}), do: {x + @port_inset, x + w - @port_inset}

  defp top_left(%{x: x, y: y}), do: shift({x, y})
  defp top_center(%{x: x, y: y, width: w}), do: shift({x + div(w, 2), y})
  defp bottom_center(%{x: x, y: y, width: w, height: h}), do: shift({x + div(w, 2), y + h})

  # ---- port spreading (RE340) ----
  #
  # dagre anchors every edge at its source's bottom-centre and its target's top-centre, so on a
  # node with several edges on one side every line converges on one pixel. This pass gives each
  # edge its OWN port on that side. It runs on the shifted dagre points, before `orthogonal/1`.
  #
  #   1. Collect endpoints: a route's first point sits on its source, its last on its target.
  #      The side is read off the geometry (`:top` / `:bottom` of the node's box), which covers
  #      a reversed loop-back edge — it leaves its source's top and lands on its target's bottom
  #      — without special-casing it. Self-loops (routed off the right side) are left untouched.
  #   2. Group by {node, side}. A group of one keeps dagre's centre anchor, so a plain chain is
  #      drawn exactly as before; `start` is too small to spread, so its edges share its centre.
  #   3. Order each group left→right by the x the line heads to past its stub, then the far
  #      endpoint's x, then edge index — deterministic, and no two lines cross at the node.
  #   4. Distribute the n ports evenly over the side's `port_span/2`:
  #      x_i = left + span_w * (i + 1) / (n + 1). A gate port's y moves onto the diamond's face.
  #   5. Rebuild that end of the route as a vertical stub from the port to the edge of the node's
  #      rank band, dropping dagre's own anchor and band point. The hop from the stub to the next
  #      waypoint turns diagonal and `orthogonal/1` doglegs it in the inter-rank gap.
  defp spread_ports(routes, dagre_nodes, types, spine) do
    boxes = Map.new(dagre_nodes, fn {id, node} -> {id, shift_box(node)} end)
    bands = rank_bands(dagre_nodes, boxes)

    routes
    |> endpoints(boxes)
    |> Enum.group_by(&{&1.id, &1.side})
    |> Enum.reject(fn {{id, _side}, group} -> id == :start or length(group) == 1 end)
    |> Enum.flat_map(fn {{id, side}, group} ->
      assign_ports(group, Map.get(types, id, id), Map.fetch!(boxes, id), side, band_edge(bands, id, side), spine)
    end)
    |> Enum.reduce(routes, fn {i, role, port, band_y}, routes ->
      Map.update!(routes, i, &%{&1 | points: restub(&1.points, role, port, band_y)})
    end)
  end

  defp endpoints(routes, boxes) do
    for {i, route} <- routes,
        route.from != route.to,
        {role, id} <- [source: route.from, target: route.to],
        point = if(role == :source, do: hd(route.points), else: List.last(route.points)),
        side = side(point, Map.fetch!(boxes, id)),
        side != nil do
      %{index: i, role: role, id: id, side: side, point: point, points: route.points}
    end
  end

  # A spine edge (RE341) keeps the node's centre — the column the spine is laid out on — so it
  # stays one vertical line; the other edges spread evenly either side of it, in the same
  # crossing-free order. With no spine edge in the group, or on a gate (whose top/bottom border
  # is a vertex, so its ports fan out along the faces), all ports spread evenly.
  defp assign_ports(group, type, box, side, band_y, spine) do
    {left, right} = port_span(type, box)
    {bx, _by, bw, _bh} = box
    centre = bx + div(bw, 2)
    sorted = Enum.sort_by(group, &{heading_x(&1), far_x(&1), &1.index})

    xs =
      case pinned_index(type, sorted, spine) do
        nil -> spread(left, right, length(sorted))
        p -> spread(left, centre, p) ++ [centre] ++ spread(centre, right, length(sorted) - p - 1)
      end

    sorted
    |> Enum.zip(xs)
    |> Enum.map(fn {e, x} -> {e.index, e.role, {x, border_y(type, box, side, x)}, band_y} end)
  end

  defp pinned_index(:gate, _sorted, _spine), do: nil
  defp pinned_index(_type, sorted, spine), do: Enum.find_index(sorted, &MapSet.member?(spine, &1.index))

  # `n` x positions evenly strictly between `from` and `to`.
  defp spread(from, to, n), do: Enum.map(1..n//1, &(from + div((to - from) * &1, n + 1)))

  defp shift_box(%{x: x, y: y, width: w, height: h}) do
    {sx, sy} = shift({x, y})
    {sx, sy, w, h}
  end

  # Each node's rank band `{top, bottom}`. dagre centres every box in its band, so the rank's
  # tallest box spans the band exactly.
  defp rank_bands(dagre_nodes, boxes) do
    by_rank =
      dagre_nodes
      |> Enum.group_by(fn {_id, node} -> node.rank end, fn {id, _node} -> Map.fetch!(boxes, id) end)
      |> Map.new(fn {rank, rank_boxes} ->
        {rank,
         {rank_boxes |> Enum.map(fn {_, y, _, _} -> y end) |> Enum.min(),
          rank_boxes |> Enum.map(fn {_, y, _, h} -> y + h end) |> Enum.max()}}
      end)

    Map.new(dagre_nodes, fn {id, node} -> {id, Map.fetch!(by_rank, node.rank)} end)
  end

  defp band_edge(bands, id, :top), do: bands |> Map.fetch!(id) |> elem(0)
  defp band_edge(bands, id, :bottom), do: bands |> Map.fetch!(id) |> elem(1)

  defp side({_x, y}, {_bx, y, _bw, _bh}), do: :top
  defp side({_x, y}, {_bx, by, _bw, bh}) when y == by + bh, do: :bottom
  defp side(_point, _box), do: nil

  # The x the line heads to once it leaves the endpoint's vertical: the first point off it, or
  # the endpoint's own x for a route that runs straight.
  defp heading_x(%{role: :source, points: points}), do: first_off_vertical(points)
  defp heading_x(%{role: :target, points: points}), do: points |> Enum.reverse() |> first_off_vertical()

  defp first_off_vertical([{x0, _} | rest]) do
    case Enum.find(rest, fn {x, _} -> x != x0 end) do
      {x, _} -> x
      nil -> x0
    end
  end

  defp far_x(%{role: :source, points: points}), do: points |> List.last() |> elem(0)
  defp far_x(%{role: :target, points: [{x, _} | _]}), do: x

  # On a gate the top/bottom border is a vertex; a port beside it sits on the diamond's face,
  # `h * |dx| / w` in from the vertex.
  defp border_y(:gate, {x, y, w, h}, side, px) do
    rise = div(h * abs(px - (x + div(w, 2))), w)
    if side == :top, do: y + rise, else: y + h - rise
  end

  defp border_y(_type, {_x, y, _w, _h}, :top, _px), do: y
  defp border_y(_type, {_x, y, _w, h}, :bottom, _px), do: y + h

  # Replace one end of `points` with `port` plus a vertical stub to the band edge.
  defp restub([{x0, _} | rest], :source, {px, _} = port, band_y),
    do: Enum.dedup([port, {px, band_y} | drop_band_point(rest, x0, band_y)])

  defp restub(points, :target, port, band_y),
    do: points |> Enum.reverse() |> restub(:source, port, band_y) |> Enum.reverse()

  defp drop_band_point([{x0, band_y} | rest], x0, band_y), do: rest
  defp drop_band_point(points, _x0, _band_y), do: points

  # dagre's polylines are waypoints, not guaranteed axis-aligned. Snap each diagonal hop to a
  # vertical–horizontal–vertical dogleg at its mid-height, then drop repeated and collinear
  # points, so the renderer's rounded-corner builder (which assumes axis alignment) applies as-is.
  # Dagre's waypoints are kept (snapping only adds doglegs between them), and the label point is
  # dagre's own output, so it is not guaranteed to sit exactly on the snapped path.
  defp orthogonal([]), do: []

  defp orthogonal(points) do
    points
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.flat_map(fn
      [{ax, ay}, {bx, by}] when ax != bx and ay != by ->
        mid = div(ay + by, 2)
        [{ax, ay}, {ax, mid}, {bx, mid}]

      [a, _b] ->
        [a]
    end)
    |> Kernel.++([List.last(points)])
    |> Enum.dedup()
    |> drop_collinear()
  end

  defp drop_collinear([a, b, c | rest]) do
    if collinear?(a, b, c),
      do: drop_collinear([a, c | rest]),
      else: [a | drop_collinear([b, c | rest])]
  end

  defp drop_collinear(points), do: points

  defp collinear?({ax, ay}, {bx, by}, {cx, cy}), do: (ax == bx and bx == cx) or (ay == by and by == cy)

  defp key(%{key: k}), do: k
  defp node_type(%{type: t}), do: t
  defp node_type(_), do: :agent
end
