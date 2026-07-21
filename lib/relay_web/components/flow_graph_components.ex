defmodule RelayWeb.FlowGraphComponents do
  @moduledoc """
  The shared flow-graph renderer: absolutely-positioned node divs + an SVG edge layer, laid out
  by `RelayWeb.FlowLayout`. Used interactively by the flow editor and (later, RLY-132) read-only
  by the run panel with live `node_states`. Concrete visual values match
  docs/designs/Relay Flow Editor.dc.html (typeMeta lines ~366-395, edges ~310-363) — the
  artboard is authoritative for node shapes, colours, dashes, arrowheads and label pills, but
  NOT for layout: node positions and edge paths are computed vertically by `FlowLayout` and
  intentionally diverge from the artboard as of RLY-186.

  Nodes/edges may arrive either as `Schemas.Flow.Node`/`Edge` structs (always carry every
  field, nil when unset) or as plain maps straight from `Relay.Flows.DefaultLibrary` (which
  omit optional keys entirely, e.g. the start edge has no `:on` key at all). Every accessor
  below goes through `Map.get/2` so both shapes render without raising.
  """
  use Phoenix.Component

  alias RelayWeb.FlowLayout

  # rounded-corner radius for orthogonal edge turns.
  @corner 8

  # oklch tokens straight from the artboard, keyed by node type.
  @type_meta %{
    agent: %{
      accent: "oklch(0.56 0.16 292)",
      border: "oklch(0.88 0.05 292)",
      fill: "oklch(1 0 0)",
      tag: "AGENT",
      tag_c: "oklch(0.46 0.14 292)",
      tag_bg: "oklch(0.95 0.04 292)"
    },
    shell: %{
      accent: "oklch(0.55 0.02 255)",
      border: "oklch(0.90 0.006 255)",
      fill: "oklch(1 0 0)",
      tag: "SHELL",
      tag_c: "oklch(0.48 0.02 255)",
      tag_bg: "oklch(0.95 0.004 255)"
    },
    gate: %{
      accent: "oklch(0.70 0.13 65)",
      border: "oklch(0.85 0.07 75)",
      fill: "oklch(0.985 0.02 75)",
      tag: "GATE",
      tag_c: "oklch(0.48 0.11 65)",
      tag_bg: nil
    },
    parallel: %{
      accent: "oklch(0.62 0.13 195)",
      border: "oklch(0.87 0.05 195)",
      fill: "oklch(0.985 0.02 195)",
      tag: "PARALLEL",
      tag_c: "oklch(0.42 0.10 195)",
      tag_bg: "oklch(0.95 0.03 195)"
    },
    human: %{
      accent: "oklch(0.60 0.14 250)",
      border: "oklch(0.86 0.06 250)",
      fill: "oklch(0.985 0.02 250)",
      tag: "HUMAN",
      tag_c: "oklch(0.44 0.13 250)",
      tag_bg: "oklch(0.95 0.03 250)"
    }
  }

  # edge stroke color by canonical outcome (start edge = nil → neutral "ok" grey).
  @edge_color %{
    nil => "oklch(0.66 0.02 255)",
    succeeded: "oklch(0.54 0.12 155)",
    failed: "oklch(0.64 0.16 22)",
    partial: "oklch(0.58 0.13 292)",
    needs_input: "oklch(0.70 0.13 65)"
  }

  attr :nodes, :list, required: true
  attr :edges, :list, required: true
  attr :layout, :map, required: true
  attr :selected, :any, default: nil
  attr :interactive?, :boolean, default: false
  attr :node_states, :map, default: %{}
  attr :lands_on, :string, default: nil

  attr :connecting_target?, :boolean,
    default: false,
    doc: "true mid connect-edge, once a source is picked — makes the `done` sentinel a clickable target"

  def flow_graph(assigns) do
    {w, base_h} = assigns.layout.size
    # the "lands → <stage>" pill sits just below `done_point`; reserve room so it never spills
    # past the canvas (and thus can't trigger a stray scrollbar) when it's shown.
    h = if assigns.lands_on, do: base_h + 34, else: base_h
    sizes = Map.new(assigns.nodes, &{&1.key, FlowLayout.node_size(&1.type)})

    geos =
      assigns.edges
      |> Enum.with_index()
      |> Enum.map(fn {edge, i} ->
        %{edge: edge, index: i, geo: edge_geometry(edge, i, assigns.layout, sizes)}
      end)

    assigns = assign(assigns, width: w, height: h, geos: geos)

    ~H"""
    <div
      id="flow-graph"
      class="relative"
      style={"width:#{@width}px;height:#{@height}px;background-image:radial-gradient(oklch(0.90 0.006 255) 1px, transparent 1px);background-size:22px 22px;"}
    >
      <svg
        width={@width}
        height={@height}
        style="position:absolute;inset:0;overflow:visible;pointer-events:none;z-index:1;"
      >
        <defs>
          <marker
            :for={{outcome, color} <- edge_colors()}
            id={"arw-#{outcome || "start"}"}
            markerWidth="9"
            markerHeight="9"
            refX="6"
            refY="3"
            orient="auto"
          >
            <path d="M0,0 L7,3 L0,6 z" fill={color} />
          </marker>
        </defs>
        <path
          :for={g <- @geos}
          d={g.geo.d}
          stroke={edge_color(g.edge)}
          stroke-width="2"
          fill="none"
          stroke-dasharray={if edge_on(g.edge) == :failed, do: "5 4", else: nil}
          marker-end={"url(#arw-#{edge_on(g.edge) || "start"})"}
        />
      </svg>

      <%= for g <- @geos, g.edge.from != "start" do %>
        <button
          :if={@interactive?}
          type="button"
          data-edge={g.index}
          phx-click="select_edge"
          phx-value-index={g.index}
          style={edge_label_style(g.edge, g.geo) <> selected_ring(@selected, {:edge, g.index})}
        >
          {edge_label(g.edge)}
        </button>
        <span :if={!@interactive?} data-edge={g.index} style={edge_label_style(g.edge, g.geo)}>
          {edge_label(g.edge)}
        </span>
      <% end %>

      <div
        :for={node <- @nodes}
        data-node={node.key}
        data-type={node.type}
        phx-click={@interactive? && "select_node"}
        phx-value-key={@interactive? && node.key}
        style={
          node_style(node, position(node, @layout), type_meta(node.type), @selected, @node_states)
        }
      >
        <% meta = type_meta(node.type) %>
        <span :if={node.type not in [:gate, :human]} style={tag_style(meta)}>
          {meta.tag}
        </span>
        <span style="font-size:12.5px;font-weight:600;color:oklch(0.28 0.02 255);text-align:center;line-height:1.15;padding:0 6px;">
          {humanize(node.key)}
        </span>
        <span style="font-size:9.5px;font-family:ui-monospace,monospace;color:oklch(0.58 0.02 255);white-space:nowrap;">
          {sub_label(node)}
        </span>
      </div>

      <div :if={@lands_on} style={lands_style(@layout)}>
        <span style="width:7px;height:7px;border-radius:50%;background:oklch(0.60 0.13 155);"></span>
        lands → {@lands_on}
      </div>

      <button
        :if={@interactive? and @connecting_target?}
        id="flow-node-done"
        type="button"
        data-node="done"
        phx-click="select_node"
        phx-value-key="done"
        style={done_marker_style(@layout)}
      >
        done
      </button>
    </div>
    """
  end

  # ---- style/geometry helpers (private) ----

  # defensive accessors — tolerate raw DefaultLibrary maps that omit optional keys entirely.
  defp edge_on(edge), do: Map.get(edge, :on)
  defp edge_max_loops(edge), do: Map.get(edge, :max_loops)
  defp node_model(node), do: Map.get(node, :model)
  defp node_effort(node), do: Map.get(node, :effort)
  defp node_run(node), do: Map.get(node, :run)

  defp edge_colors, do: @edge_color
  defp edge_color(edge), do: Map.get(@edge_color, edge_on(edge), @edge_color[nil])
  defp type_meta(type), do: Map.fetch!(@type_meta, type)
  defp position(node, layout), do: Map.fetch!(layout.positions, node.key)

  defp node_style(node, {x, y}, meta, selected, node_states) do
    {w, h} = FlowLayout.node_size(node.type)

    base =
      "position:absolute;left:#{x}px;top:#{y}px;z-index:4;cursor:pointer;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;"

    ring = if selected == {:node, node.key}, do: "box-shadow:0 0 0 3px #{meta.accent};", else: ""
    state = state_accent(Map.get(node_states, node.key))

    shape =
      case node.type do
        :gate ->
          "width:#{w}px;height:#{h}px;clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%);background:#{meta.fill};box-shadow:inset 0 0 0 1.5px #{meta.border};"

        :human ->
          "width:#{w}px;height:#{h}px;clip-path:polygon(14% 0,86% 0,100% 50%,86% 100%,14% 100%,0 50%);background:#{meta.fill};box-shadow:inset 0 0 0 1.5px #{meta.border};"

        _ ->
          "width:#{w}px;height:#{h}px;border-radius:11px;background:#{meta.fill};border:1.5px solid #{meta.border};border-left:4px solid #{meta.accent};"
      end

    base <> shape <> ring <> state
  end

  defp state_accent(:running), do: "outline:2px solid oklch(0.56 0.16 292);"
  defp state_accent(:succeeded), do: "outline:2px solid oklch(0.54 0.12 155);"
  defp state_accent(:failed), do: "outline:2px solid oklch(0.64 0.16 22);"
  defp state_accent(_), do: ""

  defp tag_style(meta) do
    bg = if meta.tag_bg, do: "background:#{meta.tag_bg};padding:1px 5px;border-radius:4px;", else: ""
    "font-size:8px;font-weight:700;letter-spacing:0.07em;font-family:ui-monospace,monospace;color:#{meta.tag_c};" <> bg
  end

  defp sub_label(%{type: :agent} = n) do
    [node_model(n), node_effort(n)] |> Enum.reject(&(&1 in [nil, ""])) |> Enum.join(" · ")
  end

  defp sub_label(node), do: truncate(node_run(node))

  defp truncate(nil), do: ""
  defp truncate(s) when byte_size(s) <= 22, do: s
  defp truncate(s), do: String.slice(s, 0, 21) <> "…"

  defp humanize(key), do: String.replace(key, "_", " ")

  defp edge_label(edge) do
    on = edge_on(edge)

    case edge_max_loops(edge) do
      max when is_integer(max) -> "#{on} · max #{max}"
      _ -> to_string(on)
    end
  end

  # ---- orthogonal edge geometry ----

  # Compute the SVG path `d` and the on-path label point together, from the route kind + lane
  # that FlowLayout already assigned. One function so `d` and the label can never disagree.
  defp edge_geometry(edge, index, layout, sizes) do
    route = Map.fetch!(layout.routes, index)
    points_and_label(route, edge, layout, sizes)
  end

  # start → first spine node: a straight vertical drop.
  defp points_and_label(%{kind: :enter}, edge, layout, sizes) do
    vgeom(layout.start_point, top_center(edge.to, layout, sizes))
  end

  # last spine node → done: a straight vertical drop.
  defp points_and_label(%{kind: :exit}, edge, layout, sizes) do
    vgeom(bottom_center(edge.from, layout, sizes), layout.done_point)
  end

  # forward spine step: bottom-centre → top-centre (a short dogleg only if columns differ).
  defp points_and_label(%{kind: :drop}, edge, layout, sizes) do
    vgeom(bottom_center(edge.from, layout, sizes), top_center(edge.to, layout, sizes))
  end

  # spine → side node on the same row: horizontal run 10px ABOVE the pair's mid-height.
  defp points_and_label(%{kind: :side_out}, edge, layout, sizes) do
    {ax, ay} = right_center(edge.from, layout, sizes)
    {bx, by} = left_center(edge.to, layout, sizes)
    runy = div(ay + by, 2) - 10
    pts = [{ax, ay}, {ax, runy}, {bx, runy}, {bx, by}]
    %{d: ortho_path(pts), label: {div(ax + bx, 2), runy}}
  end

  # side node → spine on the same row: horizontal run 10px BELOW the pair's mid-height. The
  # ±10 offsets keep the two antiparallel arrows of a rework detour off each other.
  defp points_and_label(%{kind: :side_back}, edge, layout, sizes) do
    {ax, ay} = left_center(edge.from, layout, sizes)
    {bx, by} = right_center(edge.to, layout, sizes)
    runy = div(ay + by, 2) + 10
    pts = [{ax, ay}, {ax, runy}, {bx, runy}, {bx, by}]
    %{d: ortho_path(pts), label: {div(ax + bx, 2), runy}}
  end

  # back-edge: leave the source's right, run out to its lane x, up/down to the target row, back
  # in to the target's right. Label sits on the vertical lane segment, so labels never collide.
  defp points_and_label(%{kind: :gutter, lane_x: lx}, edge, layout, sizes) do
    {ax, ay} = right_center(edge.from, layout, sizes)
    {bx, by} = right_center(edge.to, layout, sizes)
    pts = [{ax, ay}, {lx, ay}, {lx, by}, {bx, by}]
    %{d: ortho_path(pts), label: {lx, div(ay + by, 2)}}
  end

  # a vertical connector between two points sharing an x (straight); a symmetric dogleg if not.
  defp vgeom({ax, ay}, {bx, by}) do
    pts =
      if ax == bx do
        [{ax, ay}, {bx, by}]
      else
        midy = div(ay + by, 2)
        [{ax, ay}, {ax, midy}, {bx, midy}, {bx, by}]
      end

    %{d: ortho_path(pts), label: {ax, div(ay + by, 2)}}
  end

  # ---- node anchors ----

  defp box(key, layout, sizes) do
    {x, y} = Map.fetch!(layout.positions, key)
    {w, h} = Map.fetch!(sizes, key)
    {x, y, w, h}
  end

  defp top_center(key, layout, sizes) do
    {x, y, w, _h} = box(key, layout, sizes)
    {x + div(w, 2), y}
  end

  defp bottom_center(key, layout, sizes) do
    {x, y, w, h} = box(key, layout, sizes)
    {x + div(w, 2), y + h}
  end

  defp left_center(key, layout, sizes) do
    {x, y, _w, h} = box(key, layout, sizes)
    {x, y + div(h, 2)}
  end

  defp right_center(key, layout, sizes) do
    {x, y, w, h} = box(key, layout, sizes)
    {x + w, y + div(h, 2)}
  end

  # ---- rounded orthogonal path builder ----

  # Build "M … L … Q …" through axis-aligned points, rounding each interior corner. The corner
  # radius is clamped to half the shorter adjacent segment so short stubs never blow past a turn.
  defp ortho_path([{x0, y0} | _] = pts), do: "M #{x0} #{y0} " <> ortho_segments(pts)

  defp ortho_segments([_last]), do: ""
  defp ortho_segments([_a, {bx, by}]), do: "L #{bx} #{by}"

  defp ortho_segments([a, b, c | rest]) do
    r = min(@corner, min(div(dist(a, b), 2), div(dist(b, c), 2)))
    {p1x, p1y} = toward(b, a, r)
    {bx, by} = b
    {p2x, p2y} = toward(b, c, r)
    "L #{p1x} #{p1y} Q #{bx} #{by} #{p2x} #{p2y} " <> ortho_segments([b, c | rest])
  end

  # Manhattan distance — points are always axis-aligned, so this is the true segment length.
  defp dist({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)

  # A point r pixels from `b` toward `t` along their shared axis. Points are always axis-aligned,
  # so at most one of dx/dy is non-zero — moving both by their sign lands on the right axis.
  defp toward({bx, by}, {tx, ty}, r), do: {bx + sign(tx - bx) * r, by + sign(ty - by) * r}

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(0), do: 0

  # Flow-level "lands → <stage>" pill. Anchored to the layout's `done_point` (centred just below
  # where the exit edge lands) rather than a fixed coordinate — the flow "lands" on that stage
  # when it reaches `done`, so this reads naturally under the exit arrow and can never collide
  # with a spine node the way a hardcoded top/left did once FlowLayout went vertical (RLY-186).
  defp lands_style(layout) do
    {x, y} = layout.done_point

    "position:absolute;left:#{x}px;top:#{y + 8}px;transform:translateX(-50%);z-index:4;" <>
      "display:flex;align-items:center;gap:6px;white-space:nowrap;" <>
      "background:oklch(0.97 0.02 155);border:1px solid oklch(0.88 0.05 155);border-radius:20px;" <>
      "padding:7px 13px;font-size:11.5px;font-weight:600;font-family:ui-monospace,monospace;" <>
      "color:oklch(0.42 0.10 155);"
  end

  # Clickable "done" sentinel — only rendered mid connect-edge (picking a target), so it never
  # competes with real-node selection but is reachable as a valid connect target (RLY-143).
  defp done_marker_style(layout) do
    {x, y} = layout.done_point

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:5;" <>
      "font-size:10px;font-weight:700;font-family:ui-monospace,monospace;border-radius:20px;" <>
      "padding:6px 12px;cursor:pointer;border:1.5px dashed oklch(0.60 0.13 155);" <>
      "background:oklch(0.97 0.02 155);color:oklch(0.42 0.10 155);"
  end

  defp edge_label_style(edge, geo) do
    {x, y} = geo.label
    {color, bg} = label_colors(edge_on(edge))

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:3;" <>
      "font-size:9.5px;font-weight:600;font-family:ui-monospace,monospace;border-radius:5px;" <>
      "padding:2px 6px;white-space:nowrap;border:0;cursor:pointer;" <>
      "box-shadow:0 0 0 3px oklch(0.975 0.004 250);color:#{color};background:#{bg};"
  end

  defp label_colors(:succeeded), do: {"oklch(0.42 0.11 155)", "oklch(0.97 0.03 155)"}
  defp label_colors(:failed), do: {"oklch(0.52 0.15 22)", "oklch(0.98 0.03 22)"}
  defp label_colors(:partial), do: {"oklch(0.48 0.13 292)", "oklch(0.98 0.03 292)"}
  defp label_colors(:needs_input), do: {"oklch(0.52 0.11 65)", "oklch(0.98 0.04 75)"}
  defp label_colors(_), do: {"oklch(0.52 0.02 255)", "oklch(0.97 0.004 255)"}

  defp selected_ring(sel, key) when sel == key, do: "outline:2px solid oklch(0.56 0.16 292);"
  defp selected_ring(_, _), do: ""
end
