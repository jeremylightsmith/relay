defmodule RelayWeb.ValueStreamComponents do
  @moduledoc """
  The shared value-stream-map components (RE347; RE349's Code flow map reuses them): stream
  boxes, the connector line with its Request-changes arcs, the aligned ladder, the to-scale
  lead-time bar, stat tiles, the baton legend and the phone-width stream list. They take plain
  maps — `Relay.ValueStream` states laid out by `RelayWeb.ValueStreamLayout` — and render the
  level-1 artboard (`docs/designs/Value Stream Map v2.dc.html`) in daisyUI tokens only (RE237):
  agent `--color-secondary`, human `--color-primary`, queue / nobody `--color-warning`
  (hatched), done `--color-success`, rework `--color-error`. SVG is coloured through `style`,
  never presentation attributes, so `var()` resolves and the map flips with `data-theme`.
  """
  use Phoenix.Component

  alias RelayWeb.ValueStreamLayout

  # ── boxes ──────────────────────────────────────────────────────────────────

  attr :box, :map, required: true, doc: "a `ValueStreamLayout.boxes/1` entry — `%{state, x, y, w, h}`"
  attr :rows, :list, required: true, doc: "`ValueStreamLayout.box_rows/3` — `[%{k, v, tone, bold}]`"
  attr :href, :string, default: nil, doc: "a flow box's Flow Metrics page; nil renders a plain box"

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

  defp stat_rows(assigns) do
    ~H"""
    <div style="padding:6px 10px;display:flex;flex-direction:column;flex:1;">
      <div
        :for={r <- @rows}
        style="display:flex;justify-content:space-between;gap:6px;font-size:10px;line-height:17px;"
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
        TIME — rise = the card sitting still, valley = something happening to it
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
            <tspan style={"fill:#{tone_color(:secondary)};"}>{@f.(r.work)}</tspan>
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
        <div style="flex:1;display:flex;height:36px;border-radius:7px;overflow:hidden;gap:2px;background:var(--color-base-200);min-width:0;">
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

  # ── the phone list ─────────────────────────────────────────────────────────

  attr :id, :string, default: "vs-list"
  attr :rows, :list, required: true, doc: "`ValueStreamLayout.list_rows/2`"
  attr :class, :any, default: nil

  @doc """
  The vertical stream list shown below `md` in place of the wide map: one row per state, in
  order, with the box's header, its time, a thin bar to scale against lead time coloured by
  baton, and a gate's rework note instead of an arc.
  """
  def stream_list(assigns) do
    ~H"""
    <ol id={@id} class={["flex flex-col gap-2", @class]}>
      <li
        :for={r <- @rows}
        id={"vs-row-#{r.state.stage_id}"}
        class="overflow-hidden rounded-[10px] border border-base-300 bg-base-100"
      >
        <.box_header state={r.state} />
        <div style="padding:8px 10px;display:flex;flex-direction:column;gap:6px;">
          <div style="display:flex;justify-content:space-between;align-items:baseline;gap:6px;font-size:10.5px;">
            <span style={"color:#{tone_color(:muted)};"}>Time here</span>
            <span
              id={"vs-row-#{r.state.stage_id}-time"}
              style="font-family:var(--font-mono);font-weight:700;"
            >
              {r.primary}
            </span>
          </div>
          <div style="height:6px;border-radius:3px;background:var(--color-base-200);overflow:hidden;">
            <div
              class="vs-row-bar"
              style={"height:100%;width:#{r.bar_pct}%;background:#{bar_fill(r.token)};"}
            >
            </div>
          </div>
          <span
            :if={r.rework_note}
            id={"vs-row-#{r.state.stage_id}-rework"}
            style={"font-size:10.5px;font-weight:700;font-family:var(--font-mono);color:#{ink("error")};"}
          >
            {r.rework_note}
          </span>
        </div>
      </li>
    </ol>
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

  defp segment_ink(:agent), do: "var(--color-secondary-content)"
  defp segment_ink(:human), do: "var(--color-primary-content)"
  defp segment_ink(:nobody), do: ink("warning")

  defp bar_fill("warning"), do: hatch()
  defp bar_fill(token), do: "var(--color-#{token})"
end
