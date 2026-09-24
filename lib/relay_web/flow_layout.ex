defmodule RelayWeb.FlowLayout do
  @moduledoc """
  Deterministic, pure layout for a flow graph — no stored coordinates, no dragging. A thin adapter
  over the vendored `dagre_ex` (`Dagre`, `vendor/dagre_ex`, RE332), which owns the layout
  algorithm (RE333): every flow node becomes a dagre node sized by `node_size/1`; `start` and
  `done` join as real, small nodes so they are ranked, ordered and routed like anything else; and
  every edge except a start edge carries its label's measured size, so dagre reserves real room
  for the pill and no label can land on a node or another label.

  `layout/2` returns:

    * `positions` — flow node key → top-left `{x, y}` (the flow's own nodes only; `start` and
      `done` are internal to the layout)
    * `size` — the canvas `{w, h}`
    * `routes` — edge index (position in the input `edges` list) → `%{points:, label:}`.
      `points` is an axis-aligned polyline from the source node to the target node; `label` is
      the centre of the edge's pill, or `nil` for a start edge (which carries no pill)
    * `start_point` — where the entry edge leaves; `done_point` — where the exit edge lands
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

  # dagre's bounding box starts at {0, 0}; pad every side so selection rings, park badges and
  # arrowheads never clip against the canvas edge.
  @pad 16

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
    drawn = edges |> Enum.with_index() |> Enum.reject(fn {edge, _i} -> edge.to == @park end)

    result =
      Dagre.layout(
        nodes: dagre_nodes(nodes),
        edges: Enum.map(drawn, &dagre_edge/1),
        rankdir: :tb,
        ranksep: @ranksep,
        nodesep: @nodesep,
        edgesep: @edgesep
      )

    {w, h} = result.size

    %{
      positions: Map.new(nodes, fn node -> {key(node), top_left(Map.fetch!(result.nodes, {:node, key(node)}))} end),
      size: {w + 2 * @pad, h + 2 * @pad},
      routes: Map.new(drawn, fn {_edge, i} -> {i, route(Map.fetch!(result.edges, i))} end),
      start_point: bottom_center(Map.fetch!(result.nodes, :start)),
      done_point: top_center(Map.fetch!(result.nodes, :done)),
      parks: for(%{to: @park, from: from} <- edges, into: MapSet.new(), do: from)
    }
  end

  defp dagre_nodes(nodes) do
    real =
      Enum.map(nodes, fn node ->
        {w, h} = node_size(node_type(node))
        %{id: {:node, key(node)}, width: w, height: h}
      end)

    real ++ [%{id: :start, width: @start_w, height: @start_h}, %{id: :done, width: @done_w, height: @done_h}]
  end

  # A start edge draws no pill (the renderer never labels it), so it reserves no label room.
  defp dagre_edge({%{from: "start"} = edge, i}), do: %{id: i, from: endpoint(edge.from), to: endpoint(edge.to)}

  defp dagre_edge({edge, i}) do
    {w, h} = label_size(edge)
    %{id: i, from: endpoint(edge.from), to: endpoint(edge.to), label: %{width: w, height: h}}
  end

  # `start` and `done` are the edge-endpoint sentinels; dagre ids are namespaced so a node an
  # author transiently names "done" (the editor blocks saving it) still lays out instead of
  # colliding with the sentinel.
  defp endpoint("start"), do: :start
  defp endpoint("done"), do: :done
  defp endpoint(key), do: {:node, key}

  defp route(%{points: points, label: label}) do
    %{points: points |> Enum.map(&shift/1) |> orthogonal(), label: label && shift(label)}
  end

  defp shift({x, y}), do: {x + @pad, y + @pad}

  defp top_left(%{x: x, y: y}), do: shift({x, y})
  defp top_center(%{x: x, y: y, width: w}), do: shift({x + div(w, 2), y})
  defp bottom_center(%{x: x, y: y, width: w, height: h}), do: shift({x + div(w, 2), y + h})

  # dagre's polylines are waypoints, not guaranteed axis-aligned. Snap each diagonal hop to a
  # vertical–horizontal–vertical dogleg at its mid-height, then drop repeated and collinear
  # points, so the renderer's rounded-corner builder (which assumes axis alignment) applies as-is.
  # Every dagre waypoint is kept, so a route's label point still lies on its path.
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
