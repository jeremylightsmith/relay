defmodule RelayWeb.FlowGraphComponents do
  @moduledoc """
  The shared flow-graph renderer: absolutely-positioned node divs + an SVG edge layer, laid out
  by `RelayWeb.FlowLayout`. Used interactively by the flow editor and (later, RLY-132) read-only
  by the run panel with live `node_states`. Concrete visual values match
  docs/designs/Relay Flow Editor.dc.html (typeMeta lines ~366-395, edges ~310-363).

  Nodes/edges may arrive either as `Schemas.Flow.Node`/`Edge` structs (always carry every
  field, nil when unset) or as plain maps straight from `Relay.Flows.DefaultLibrary` (which
  omit optional keys entirely, e.g. the start edge has no `:on` key at all). Every accessor
  below goes through `Map.get/2` so both shapes render without raising.
  """
  use Phoenix.Component

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
    {w, h} = assigns.layout.size
    assigns = assign(assigns, width: w, height: h)

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
          :for={edge <- @edges}
          d={edge_path(edge, @layout)}
          stroke={edge_color(edge)}
          stroke-width="2"
          fill="none"
          stroke-dasharray={if edge_on(edge) == :failed, do: "5 4", else: nil}
          marker-end={"url(#arw-#{edge_on(edge) || "start"})"}
        />
      </svg>

      <%= for {edge, i} <- Enum.with_index(@edges), edge.from != "start" do %>
        <button
          :if={@interactive?}
          type="button"
          data-edge={i}
          phx-click="select_edge"
          phx-value-index={i}
          style={edge_label_style(edge, @layout) <> selected_ring(@selected, {:edge, i})}
        >
          {edge_label(edge)}
        </button>
        <span :if={!@interactive?} data-edge={i} style={edge_label_style(edge, @layout)}>
          {edge_label(edge)}
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

      <div
        :if={@lands_on}
        style="position:absolute;left:2px;top:150px;display:flex;align-items:center;gap:6px;background:oklch(0.97 0.02 155);border:1px solid oklch(0.88 0.05 155);border-radius:20px;padding:7px 13px;font-size:11.5px;font-weight:600;font-family:ui-monospace,monospace;color:oklch(0.42 0.10 155);"
      >
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
    base =
      "position:absolute;left:#{x}px;top:#{y}px;z-index:4;cursor:pointer;display:flex;flex-direction:column;align-items:center;justify-content:center;gap:2px;"

    ring = if selected == {:node, node.key}, do: "box-shadow:0 0 0 3px #{meta.accent};", else: ""
    state = state_accent(Map.get(node_states, node.key))

    shape =
      case node.type do
        :gate ->
          "width:118px;height:76px;clip-path:polygon(50% 0,100% 50%,50% 100%,0 50%);background:#{meta.fill};box-shadow:inset 0 0 0 1.5px #{meta.border};"

        :human ->
          "width:150px;height:56px;clip-path:polygon(14% 0,86% 0,100% 50%,86% 100%,14% 100%,0 50%);background:#{meta.fill};box-shadow:inset 0 0 0 1.5px #{meta.border};"

        _ ->
          "width:150px;height:56px;border-radius:11px;background:#{meta.fill};border:1.5px solid #{meta.border};border-left:4px solid #{meta.accent};"
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

  # Bezier/arc path between the two endpoints, chosen by the edge's route kind.
  defp edge_path(edge, layout) do
    {x1, y1} = endpoint(edge.from, layout, :out)
    {x2, y2} = endpoint(edge.to, layout, :in)

    case edge_route(edge, layout) do
      :arc ->
        # loop-back: arc over the top
        midy = min(y1, y2) - 46
        "M #{x1} #{y1} C #{x1} #{midy}, #{x2} #{midy}, #{x2} #{y2}"

      :drop ->
        "M #{x1} #{y1} C #{x1} #{y1 + 40}, #{x2} #{y2 - 40}, #{x2} #{y2}"

      :vertical ->
        "M #{x1} #{y1} L #{x2} #{y2}"

      _ ->
        # horizontal / enter / exit / straight: gentle bezier
        dx = round((x2 - x1) / 2)
        "M #{x1} #{y1} C #{x1 + dx} #{y1}, #{x2 - dx} #{y2}, #{x2} #{y2}"
    end
  end

  # Recompute the route kind for this specific edge from positions. Mirrors
  # FlowLayout.route_kind/2 for path selection only (kept independent of edge index ordering).
  defp edge_route(%{from: "start"}, _), do: :enter
  defp edge_route(%{to: "done"}, _), do: :exit

  defp edge_route(edge, layout) do
    with {x1, y1} <- Map.get(layout.positions, edge.from),
         {x2, y2} <- Map.get(layout.positions, edge.to) do
      cond do
        y2 > y1 -> :drop
        y2 < y1 -> :arc
        x2 < x1 -> :arc
        x1 == x2 -> :vertical
        true -> :horizontal
      end
    else
      _ -> :straight
    end
  end

  # anchor points: right-center for source, left-center for target (approx node box).
  defp endpoint("start", _layout, _), do: {0, 60}
  defp endpoint("done", layout, _), do: exit_point(layout)

  defp endpoint(key, layout, dir) do
    case Map.get(layout.positions, key) do
      {x, y} when dir == :out -> {x + 150, y + 28}
      {x, y} -> {x, y + 28}
      _ -> {0, 0}
    end
  end

  defp exit_point(layout) do
    {_w, h} = layout.size
    {60, min(h - 40, 190)}
  end

  # Clickable "done" sentinel — only rendered mid connect-edge (picking a target), so it never
  # competes with real-node selection but is reachable as a valid connect target (RLY-143).
  defp done_marker_style(layout) do
    {x, y} = exit_point(layout)

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:5;" <>
      "font-size:10px;font-weight:700;font-family:ui-monospace,monospace;border-radius:20px;" <>
      "padding:6px 12px;cursor:pointer;border:1.5px dashed oklch(0.60 0.13 155);" <>
      "background:oklch(0.97 0.02 155);color:oklch(0.42 0.10 155);"
  end

  defp edge_label_style(edge, layout) do
    {x, y} = label_pos(edge, layout)
    {color, bg} = label_colors(edge_on(edge))

    "position:absolute;left:#{x}px;top:#{y}px;transform:translate(-50%,-50%);z-index:3;" <>
      "font-size:9.5px;font-weight:600;font-family:ui-monospace,monospace;border-radius:5px;" <>
      "padding:2px 6px;white-space:nowrap;border:0;cursor:pointer;" <>
      "box-shadow:0 0 0 3px oklch(0.975 0.004 250);color:#{color};background:#{bg};"
  end

  defp label_pos(edge, layout) do
    {x1, y1} = endpoint(edge.from, layout, :out)
    {x2, y2} = endpoint(edge.to, layout, :in)
    {div(x1 + x2, 2), div(y1 + y2, 2)}
  end

  defp label_colors(:succeeded), do: {"oklch(0.42 0.11 155)", "oklch(0.97 0.03 155)"}
  defp label_colors(:failed), do: {"oklch(0.52 0.15 22)", "oklch(0.98 0.03 22)"}
  defp label_colors(:partial), do: {"oklch(0.48 0.13 292)", "oklch(0.98 0.03 292)"}
  defp label_colors(:needs_input), do: {"oklch(0.52 0.11 65)", "oklch(0.98 0.04 75)"}
  defp label_colors(_), do: {"oklch(0.52 0.02 255)", "oklch(0.97 0.004 255)"}

  defp selected_ring(sel, key) when sel == key, do: "outline:2px solid oklch(0.56 0.16 292);"
  defp selected_ring(_, _), do: ""
end
