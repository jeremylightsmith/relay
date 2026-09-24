defmodule RelayWeb.FlowGraphComponents do
  @moduledoc """
  The shared flow-graph renderer: absolutely-positioned node divs + an SVG edge layer, laid out
  by `RelayWeb.FlowLayout` (a thin adapter over the vendored `dagre_ex`). Used interactively by
  the flow editor and (later, RLY-132) read-only by the run panel with live `node_states`.
  Concrete visual values match docs/designs/Relay Flow Editor.dc.html (typeMeta lines ~366-395,
  edges ~310-363) — the artboard is authoritative for node shapes, colours, dashes, arrowheads
  and label pills, but NOT for layout: node positions and edge paths come from `FlowLayout` and
  intentionally diverge from the artboard (RLY-186, RE333). Each edge is drawn by handing its
  route's axis-aligned `points` to `ortho_path/1`, and its label pill sits at the route's `label`.

  Nodes/edges may arrive either as `Schemas.Flow.Node`/`Edge` structs or as plain maps from
  `Relay.Flows.DefaultLibrary` / the flow editor's working copy. Both shapes are dense — every
  field present, nil when unset — since RLY-241 made `Relay.Flows.Document.decode/1` fill the
  schema default for anything the JSON omits. Every accessor below still goes through
  `Map.get/2` so a partial map from a future caller renders rather than raising.
  """
  use Phoenix.Component

  import RelayWeb.CoreComponents, only: [icon: 1]

  alias RelayWeb.FlowLayout

  # rounded-corner radius for orthogonal edge turns.
  @corner 8

  # daisyUI tokens mapped from the artboard's oklch literals (RE237), keyed by node type.
  @type_meta %{
    agent: %{
      accent: "var(--color-secondary)",
      border: "color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100))",
      fill: "var(--color-base-100)",
      tag: "AGENT",
      tag_c: "color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content))",
      tag_bg: "color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100))"
    },
    shell: %{
      accent: "color-mix(in oklab, var(--color-base-content) 60%, var(--color-base-100))",
      border: "var(--color-field-border)",
      fill: "var(--color-base-100)",
      tag: "SHELL",
      tag_c: "color-mix(in oklab, var(--color-base-content) 70%, transparent)",
      tag_bg: "color-mix(in oklab, var(--color-base-content) 5%, var(--color-base-100))"
    },
    gate: %{
      accent: "var(--color-warning)",
      border: "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-100))",
      fill: "color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100))",
      tag: "GATE",
      tag_c: "color-mix(in oklab, var(--color-warning) 50%, var(--color-base-content))",
      tag_bg: nil
    },
    parallel: %{
      accent: "var(--color-accent)",
      border: "color-mix(in oklab, var(--color-accent) 35%, var(--color-base-100))",
      fill: "color-mix(in oklab, var(--color-accent) 5%, var(--color-base-100))",
      tag: "PARALLEL",
      tag_c: "color-mix(in oklab, var(--color-accent) 45%, var(--color-base-content))",
      tag_bg: "color-mix(in oklab, var(--color-accent) 15%, var(--color-base-100))"
    },
    human: %{
      accent: "var(--color-primary)",
      border: "color-mix(in oklab, var(--color-primary) 35%, var(--color-base-100))",
      fill: "color-mix(in oklab, var(--color-primary) 5%, var(--color-base-100))",
      tag: "HUMAN",
      tag_c: "color-mix(in oklab, var(--color-primary) 55%, var(--color-base-content))",
      tag_bg: "color-mix(in oklab, var(--color-primary) 15%, var(--color-base-100))"
    }
  }

  # edge stroke color by canonical outcome (start edge = nil → neutral "ok" grey).
  @edge_color %{
    nil => "color-mix(in oklab, var(--color-base-content) 45%, transparent)",
    succeeded: "var(--color-success)",
    failed: "var(--color-error)",
    partial: "var(--color-secondary)",
    needs_input: "var(--color-warning)"
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

    geos =
      for {edge, i} <- Enum.with_index(assigns.edges), Map.has_key?(assigns.layout.routes, i) do
        %{points: points, label: label} = Map.fetch!(assigns.layout.routes, i)
        %{edge: edge, index: i, d: ortho_path(points), label: label}
      end

    parked = Enum.filter(assigns.nodes, &MapSet.member?(assigns.layout.parks, &1.key))

    assigns = assign(assigns, width: w, height: h, geos: geos, parked: parked)

    ~H"""
    <div
      id="flow-graph"
      class="relative"
      style={"width:#{@width}px;height:#{@height}px;background-image:radial-gradient(var(--color-field-border) 1px, transparent 1px);background-size:22px 22px;"}
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
          d={g.d}
          stroke={edge_color(g.edge)}
          stroke-width="2"
          fill="none"
          stroke-dasharray={if edge_on(g.edge) == :failed, do: "5 4", else: nil}
          marker-end={"url(#arw-#{edge_on(g.edge) || "start"})"}
        />
      </svg>

      <%= for g <- @geos, g.label do %>
        <button
          :if={@interactive?}
          type="button"
          data-edge={g.index}
          phx-click="select_edge"
          phx-value-index={g.index}
          style={edge_label_style(g.edge, g.label) <> selected_ring(@selected, {:edge, g.index})}
        >
          {FlowLayout.edge_label(g.edge)}
        </button>
        <span :if={!@interactive?} data-edge={g.index} style={edge_label_style(g.edge, g.label)}>
          {FlowLayout.edge_label(g.edge)}
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
        <span style="font-size:12.5px;font-weight:600;color:color-mix(in oklab, var(--color-base-content) 95%, transparent);text-align:center;line-height:1.15;padding:0 6px;">
          {humanize(node.key)}
        </span>
        <span style="font-size:9.5px;font-family:ui-monospace,monospace;color:color-mix(in oklab, var(--color-base-content) 55%, transparent);white-space:nowrap;">
          {sub_label(node)}
        </span>
      </div>

      <span
        :for={node <- @parked}
        data-park={node.key}
        role="img"
        title="Can park for human input"
        aria-label="Can park for human input"
        style={park_badge_style(node, @layout)}
      >
        <.icon name="hero-pause-circle" class="size-3" />
      </span>

      <div :if={@lands_on} style={lands_style(@layout)}>
        <span style="width:7px;height:7px;border-radius:50%;background:var(--color-success);"></span>
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

  # defensive accessors — every shipped shape is dense (see the moduledoc), so these only
  # guard against a partial map from a future caller.
  defp edge_on(edge), do: Map.get(edge, :on)
  defp node_model(node), do: Map.get(node, :model)
  defp node_effort(node), do: Map.get(node, :effort)
  defp node_run(node), do: Map.get(node, :run)
  defp node_agent(node), do: Map.get(node, :agent)

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

  defp state_accent(:running), do: "outline:2px solid var(--color-secondary);"
  defp state_accent(:succeeded), do: "outline:2px solid var(--color-success);"
  defp state_accent(:failed), do: "outline:2px solid var(--color-error);"
  defp state_accent(_), do: ""

  defp tag_style(meta) do
    bg = if meta.tag_bg, do: "background:#{meta.tag_bg};padding:1px 5px;border-radius:4px;", else: ""
    "font-size:8px;font-weight:700;letter-spacing:0.07em;font-family:ui-monospace,monospace;color:#{meta.tag_c};" <> bg
  end

  # Stack the whole agent binding: WHICH subagent it dispatches to (the thing the graph exists to
  # make visible) then its model · effort tuning. Each part is dropped when absent, so a generic
  # agent node reads `model · effort` and a bare one never renders an empty label.
  defp sub_label(%{type: :agent} = n) do
    [node_agent(n), node_model(n), node_effort(n)]
    |> Enum.reject(&(&1 in [nil, ""]))
    |> Enum.join(" · ")
  end

  defp sub_label(node), do: truncate(node_run(node))

  defp truncate(nil), do: ""
  defp truncate(s) when byte_size(s) <= 22, do: s
  defp truncate(s), do: String.slice(s, 0, 21) <> "…"

  defp humanize(key), do: String.replace(key, "_", " ")

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

  # Manhattan distance — FlowLayout snaps every route to axis-aligned points, so this is the true
  # segment length.
  defp dist({x1, y1}, {x2, y2}), do: abs(x1 - x2) + abs(y1 - y2)

  # A point r pixels from `b` toward `t` along their shared axis. Points are always axis-aligned,
  # so at most one of dx/dy is non-zero — moving both by their sign lands on the right axis.
  defp toward({bx, by}, {tx, ty}, r), do: {bx + sign(tx - bx) * r, by + sign(ty - by) * r}

  defp sign(n) when n > 0, do: 1
  defp sign(n) when n < 0, do: -1
  defp sign(0), do: 0

  # "This node can park on a human" (RE330): a small warning pill straddling the node box's
  # top-right corner, carrying the same warning colours a needs_input edge used to. A sibling of
  # the node div rather than a child, because gate/human nodes clip-path their box and would clip
  # a badge that overlaps the border. z-index 5 lifts it above the node (4).
  defp park_badge_style(node, layout) do
    {x, y} = position(node, layout)
    {w, _h} = FlowLayout.node_size(node.type)
    {fg, bg} = label_colors(:needs_input)

    "position:absolute;left:#{x + w - 12}px;top:#{y - 9}px;z-index:5;" <>
      "display:flex;align-items:center;justify-content:center;width:20px;height:18px;" <>
      "border-radius:9px;border:1.5px solid #{@edge_color[:needs_input]};background:#{bg};color:#{fg};"
  end

  # Flow-level "lands → <stage>" pill. Anchored to the layout's `done_point` (centred just below
  # where the exit edge lands) rather than a fixed coordinate — the flow "lands" on that stage
  # when it reaches `done`, so this reads naturally under the exit arrow and can never collide
  # with a spine node the way a hardcoded top/left did once FlowLayout went vertical (RLY-186).
  defp lands_style(layout) do
    {x, y} = layout.done_point

    "position:absolute;left:#{x}px;top:#{y + 8}px;transform:translateX(-50%);z-index:4;" <>
      "display:flex;align-items:center;gap:6px;white-space:nowrap;" <>
      "background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));border:1px solid color-mix(in oklab, var(--color-success) 30%, var(--color-base-100));border-radius:20px;" <>
      "padding:7px 13px;font-size:11.5px;font-weight:600;font-family:ui-monospace,monospace;" <>
      "color:color-mix(in oklab, var(--color-success) 45%, var(--color-base-content));"
  end

  # Clickable "done" sentinel — only rendered mid connect-edge (picking a target), so it never
  # competes with real-node selection but is reachable as a valid connect target (RLY-143).
  defp done_marker_style(layout) do
    {x, y} = layout.done_point

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:5;" <>
      "font-size:10px;font-weight:700;font-family:ui-monospace,monospace;border-radius:20px;" <>
      "padding:6px 12px;cursor:pointer;border:1.5px dashed var(--color-success);" <>
      "background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100));color:color-mix(in oklab, var(--color-success) 45%, var(--color-base-content));"
  end

  defp edge_label_style(edge, {x, y}) do
    {color, bg} = label_colors(edge_on(edge))

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:3;" <>
      "font-size:9.5px;font-weight:600;font-family:ui-monospace,monospace;border-radius:5px;" <>
      "padding:2px 6px;white-space:nowrap;border:0;cursor:pointer;" <>
      "box-shadow:0 0 0 3px var(--color-base-200);color:#{color};background:#{bg};"
  end

  defp label_colors(:succeeded),
    do:
      {"color-mix(in oklab, var(--color-success) 45%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-success) 10%, var(--color-base-100))"}

  defp label_colors(:failed),
    do:
      {"color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-error) 5%, var(--color-base-100))"}

  defp label_colors(:partial),
    do:
      {"color-mix(in oklab, var(--color-secondary) 75%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100))"}

  defp label_colors(:needs_input),
    do:
      {"color-mix(in oklab, var(--color-warning) 60%, var(--color-base-content))",
       "color-mix(in oklab, var(--color-warning) 5%, var(--color-base-100))"}

  defp label_colors(_),
    do: {"color-mix(in oklab, var(--color-base-content) 65%, transparent)", "var(--color-field-hover)"}

  defp selected_ring(sel, key) when sel == key, do: "outline:2px solid var(--color-secondary);"
  defp selected_ring(_, _), do: ""
end
