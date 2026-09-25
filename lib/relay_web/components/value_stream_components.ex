defmodule RelayWeb.ValueStreamComponents do
  @moduledoc """
  The shared value-stream-map components (RE347 level 1; RE349 level 2): stream boxes, the
  connector line with its Request-changes arcs, the aligned ladder, the to-scale lead-time bar,
  stat tiles and the baton legend, plus level 2's flow node box, flow map canvas, legend and run
  lead-time bands. They take plain maps — `Relay.ValueStream` states laid out by
  `RelayWeb.ValueStreamLayout` (level 1) or `RelayWeb.ValueStreamFlowLayout` (level 2) — and
  render the artboards (`docs/designs/Value Stream Map v2.dc.html`) in daisyUI tokens only
  (RE237): agent `--color-secondary`, human `--color-primary`, queue / nobody `--color-warning`
  (hatched), done and Do `--color-success`, Check `--color-info`, rework / Fix `--color-error`. SVG is coloured through `style`,
  never presentation attributes, so `var()` resolves and the map flips with `data-theme`.
  """
  use Phoenix.Component

  alias RelayWeb.ValueStreamFlowLayout
  alias RelayWeb.ValueStreamLayout

  # ── boxes ──────────────────────────────────────────────────────────────────

  attr :box, :map, required: true, doc: "a `ValueStreamLayout.boxes/1` entry — `%{state, x, y, w, h}`"
  attr :rows, :list, required: true, doc: "`ValueStreamLayout.box_rows/3` — `[%{k, v, tone, bold}]`"
  attr :href, :string, default: nil, doc: "a flow box's level-2 drill (RE349); nil renders a plain box"
  attr :metrics_href, :string, default: nil, doc: "a flow box's secondary Flow Metrics link, under the box"

  @doc "One stream-state box, absolutely positioned on the map canvas; a flow box is a link."
  def stream_box(%{href: nil} = assigns) do
    ~H"""
    <div id={"vs-box-#{@box.state.stage_id}"} style={box_style(@box)}>
      <.box_header state={@box.state} />
      <.stat_rows rows={@rows} />
    </div>
    """
  end

  def stream_box(assigns) do
    ~H"""
    <.link
      id={"vs-box-#{@box.state.stage_id}"}
      navigate={@href}
      style={box_style(@box)}
      class="hover:brightness-95"
    >
      <.box_header state={@box.state} />
      <.stat_rows rows={@rows} />
    </.link>
    <.link
      :if={@metrics_href}
      id={"vs-box-#{@box.state.stage_id}-metrics"}
      navigate={@metrics_href}
      class="hover:underline"
      style={"position:absolute;left:#{@box.x}px;top:#{@box.y + @box.h + 5}px;width:#{@box.w}px;text-align:right;font-size:10px;font-weight:600;font-family:var(--font-mono);color:#{ink("secondary")};text-decoration:none;"}
    >
      Flow metrics →
    </.link>
    """
  end

  attr :state, :map, required: true

  defp box_header(assigns) do
    assigns =
      assign(assigns,
        token: ValueStreamLayout.kind_token(assigns.state.kind),
        visits: ValueStreamLayout.fmt_visits(assigns.state.mean_visits)
      )

    ~H"""
    <div style={"background:#{tint(@token, 6)};padding:7px 10px 6px;display:flex;flex-direction:column;gap:4px;border-bottom:1px solid var(--color-base-300);"}>
      <div style="display:flex;align-items:baseline;justify-content:space-between;gap:6px;">
        <span
          class="vs-box-name"
          style="font-size:11.5px;font-weight:600;font-family:var(--font-mono);white-space:nowrap;"
        >
          {@state.name}
        </span>
        <span
          :if={@visits != ""}
          class="vs-visits"
          style={"font-size:9.5px;font-weight:700;font-family:var(--font-mono);white-space:nowrap;color:#{ink("error")};"}
        >
          {@visits}
        </span>
      </div>
      <span class="vs-kind" style={"align-self:flex-start;" <> badge_style(@token)}>
        {ValueStreamLayout.kind_badge(@state.kind)}
      </span>
    </div>
    """
  end

  attr :rows, :list, required: true
  attr :dense, :boolean, default: false

  defp stat_rows(assigns) do
    ~H"""
    <div style={"padding:#{if @dense, do: "4px 9px", else: "6px 10px"};display:flex;flex-direction:column;flex:1;"}>
      <div
        :for={r <- @rows}
        style={"display:flex;justify-content:space-between;gap:6px;font-size:#{if @dense, do: "9.5px", else: "10px"};line-height:#{if @dense, do: "16px", else: "17px"};"}
      >
        <span style={"white-space:nowrap;color:#{tone_color(:muted)};"}>{r.k}</span>
        <span style={"font-family:var(--font-mono);white-space:nowrap;color:#{tone_color(r.tone)};font-weight:#{if r.bold, do: 700, else: 500};"}>
          {r.v}
        </span>
      </div>
    </div>
    """
  end

  # ── the line and its arcs ──────────────────────────────────────────────────

  attr :id, :string, default: "vs-stream-line"
  attr :boxes, :list, required: true, doc: "`ValueStreamLayout.boxes/1`"
  attr :geometry, :map, required: true, doc: "`ValueStreamLayout.geometry/1`"
  attr :first, :string, required: true, doc: "the first stream state's name"
  attr :last, :string, required: true, doc: "the last stream state's name"

  @doc "The SVG connector line, its arrows and the Request-changes arcs above it."
  def stream_line(assigns) do
    assigns =
      assign(assigns,
        connectors: ValueStreamLayout.connectors(assigns.boxes),
        arcs: ValueStreamLayout.arcs(assigns.boxes)
      )

    ~H"""
    <svg
      id={@id}
      width={@geometry.w}
      height={@geometry.h}
      viewBox={"0 0 #{@geometry.w} #{@geometry.h}"}
      style={canvas_style()}
    >
      <text x="2" y="24" style={label_style(:error)}>
        REWORK — Request changes sends the card back
      </text>
      <text x="2" y={@geometry.box_y - 14} style={label_style(:ink)}>
        {"THE CARD STREAM — #{@first} → #{@last}"}
      </text>
      <g :for={c <- @connectors} class="vs-connector">
        <line
          x1={c.x1}
          y1={c.y}
          x2={c.x2}
          y2={c.y}
          style={"stroke:#{line_color()};stroke-width:1.8;"}
        />
        <polygon points={c.arrow} style={"fill:#{line_color()};"} />
      </g>
      <g :for={a <- @arcs} id={"vs-arc-#{a.stage_id}"} class="vs-arc">
        <path
          d={a.d}
          style={"fill:none;stroke:var(--color-error);stroke-opacity:0.85;stroke-width:#{a.width};"}
        />
        <polygon points={a.arrow} style="fill:var(--color-error);" />
        <text
          x={a.label_x}
          y={a.label_y}
          text-anchor="middle"
          style={"font-family:var(--font-mono);font-size:11px;font-weight:700;fill:#{ink("error")};stroke:var(--color-base-100);stroke-width:4.5;paint-order:stroke;stroke-linejoin:round;"}
        >
          {a.label}
        </text>
      </g>
    </svg>
    """
  end

  # ── the ladder ─────────────────────────────────────────────────────────────

  attr :id, :string, default: "vs-ladder"
  attr :items, :list, required: true, doc: "`ValueStreamLayout.ladder_items/1` — `%{x, w, wait, work, rework, color}`"
  attr :geometry, :map, required: true, doc: "`ValueStreamLayout.geometry/1`"
  attr :outside, :any, default: 0, doc: "off-stream seconds — added to Δ so it equals the lead time"
  attr :fmt, :any, default: nil, doc: "seconds → label; defaults to `ValueStreamLayout.fmt_duration/1`"

  attr :label, :string,
    default: "TIME — rise = the card sitting still, valley = something happening to it",
    doc: "the band label above the ladder"

  attr :footnote, :string, default: nil, doc: "an optional footnote under the cumulative row"

  @doc """
  The time ladder, aligned under the boxes: the rise in the gap before each box is its wait, the
  valley under it its work with a rose rework tail, a cumulative figure per rung and `Δ` at the
  right end (including off-stream time, so it equals the lead time).
  """
  def ladder(assigns) do
    {rungs, cum} = ValueStreamLayout.rungs(assigns.items, assigns.geometry.gap)

    assigns =
      assign(assigns,
        rungs: Enum.with_index(rungs),
        total: cum + assigns.outside,
        f: assigns.fmt || (&ValueStreamLayout.fmt_duration/1)
      )

    ~H"""
    <svg
      id={@id}
      width={@geometry.w}
      height={@geometry.h}
      viewBox={"0 0 #{@geometry.w} #{@geometry.h}"}
      style={canvas_style()}
    >
      <text x="2" y={@geometry.t_y0 - 30} style={label_style(:info)}>
        {@label}
      </text>
      <g :for={{r, i} <- @rungs} class="vs-rung">
        <line
          x1={r.x + r.w / 2}
          y1={@geometry.box_y + @geometry.box_h + 6}
          x2={r.x + r.w / 2}
          y2={@geometry.t_y1}
          style={"stroke:#{tone_color(:muted)};stroke-opacity:0.5;stroke-width:1;stroke-dasharray:2 5;"}
        />
        <line
          :if={i > 0}
          x1={r.rise_x}
          y1={@geometry.t_y1}
          x2={r.rise_x}
          y2={@geometry.t_y0}
          style={stroke_style()}
        />
        <line
          x1={r.rise_x}
          y1={@geometry.t_y0}
          x2={r.x}
          y2={@geometry.t_y0}
          style={stroke_style()}
        />
        <text
          :if={r.wait > 0}
          x={(r.rise_x + r.x) / 2}
          y={@geometry.t_y0 - 8}
          text-anchor="middle"
          style={"font-family:var(--font-mono);font-size:9.5px;font-weight:600;fill:#{tone_color(:warning)};"}
        >
          {@f.(r.wait)}
        </text>
        <line x1={r.x} y1={@geometry.t_y0} x2={r.x} y2={@geometry.t_y1} style={stroke_style()} />
        <line
          x1={r.x}
          y1={@geometry.t_y1}
          x2={r.x + r.w}
          y2={@geometry.t_y1}
          style={stroke_style()}
        />
        <line
          x1={r.x}
          y1={@geometry.t_y1}
          x2={r.x + r.work_w}
          y2={@geometry.t_y1}
          style={"stroke:var(--color-#{r.color});stroke-width:6;"}
        />
        <line
          :if={r.rework > 0}
          x1={r.x + r.work_w}
          y1={@geometry.t_y1}
          x2={r.x + r.w}
          y2={@geometry.t_y1}
          style="stroke:var(--color-error);stroke-width:6;"
        />
        <text
          x={r.x + r.w / 2}
          y={@geometry.t_y1 + 18}
          text-anchor="middle"
          style="font-family:var(--font-mono);font-size:10px;"
        >
          <%= if r.rework > 0 do %>
            <tspan style={"fill:#{ink(r.color)};"}>{@f.(r.work)}</tspan>
            <tspan style={"fill:#{tone_color(:muted)};"}>{" + "}</tspan>
            <tspan style={"fill:#{tone_color(:error)};"}>{@f.(r.rework)}</tspan>
          <% else %>
            <tspan style={"fill:#{tone_color(:ink)};"}>{if r.kv > 0, do: @f.(r.kv), else: "—"}</tspan>
          <% end %>
        </text>
        <text
          x={r.x + r.w / 2}
          y={@geometry.t_y1 + 33}
          text-anchor="middle"
          class="vs-cum"
          style={"font-family:var(--font-mono);font-size:9px;font-weight:600;fill:#{tone_color(:muted)};"}
        >
          {@f.(r.cum)}
        </text>
      </g>
      <line
        x1={@geometry.line_end}
        y1={@geometry.t_y1}
        x2={@geometry.line_end}
        y2={@geometry.t_y0}
        style={stroke_style()}
      />
      <text
        id={"#{@id}-total"}
        x={@geometry.line_end + 12}
        y={@geometry.t_y0 + 4}
        style={"font-family:var(--font-mono);font-size:13px;font-weight:700;fill:#{tone_color(:ink)};"}
      >
        {"Δ " <> @f.(@total)}
      </text>
      <text
        :if={@outside > 0}
        x={@geometry.line_end + 12}
        y={@geometry.t_y0 + 20}
        style={"font-family:var(--font-mono);font-size:9.5px;fill:#{tone_color(:muted)};"}
      >
        {"incl. #{@f.(@outside)} off-stream"}
      </text>
      <text
        x="2"
        y={@geometry.t_y1 + 33}
        style={"font-family:var(--font-mono);font-size:8.5px;font-weight:600;fill:#{tone_color(:muted)};"}
      >
        cumulative
      </text>
      <text
        :if={@footnote}
        id={"#{@id}-footnote"}
        x="2"
        y={@geometry.t_y1 + 52}
        style={"font-family:var(--font-mono);font-size:9px;fill:#{tone_color(:muted)};"}
      >
        {@footnote}
      </text>
    </svg>
    """
  end

  # ── lead bar, tiles, legend ─────────────────────────────────────────────────

  attr :id, :string, default: "vs-lead-bar"
  attr :baton, :map, required: true, doc: "`%{agent, human, nobody}` seconds (`Relay.ValueStream.batons/0`)"
  attr :total, :string, required: true, doc: "the formatted lead time"

  @doc "CARD LEAD TIME · to scale — agent working (violet), human deciding (blue), nobody · queued (hatched amber)."
  def lead_bar(assigns) do
    assigns = assign(assigns, :segments, ValueStreamLayout.lead_segments(assigns.baton))

    ~H"""
    <div
      id={@id}
      style="display:flex;flex-direction:column;gap:12px;border-top:1px solid var(--color-base-300);padding-top:18px;max-width:1500px;"
    >
      <span style={"font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{tone_color(:muted)};"}>
        CARD LEAD TIME · to scale
      </span>
      <div style="display:flex;align-items:center;gap:14px;">
        <.segment_bar id={@id} segments={@segments} height={36} />
        <span
          id={"#{@id}-total"}
          style="width:104px;flex:0 0 auto;text-align:right;font-size:19px;font-weight:600;font-family:var(--font-mono);"
        >
          {@total}
        </span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :segments, :list, required: true, doc: "`[%{key, grow, label}]`"
  attr :height, :integer, required: true

  # The one to-scale segment bar behind both lead-time bars (level 1's baton bar, level 2's bands).
  defp segment_bar(assigns) do
    ~H"""
    <div style={"flex:1;display:flex;height:#{@height}px;border-radius:7px;overflow:hidden;gap:2px;background:var(--color-base-200);min-width:0;"}>
      <div
        :for={s <- @segments}
        style={"flex:#{s.grow} 1 0;background:#{segment_bg(s.key)};display:flex;align-items:center;padding:0 9px;min-width:0;overflow:hidden;"}
      >
        <span
          id={"#{@id}-#{s.key}"}
          style={"font-size:10.5px;font-weight:700;font-family:var(--font-mono);white-space:nowrap;color:#{segment_ink(s.key)};"}
        >
          {s.label}
        </span>
      </div>
    </div>
    """
  end

  attr :id, :string, required: true
  attr :label, :string, required: true
  attr :value, :string, required: true
  attr :sub, :string, default: nil

  attr :tone, :atom,
    default: :ink,
    doc: ":ink | :muted | a daisyUI token atom (:error, :warning, :primary, :secondary, :success)"

  attr :hot, :boolean, default: false, doc: "an error-tinted tile — the numbers the map exists to show"

  @doc "One stat tile: a mono label, a 19px value and an optional sub-line."
  def stat_tile(assigns) do
    ~H"""
    <div id={@id} class="vs-tile min-w-0 md:min-w-[168px]" style={tile_style(@hot)}>
      <span style={"font-size:9px;font-weight:600;letter-spacing:0.04em;font-family:var(--font-mono);color:#{tone_color(:muted)};"}>
        {@label}
      </span>
      <span
        id={"#{@id}-value"}
        style={"font-size:19px;font-weight:600;font-family:var(--font-mono);color:#{tone_color(@tone)};"}
      >
        {@value}
      </span>
      <span
        :if={@sub}
        id={"#{@id}-sub"}
        style={"font-size:10.5px;line-height:1.4;color:#{tone_color(:muted)};"}
      >
        {@sub}
      </span>
    </div>
    """
  end

  attr :id, :string, default: "vs-legend"

  @doc "The baton legend: AI = agent flow, HUMAN = review gate, hatched = queue, rose = Request changes."
  def baton_legend(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-[18px] gap-y-2 border-y border-base-300 py-[11px] text-[11.5px] text-base-content/60"
    >
      <span class="flex items-center gap-1.5">
        <span class="vs-kind" style={badge_style("secondary")}>AI</span> agent flow
      </span>
      <span class="flex items-center gap-1.5">
        <span class="vs-kind" style={badge_style("primary")}>HUMAN</span>
        review gate — Approve / Request changes
      </span>
      <span class="flex items-center gap-1.5">
        <span style={"width:18px;height:9px;border-radius:2px;background:#{hatch()};"}></span>
        queue — nobody holds the baton
      </span>
      <span class="flex items-center gap-1.5">
        <span style="width:22px;height:5px;border-radius:2px;background:var(--color-error);"></span>
        Request changes — the card-level rework loop
      </span>
    </div>
    """
  end

  # ── level 2: one flow (RE349) ──────────────────────────────────────────────

  attr :box, :map, required: true, doc: "a `ValueStreamFlowLayout.node_boxes/2` entry"

  @doc """
  One flow node, absolutely positioned: key, `×visits` (rose above 1.25), the DO / CHECK / FIX
  chip and its type; three rows by role; a check's green / rose pass strip along the bottom. A
  fix is a dashed rose box above the line.
  """
  def flow_node_box(assigns) do
    assigns = assign(assigns, :token, ValueStreamFlowLayout.role_token(assigns.box.role))

    ~H"""
    <div
      id={"vs-node-#{@box.key}"}
      class={["vs-node", @box.fix? && "vs-node-fix"]}
      style={node_style(@box)}
    >
      <div style={"background:#{tint(@token, 6)};padding:6px 9px 5px;display:flex;flex-direction:column;gap:3px;border-bottom:1px solid var(--color-base-300);"}>
        <div style="display:flex;align-items:baseline;justify-content:space-between;gap:5px;">
          <span
            class="vs-node-key"
            style="font-size:10.5px;font-weight:600;font-family:var(--font-mono);white-space:nowrap;"
          >
            {@box.key}
          </span>
          <span
            :if={@box.visits != ""}
            class="vs-node-visits"
            style={"font-size:9px;font-weight:700;font-family:var(--font-mono);white-space:nowrap;color:#{if @box.visits_hot, do: ink("error"), else: tone_color(:muted)};"}
          >
            {@box.visits}
          </span>
        </div>
        <div style="display:flex;align-items:center;gap:5px;">
          <span class="vs-role" style={badge_style(@token)}>
            {ValueStreamFlowLayout.role_label(@box.role)}
          </span>
          <span
            class="vs-node-type"
            style={"font-size:8.5px;font-family:var(--font-mono);white-space:nowrap;color:#{tone_color(:muted)};"}
          >
            {@box.type}
          </span>
        </div>
      </div>
      <.stat_rows rows={@box.rows} dense />
      <div :if={@box.pass_pct} class="vs-pass-strip" style="display:flex;height:5px;flex:0 0 auto;">
        <div style={"width:#{@box.pass_pct}%;background:var(--color-success);"}></div>
        <div style="flex:1;background:var(--color-error);"></div>
      </div>
    </div>
    """
  end

  attr :id, :string, default: "vs-flow-svg"
  attr :layout, :map, required: true, doc: "`ValueStreamFlowLayout.layout/1`"
  attr :arcs, :list, required: true, doc: "`ValueStreamFlowLayout.arcs/2`"
  attr :queue, :map, required: true, doc: "`ValueStreamFlowLayout.queue/2` — `%{lead, slot, value}`"
  attr :terminals, :map, required: true, doc: "`ValueStreamFlowLayout.terminals/3`"

  @doc """
  The level-2 canvas under the node boxes: the REWORK / STREAM band labels, the dashed rose
  VERIFY BLOCK frames, the line's connectors, the check → fix send-backs and fix re-entries
  (rose, width = minutes), the dashed foreach loop, the amber queue triangle before the first box,
  and the green done / amber ⏸ needs_input terminals after the last.
  """
  def flow_map(assigns) do
    assigns =
      assign(assigns, g: assigns.layout.geometry, connectors: ValueStreamFlowLayout.connectors(assigns.layout))

    ~H"""
    <svg
      id={@id}
      width={@g.w}
      height={@g.h}
      viewBox={"0 0 #{@g.w} #{@g.h}"}
      style={canvas_style()}
    >
      <text id="vs-band-rework" x="2" y="24" style={label_style(:error)}>
        REWORK — everything above the line exists only because something failed
      </text>
      <text id="vs-band-stream" x="2" y={@g.box_y - 14} style={label_style(:ink)}>
        THE STREAM — one line, in execution order
      </text>
      <g :for={f <- @layout.verify_blocks} id={f.id} class="vs-verify">
        <rect
          x={f.x}
          y={f.y}
          width={f.w}
          height={f.h}
          rx="12"
          style={"fill:var(--color-error);fill-opacity:0.045;stroke:#{tint("error", 55)};stroke-width:1.4;stroke-dasharray:6 5;"}
        />
        <text
          x={f.label_x}
          y={f.label_y}
          style={"font-family:var(--font-mono);font-size:10px;font-weight:700;fill:#{ink("error")};"}
        >
          {f.label}
        </text>
      </g>
      <g :for={c <- @connectors} class="vs-connector">
        <line
          x1={c.x1}
          y1={c.y}
          x2={c.x2}
          y2={c.y}
          style={"stroke:#{line_color()};stroke-width:1.8;"}
        />
        <polygon points={c.arrow} style={"fill:#{line_color()};"} />
      </g>
      <g :if={@layout.foreach_loop} id="vs-foreach-loop">
        <path
          d={@layout.foreach_loop.d}
          style={"fill:none;stroke:#{tone_color(:muted)};stroke-width:4.5;stroke-dasharray:8 6;stroke-opacity:0.85;"}
        />
        <polygon points={@layout.foreach_loop.arrow} style={"fill:#{tone_color(:muted)};"} />
        <text
          x={@layout.foreach_loop.label_x}
          y={@layout.foreach_loop.label_y}
          text-anchor="middle"
          style={halo_style(10.5, 600, tone_color(:muted))}
        >
          {@layout.foreach_loop.label}
        </text>
      </g>
      <g :for={a <- @arcs} id={a.id} class={"vs-arc vs-arc-#{a.kind}"}>
        <path
          d={a.d}
          style={"fill:none;stroke:var(--color-error);stroke-opacity:0.85;stroke-width:#{a.width};"}
        />
        <polygon points={a.arrow} style="fill:var(--color-error);" />
        <text
          x={a.label_x}
          y={a.label_y}
          text-anchor="middle"
          style={halo_style(a.size, 700, ink("error"))}
        >
          {a.label}
        </text>
      </g>
      <g id="vs-queue">
        <polygon
          points={"20,#{@g.box_y + 66} 32,#{@g.box_y + 46} 44,#{@g.box_y + 66}"}
          style="fill:var(--color-warning);"
        />
        <text x="32" y={@g.box_y + 81} text-anchor="middle" style={term_text(10.5, 700, "warning")}>
          {@queue.value}
        </text>
        <text x="4" y={@g.box_y + 25} style={term_text(9.5, 600, "warning")}>{@queue.lead}</text>
        <text x="4" y={@g.box_y + 36} style={term_text(9.5, 700, "warning")}>{@queue.slot}</text>
      </g>
      <g id="vs-terminals">
        <line
          x1={@g.line_end}
          y1={@g.mid_y}
          x2={@g.term_x - 9}
          y2={@g.mid_y}
          style="stroke:var(--color-success);stroke-width:2.4;"
        />
        <polygon
          points={ValueStreamLayout.arrow(@g.term_x, @g.mid_y, 6, :right)}
          style="fill:var(--color-success);"
        />
        <g id="vs-term-done">
          <rect
            x={@g.term_x}
            y={@g.mid_y - 27}
            width="184"
            height="54"
            rx="10"
            style={"fill:#{tint("success", 8)};stroke:#{tint("success", 55)};stroke-width:1.5;"}
          />
          <text x={@g.term_x + 14} y={@g.mid_y - 4} style={term_text(12, 700, "success")}>
            {@terminals.done_label}
          </text>
          <text x={@g.term_x + 14} y={@g.mid_y + 13} style={term_text(10, 500, "success")}>
            {@terminals.done_sub}
          </text>
        </g>
        <g id="vs-term-park">
          <rect
            x={@g.term_x}
            y={@g.mid_y + 50}
            width="184"
            height="54"
            rx="10"
            style={"fill:#{tint("warning", 8)};stroke:#{tint("warning", 55)};stroke-width:1.5;"}
          />
          <text x={@g.term_x + 14} y={@g.mid_y + 73} style={term_text(12, 700, "warning")}>
            ⏸ needs_input
          </text>
          <text x={@g.term_x + 14} y={@g.mid_y + 90} style={term_text(10, 500, "warning")}>
            {@terminals.park_sub}
          </text>
        </g>
        <path
          :if={@terminals.feeder_x}
          d={"M#{@terminals.feeder_x},#{@g.box_y + @g.box_h + 8} L#{@terminals.feeder_x},#{@g.mid_y + 77} L#{@g.term_x - 9},#{@g.mid_y + 77}"}
          style={"fill:none;stroke:#{tint("warning", 70)};stroke-width:2;stroke-dasharray:5 4;"}
        />
        <polygon
          :if={@terminals.feeder_x}
          points={ValueStreamLayout.arrow(@g.term_x, @g.mid_y + 77, 6, :right)}
          style={"fill:#{tint("warning", 70)};"}
        />
        <text id="vs-park-note" x={@g.term_x} y={@g.mid_y + 124} style={term_text(10, 600, "warning")}>
          {@terminals.park_note}
        </text>
      </g>
    </svg>
    """
  end

  attr :id, :string, default: "vs-flow-legend"
  attr :runs, :integer, required: true, doc: "the population's run count (the laps denominator)"

  @doc "The level-2 legend: DO / CHECK / FIX chips, the send-back and foreach swatches, the visits note."
  def flow_legend(assigns) do
    ~H"""
    <div
      id={@id}
      class="flex flex-wrap items-center gap-x-[18px] gap-y-2 border-y border-base-300 py-[11px] text-[11.5px] text-base-content/60"
    >
      <span class="flex items-center gap-1.5">
        <span class="vs-role" style={badge_style("success")}>DO</span> value-add
      </span>
      <span class="flex items-center gap-1.5">
        <span class="vs-role" style={badge_style("info")}>CHECK</span> necessary, not value-add
      </span>
      <span class="flex items-center gap-1.5">
        <span class="vs-role" style={badge_style("error")}>FIX</span> rework only · above the line
      </span>
      <span class="h-4 w-px bg-base-300"></span>
      <span class="flex items-center gap-1.5">
        <span style="width:22px;height:5px;border-radius:2px;background:var(--color-error);"></span>
        send-back · <b class="text-base-content/80">thickness = minutes</b>, label = laps / {@runs} runs
      </span>
      <span class="flex items-center gap-1.5">
        <span style={"width:22px;height:0;border-top:2px dashed #{tone_color(:muted)};"}></span>
        planned iteration (<code>foreach</code>)
      </span>
      <span class="flex-1"></span>
      <span class="font-mono text-[10.5px]">×n in a header = visits per run</span>
    </div>
    """
  end

  attr :id, :string, default: "vs-run-lead"
  attr :bands, :list, required: true, doc: "`ValueStreamFlowLayout.bands/1`"

  @doc "RUN LEAD TIME · to scale — PROCESS TIME (value-add + checking) and RUN WALL-CLOCK (+ rework + wait)."
  def run_lead_bands(assigns) do
    ~H"""
    <div
      id={@id}
      style="display:flex;flex-direction:column;gap:12px;border-top:1px solid var(--color-base-300);padding-top:18px;max-width:1500px;"
    >
      <span style={"font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{tone_color(:muted)};"}>
        RUN LEAD TIME · to scale (the ladder above is aligned to nodes, so it is not)
      </span>
      <div :for={b <- @bands} id={b.id} style="display:flex;align-items:center;gap:14px;">
        <div style="width:176px;flex:0 0 auto;display:flex;flex-direction:column;gap:1px;">
          <span style="font-size:11px;font-weight:700;letter-spacing:0.04em;font-family:var(--font-mono);">
            {b.k}
          </span>
          <span style={"font-size:10px;color:#{tone_color(:muted)};"}>{b.sub}</span>
        </div>
        <.segment_bar id={b.id} segments={b.segments} height={34} />
        <span
          id={"#{b.id}-total"}
          style={"width:96px;flex:0 0 auto;text-align:right;font-size:17px;font-weight:600;font-family:var(--font-mono);color:#{tone_color(b.tone)};"}
        >
          {b.total}
        </span>
      </div>
    </div>
    """
  end

  # ── token helpers (RE237: no literals) ─────────────────────────────────────

  defp tint(token, pct), do: "color-mix(in oklab, var(--color-#{token}) #{pct}%, var(--color-base-100))"
  defp ink(token), do: "color-mix(in oklab, var(--color-#{token}) 70%, var(--color-base-content))"

  defp hatch, do: "repeating-linear-gradient(45deg, #{tint("warning", 55)} 0 5px, #{tint("warning", 25)} 5px 10px)"

  defp tone_color(:ink), do: "color-mix(in oklab, var(--color-base-content) 90%, transparent)"
  defp tone_color(:muted), do: "color-mix(in oklab, var(--color-base-content) 55%, transparent)"
  defp tone_color(token) when is_atom(token), do: ink(Atom.to_string(token))

  defp line_color, do: "color-mix(in oklab, var(--color-base-content) 60%, transparent)"
  defp stroke_style, do: "stroke:#{line_color()};stroke-width:1.5;"
  defp canvas_style, do: "position:absolute;inset:0;pointer-events:none;display:block;overflow:visible;"

  defp label_style(tone), do: "font-family:var(--font-mono);font-size:11px;font-weight:700;fill:#{tone_color(tone)};"

  defp badge_style(token) do
    "font-size:8px;font-weight:700;letter-spacing:0.06em;font-family:var(--font-mono);" <>
      "color:var(--color-#{token}-content);background:var(--color-#{token});border-radius:3px;padding:1px 5px;"
  end

  defp box_style(box) do
    token = ValueStreamLayout.kind_token(box.state.kind)

    "position:absolute;left:#{box.x}px;top:#{box.y}px;width:#{box.w}px;height:#{box.h}px;" <>
      "border:1px solid #{tint(token, 40)};border-radius:10px;background:var(--color-base-100);" <>
      "overflow:hidden;display:flex;flex-direction:column;color:inherit;text-decoration:none;" <>
      "box-shadow:0 1px 3px color-mix(in oklab, var(--color-neutral) 7%, transparent);"
  end

  defp tile_style(true) do
    "border:1px solid #{tint("error", 35)};background:#{tint("error", 4)};" <>
      "border-radius:9px;padding:10px 15px;display:flex;flex-direction:column;gap:2px;"
  end

  defp tile_style(false) do
    "border:1px solid var(--color-base-300);background:var(--color-base-100);" <>
      "border-radius:9px;padding:10px 15px;display:flex;flex-direction:column;gap:2px;"
  end

  defp segment_bg(:agent), do: "var(--color-secondary)"
  defp segment_bg(:human), do: "var(--color-primary)"
  defp segment_bg(:nobody), do: hatch()
  defp segment_bg(:value_add), do: "var(--color-success)"
  defp segment_bg(:checking), do: "var(--color-info)"
  defp segment_bg(:rework), do: "var(--color-error)"
  defp segment_bg(:wait), do: hatch()

  defp segment_ink(:agent), do: "var(--color-secondary-content)"
  defp segment_ink(:human), do: "var(--color-primary-content)"
  defp segment_ink(:nobody), do: ink("warning")
  defp segment_ink(:value_add), do: "var(--color-success-content)"
  defp segment_ink(:checking), do: "var(--color-info-content)"
  defp segment_ink(:rework), do: "var(--color-error-content)"
  defp segment_ink(:wait), do: ink("warning")

  defp halo_style(size, weight, fill) do
    "font-family:var(--font-mono);font-size:#{size}px;font-weight:#{weight};fill:#{fill};" <>
      "stroke:var(--color-base-100);stroke-width:4.5;paint-order:stroke;stroke-linejoin:round;"
  end

  defp term_text(size, weight, token),
    do: "font-family:var(--font-mono);font-size:#{size}px;font-weight:#{weight};fill:#{ink(token)};"

  defp node_style(box) do
    border =
      case box.role do
        :fix -> "1px dashed #{tint("error", 55)}"
        :check -> "1px solid #{tint("info", 45)}"
        _do -> "1px solid var(--color-base-300)"
      end

    "position:absolute;left:#{box.x}px;top:#{box.y}px;width:#{box.w}px;height:#{box.h}px;" <>
      "border:#{border};border-radius:9px;background:var(--color-base-100);overflow:hidden;" <>
      "display:flex;flex-direction:column;box-shadow:0 1px 3px color-mix(in oklab, var(--color-neutral) 7%, transparent);"
  end
end
