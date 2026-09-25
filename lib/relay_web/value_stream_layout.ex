defmodule RelayWeb.ValueStreamLayout do
  @moduledoc """
  Pure geometry and formatting for the value stream map (RE347; RE349's level 2 reuses it).
  Turns `Relay.ValueStream` per-state maps into box positions, connector and Request-changes arc
  paths, ladder items, box stat rows, using the level-1 artboard's
  constants (`docs/designs/Value Stream Map v2.dc.html`, `cardLay()` / `buildCard()` /
  `ladder()`): boxes W 186 × H 132, gap 58, from x 66 at y 150. Nothing here renders or touches
  the database, so it is unit-tested without a LiveView.

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.FlowLayout`.
  """

  alias Relay.ValueStream

  @box_w 186
  @box_h 132
  @gap 58
  @x0 66
  @y 150
  # The artboard flags a gate's Approve rate below this, and a flow with more nodes than this.
  @low_approve 0.85
  @many_nodes 10

  @doc "One box per state, in order, on one line: `%{state, x, y, w, h}`."
  def boxes(states) do
    states
    |> Enum.with_index()
    |> Enum.map(fn {state, i} -> %{state: state, x: @x0 + i * (@box_w + @gap), y: @y, w: @box_w, h: @box_h} end)
  end

  @doc "The map canvas for `n` boxes, the stream's mid line and the ladder's two rows."
  def geometry(n) when is_integer(n) and n > 0 do
    line_end = @x0 + (n - 1) * (@box_w + @gap) + @box_w

    %{
      w: line_end + 60,
      h: @y + @box_h + 110 + 96,
      line_end: line_end,
      mid_y: @y + div(@box_h, 2),
      box_y: @y,
      box_h: @box_h,
      t_y0: @y + @box_h + 52,
      t_y1: @y + @box_h + 110,
      gap: @gap
    }
  end

  @doc "The connector between each pair of neighbouring boxes, with its arrowhead's points."
  def connectors(boxes) do
    mid_y = @y + div(@box_h, 2)

    boxes
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> %{x1: a.x + a.w, x2: b.x - 9, y: mid_y, arrow: arrow(b.x, mid_y, 5.5, :right)} end)
  end

  @doc """
  One Request-changes arc per gate that sent work back to its `rework_target`, above the line:
  stroke width `2.5 + rate × 26`, apex `46 + k × 30` for the k-th gate, arrowhead down into the
  target. None for a gate with no rejections, no decisions or no rework target.
  """
  def arcs(boxes) do
    by_stage = Map.new(boxes, &{&1.state.stage_id, &1})

    boxes
    |> Enum.filter(&(&1.state.kind == :gate))
    |> Enum.with_index()
    |> Enum.flat_map(fn {gate, k} ->
      arc(gate, Map.get(by_stage, gate.state.rework_target), send_back_rate(gate.state), k)
    end)
  end

  defp arc(_gate, nil, _rate, _k), do: []
  defp arc(_gate, _target, nil, _k), do: []

  defp arc(gate, target, rate, k) do
    w = 2.5 + rate * 26
    head = w * 0.7 + 4
    apex = 46 + k * 30
    ax = gate.x + gate.w / 2
    bx = target.x + target.w / 2

    [
      %{
        stage_id: gate.state.stage_id,
        d: "M#{num(ax)},#{gate.y} C#{num(ax)},#{apex} #{num(bx)},#{apex} #{num(bx)},#{num(target.y - head * 1.2)}",
        width: Float.round(w, 1),
        arrow: arrow(bx, target.y, head, :down),
        label: "Request changes · #{fmt_pct(rate)} → re-runs #{target.state.name}",
        label_x: Float.round((ax + bx) / 2, 1),
        label_y: apex - 9
      }
    ]
  end

  @doc "The share of a gate's decisions that sent the card back — nil unless it is a gate that rejected."
  def send_back_rate(%{kind: :gate, approve_rate: rate}) when is_number(rate) and rate < 1, do: 1 - rate
  def send_back_rate(_state), do: nil

  @doc """
  Ladder items, one per box: `%{x, w, wait, work, rework, color}`. The rise before a box is its
  wait (a queue's or gate's time). The valley under a flow is its first-visit work plus the
  rework tail (`mean_secs - mean_first_secs`). `color` is a daisyUI token name.
  """
  def ladder_items(boxes) do
    Enum.map(boxes, fn %{state: state} = box ->
      {wait, work, rework} = rung_times(state)
      %{x: box.x, w: box.w, wait: wait, work: work, rework: rework, color: rung_token(state.kind)}
    end)
  end

  defp rung_times(%{kind: :flow} = state), do: {0, state.mean_first_secs, state.mean_secs - state.mean_first_secs}
  defp rung_times(state), do: {state.mean_secs, 0, 0}

  defp rung_token(:flow), do: "secondary"
  defp rung_token(:done), do: "success"
  defp rung_token(_kind), do: "warning"

  @doc """
  Per-rung drawing values plus the running total: `{rungs, total}`. Each rung is its item plus
  `rise_x` (the gap's left edge), `work_w` (the valley's work share), `kv` (work + rework) and
  `cum` (cumulative seconds after it).
  """
  def rungs(items, gap) do
    Enum.map_reduce(items, 0, fn item, cum ->
      kv = item.work + item.rework
      work_w = if kv > 0, do: Float.round(item.w * item.work / kv, 1), else: item.w
      cum = cum + item.wait + kv
      {Map.merge(item, %{rise_x: item.x - gap, work_w: work_w, kv: kv, cum: cum}), cum}
    end)
  end

  @doc """
  A box's stat rows, `[%{k, v, tone, bold}]`, by kind and scope. `:flow` (averaged) reads
  "Mean …"; `:card` shows that card's actuals. `extra` carries what the state map does not:
  `nodes` (a flow's node count), `approved` / `rejected` (a gate's counts for one card),
  `done_at` (one card's) and `cards_per_week` (averaged).
  """
  def box_rows(%{kind: :queue} = state, scope, _extra) do
    [
      row(mean_label(scope, "Mean wait", "Wait"), fmt_duration(state.mean_secs), :warning, true),
      row("Cards here", Integer.to_string(state.wip), :ink, false),
      row("Baton", "nobody", :muted, false)
    ]
  end

  def box_rows(%{kind: :flow} = state, scope, extra) do
    nodes = Map.get(extra, :nodes)
    many? = is_integer(nodes) and nodes > @many_nodes

    [
      row(mean_label(scope, "Mean work", "Work"), fmt_duration(state.mean_baton.agent), :secondary, true),
      row("Nodes", if(nodes, do: Integer.to_string(nodes), else: "—"), if(many?, do: :error, else: :ink), many?),
      row("$ / card", fmt_money(state.mean_cost), :secondary, false)
    ]
  end

  def box_rows(%{kind: :gate} = state, :card, extra) do
    rejected = Map.get(extra, :rejected, 0)

    [
      row("Time to decide", fmt_duration(state.mean_secs), :primary, true),
      row("Approved", Integer.to_string(Map.get(extra, :approved, 0)), :ink, false),
      row("Rejected", Integer.to_string(rejected), if(rejected > 0, do: :error, else: :ink), rejected > 0)
    ]
  end

  def box_rows(%{kind: :gate} = state, _scope, _extra) do
    low? = is_number(state.approve_rate) and state.approve_rate < @low_approve

    [
      row("Mean to decide", fmt_duration(state.mean_first_secs), :primary, true),
      row("Approve", fmt_pct(state.approve_rate), if(low?, do: :error, else: :ink), low?),
      row("Sends back", fmt_pct(state.approve_rate && 1 - state.approve_rate), :error, true)
    ]
  end

  def box_rows(%{kind: :done}, :card, %{done_at: %DateTime{} = at}),
    do: [row("Done", Calendar.strftime(at, "%b %-d"), :success, true)]

  def box_rows(%{kind: :done}, :card, _extra), do: [row("Done", "in progress", :muted, true)]

  def box_rows(%{kind: :done}, _scope, extra),
    do: [row("Cards / week", fmt_rate(Map.get(extra, :cards_per_week)), :success, true)]

  defp row(k, v, tone, bold), do: %{k: k, v: v, tone: tone, bold: bold}

  defp mean_label(:card, _mean, actual), do: actual
  defp mean_label(_scope, mean, _actual), do: mean

  @doc """
  The phone-width list's rows, one per state: the visits badge, the primary time figure, a bar
  to scale against `lead_secs` (percent) coloured by `token`, and a gate's rework note
  ("Request changes N% → re-runs X") in place of the arc.
  """
  def list_rows(states, lead_secs) do
    names = Map.new(states, &{&1.stage_id, &1.name})

    Enum.map(states, fn state ->
      %{
        state: state,
        visits: fmt_visits(state.mean_visits),
        primary: fmt_duration(state.mean_secs),
        bar_pct: bar_pct(state.mean_secs, lead_secs),
        token: kind_token(state.kind),
        rework_note: rework_note(state, names)
      }
    end)
  end

  defp bar_pct(secs, lead) when is_number(lead) and lead > 0, do: Float.round(min(secs / lead, 1.0) * 100, 1)
  defp bar_pct(_secs, _lead), do: 0.0

  defp rework_note(state, names) do
    case {send_back_rate(state), Map.get(names, state.rework_target)} do
      {rate, name} when is_number(rate) and is_binary(name) -> "Request changes #{fmt_pct(rate)} → re-runs #{name}"
      _none -> nil
    end
  end

  @doc "The lead-time bar's segments in `Relay.ValueStream.batons/0` order, empty batons dropped."
  def lead_segments(baton_secs) do
    ValueStream.batons()
    |> Enum.map(fn baton ->
      secs = Map.fetch!(baton_secs, baton)
      %{key: baton, grow: secs, label: "#{baton_phrase(baton)} #{fmt_duration(secs)}"}
    end)
    |> Enum.filter(&(&1.grow > 0))
  end

  defp baton_phrase(:agent), do: "agent working"
  defp baton_phrase(:human), do: "human deciding"
  defp baton_phrase(:nobody), do: "nobody · queued"

  @doc "The daisyUI colour token a stream-state kind is drawn in (the baton that holds it)."
  def kind_token(:queue), do: "warning"
  def kind_token(:flow), do: "secondary"
  def kind_token(:gate), do: "primary"
  def kind_token(:done), do: "success"

  @doc "The kind badge's label."
  def kind_badge(:queue), do: "QUEUE"
  def kind_badge(:flow), do: "AI"
  def kind_badge(:gate), do: "HUMAN"
  def kind_badge(:done), do: "DONE"

  @doc "Seconds as the artboard's hrs(): `Ns`, `Nm`, `N.Nh`, `N.Nd`; nil → `—`."
  def fmt_duration(nil), do: "—"
  def fmt_duration(secs) when secs >= 86_400, do: "#{one_dp(secs / 86_400)}d"
  def fmt_duration(secs) when secs >= 3_600, do: "#{one_dp(secs / 3_600)}h"
  def fmt_duration(secs) when secs >= 60, do: "#{round(secs / 60)}m"
  def fmt_duration(secs), do: "#{round(secs)}s"

  @doc "A ratio as a whole percent; nil → `—`."
  def fmt_pct(nil), do: "—"
  def fmt_pct(ratio), do: "#{round(ratio * 100)}%"

  @doc "A ratio as a percent to one decimal (flow efficiency); nil → `—`."
  def fmt_pct1(nil), do: "—"
  def fmt_pct1(ratio), do: "#{one_dp(ratio * 100)}%"

  @doc "Dollars: two decimals under $10, one above; nil → `—`."
  def fmt_money(nil), do: "—"

  def fmt_money(%Decimal{} = amount) do
    places = if Decimal.compare(amount, 10) == :lt, do: 2, else: 1
    "$" <> (amount |> Decimal.round(places) |> Decimal.to_string(:normal))
  end

  @doc "The visits badge: `×N` above one visit (whole numbers bare, else two decimals), `\"\"` at one."
  def fmt_visits(visits) when is_number(visits) and visits > 1.001 do
    if visits == trunc(visits),
      do: "×#{trunc(visits)}",
      else: "×#{:erlang.float_to_binary(visits * 1.0, decimals: 2)}"
  end

  def fmt_visits(_visits), do: ""

  @doc "A rate to one decimal; nil → `—`."
  def fmt_rate(nil), do: "—"
  def fmt_rate(rate), do: one_dp(rate)

  defp one_dp(x), do: :erlang.float_to_binary(x * 1.0, decimals: 1)

  @doc "An arrowhead's polygon points, tip at `{x, y}`, pointing `:right`, `:down` or `:up` (half-width `a`)."
  def arrow(x, y, a, :right), do: points([{x - a * 1.3, y - a}, {x - a * 1.3, y + a}, {x, y}])
  def arrow(x, y, a, :down), do: points([{x - a, y - a * 1.3}, {x + a, y - a * 1.3}, {x, y}])
  def arrow(x, y, a, :up), do: points([{x - a, y + a * 1.3}, {x + a, y + a * 1.3}, {x, y}])

  defp points(pairs), do: Enum.map_join(pairs, " ", fn {px, py} -> "#{num(px)},#{num(py)}" end)

  @doc "An SVG coordinate: integers bare, floats to one decimal."
  def num(x) when is_integer(x), do: Integer.to_string(x)
  def num(x), do: one_dp(x)
end
