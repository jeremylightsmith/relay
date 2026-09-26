defmodule RelayWeb.ValueStreamFlowLayout do
  @moduledoc """
  Pure geometry and presentation for the value stream map, level 2 (RE349): one flow's nodes on
  one line in execution order, derived from the flow graph and `Schemas.Flow.node_roles/1` alone
  — nothing is specific to `code.json`. Constants follow the level-2 artboard
  (`docs/designs/Value Stream Map v2.dc.html`, `lay()` / `buildMap()`): node W 150 × H 138,
  gap 48, x0 76, line y 340; fix boxes 136 × 92 at y 188.

  - **The line** starts at `Schemas.Flow.start_node/1` and follows the `on: :succeeded` edge to a
    non-fix node, preferring `when: :foreach_exhausted` over `:foreach_remaining`, until `done`
    or a node already on it. Non-fix nodes the walk misses are appended in flow order.
  - **A fix** sits above the line at the mean line slot of the nodes with an `on: :failed` edge
    to it.
  - **Verify blocks** are a maximal run of ≥ 2 consecutive line nodes whose `(type, run)` pairs
    repeat an earlier run of the same length — both runs are framed.
  - **The foreach loop** is the `when: :foreach_remaining` edge, if any.
  - **A REWIND** is a fix re-entering a node ≥ 2 line slots to its left that itself fails into
    the fix, so every lap re-runs checks that already passed (Code: `final_fix → precommit` only
    — `github_fix → resync` lands left of it too, but `resync` never fails into `github_fix`).

  The presentation half turns `Relay.ValueStream.flow_stream/2` into per-run figures: every
  "per run" number is a total ÷ `runs`. Nothing here renders or touches the database.

  No `use Boundary` — a pure web-layer helper inside the `RelayWeb` boundary, like
  `RelayWeb.ValueStreamLayout`.
  """

  alias RelayWeb.ValueStreamLayout, as: VSL
  alias Schemas.Flow

  @node_w 150
  @node_h 138
  @gap 48
  @slot @node_w + @gap
  @x0 76
  @line_y 340
  @fix_w 136
  @fix_h 92
  @fix_y 188
  # A header's ×visits turns rose above this (the artboard's `visits > 1.25`); a check's Pass row below @low_pass.
  @hot_visits 1.25
  @low_pass 0.8
  @circled ~w(① ② ③ ④ ⑤ ⑥ ⑦ ⑧)

  # ── the graph ─────────────────────────────────────────────────────────────

  @doc "The flow's map, derived from the graph alone — see the moduledoc for every rule."
  def layout(%Flow{} = flow) do
    nodes = flow.nodes || []
    edges = flow.edges || []
    roles = Flow.node_roles(flow)
    by_key = Map.new(nodes, &{&1.key, &1})
    {fixes, non_fix} = nodes |> Enum.map(& &1.key) |> Enum.split_with(&(Map.get(roles, &1) == :fix))
    line = line(Flow.start_node(flow), edges, non_fix)
    line_slots = line |> Enum.with_index() |> Map.new()
    senders = senders(edges, roles)
    fix_slots = Map.new(fixes, &{&1, fix_slot(Map.get(senders, &1, []), line_slots)})

    pos =
      Map.merge(
        Map.new(line_slots, fn {key, i} -> {key, line_box(i)} end),
        Map.new(fix_slots, fn {key, slot} -> {key, fix_box(slot)} end)
      )

    base = %{
      line: line,
      fixes: fixes,
      roles: roles,
      nodes: Enum.map(line ++ fixes, &node_box(Map.fetch!(by_key, &1), roles, pos)),
      pos: pos,
      slots: Map.merge(line_slots, fix_slots),
      senders: senders,
      verify_blocks: line |> repeats(by_key) |> verify_blocks(line, pos),
      foreach_loop: foreach_loop(edges, pos),
      parkable: parkable(edges, by_key),
      node_count: length(nodes),
      edge_count: length(edges),
      geometry: geometry(length(line))
    }

    Map.put(base, :reentries, reentries(base, edges))
  end

  @doc "Whether a fix's re-entry into `target` is a REWIND (moduledoc) — false for unplaced nodes."
  def rewind?(layout, fix, target) do
    case {Map.get(layout.slots, fix), Map.get(layout.slots, target)} do
      {fix_slot, target_slot} when is_number(fix_slot) and is_number(target_slot) ->
        fix_slot - target_slot >= 2 and target in Map.get(layout.senders, fix, [])

      _unplaced ->
        false
    end
  end

  @doc "The connector between each pair of neighbouring line nodes, with its arrowhead."
  def connectors(layout) do
    mid_y = layout.geometry.mid_y

    layout.line
    |> Enum.map(&Map.fetch!(layout.pos, &1))
    |> Enum.chunk_every(2, 1, :discard)
    |> Enum.map(fn [a, b] -> %{x1: a.x + a.w, x2: b.x - 9, y: mid_y, arrow: VSL.arrow(b.x, mid_y, 5.5, :right)} end)
  end

  defp line(start, edges, non_fix) do
    walked = walk(start, edges, MapSet.new(non_fix), [])
    walked ++ Enum.reject(non_fix, &(&1 in walked))
  end

  defp walk(key, edges, line_keys, acc) do
    if MapSet.member?(line_keys, key) and key not in acc,
      do: walk(next_on_line(key, edges, line_keys), edges, line_keys, [key | acc]),
      else: Enum.reverse(acc)
  end

  defp next_on_line(key, edges, line_keys) do
    edges
    |> Enum.filter(&(&1.from == key and &1.on == :succeeded and MapSet.member?(line_keys, &1.to)))
    |> Enum.sort_by(&when_rank(&1.when))
    |> case do
      [edge | _] -> edge.to
      [] -> nil
    end
  end

  defp when_rank(:foreach_exhausted), do: 0
  defp when_rank(:foreach_remaining), do: 2
  defp when_rank(_unguarded), do: 1

  # %{fix_key => [keys with an on: :failed edge into it]}
  defp senders(edges, roles) do
    edges
    |> Enum.filter(&(&1.on == :failed and Map.get(roles, &1.to) == :fix))
    |> Enum.group_by(& &1.to, & &1.from)
    |> Map.new(fn {fix, froms} -> {fix, Enum.uniq(froms)} end)
  end

  defp fix_slot(senders, line_slots) do
    case for(s <- senders, Map.has_key?(line_slots, s), do: Map.fetch!(line_slots, s)) do
      [] -> 0.0
      slots -> Enum.sum(slots) / length(slots)
    end
  end

  defp line_box(i), do: %{x: @x0 + i * @slot, y: @line_y, w: @node_w, h: @node_h}
  defp fix_box(slot), do: %{x: @x0 + slot * @slot + (@node_w - @fix_w) / 2, y: @fix_y, w: @fix_w, h: @fix_h}

  defp node_box(node, roles, pos) do
    role = Map.get(roles, node.key)
    Map.merge(Map.fetch!(pos, node.key), %{key: node.key, type: to_string(node.type), role: role, fix?: role == :fix})
  end

  defp geometry(n) do
    line_end = @x0 + max(n - 1, 0) * @slot + @node_w
    t_y0 = @line_y + @node_h + 52

    %{
      w: line_end + 300,
      h: t_y0 + 58 + 104,
      line_end: line_end,
      mid_y: @line_y + div(@node_h, 2),
      box_y: @line_y,
      box_h: @node_h,
      t_y0: t_y0,
      t_y1: t_y0 + 58,
      gap: @gap,
      term_x: line_end + 58
    }
  end

  # [{first_start, repeat_start, len}] — each repeat is the longest earlier match, covered once.
  defp repeats(line, by_key) do
    sigs = line |> Enum.map(&{by_key[&1].type, by_key[&1].run}) |> List.to_tuple()

    {pairs, _covered} =
      Enum.reduce(0..(tuple_size(sigs) - 1)//1, {[], MapSet.new()}, fn j, {pairs, covered} ->
        with false <- MapSet.member?(covered, j),
             {i, len} when len >= 2 <- longest_earlier(sigs, j) do
          {[{i, j, len} | pairs], Enum.into(j..(j + len - 1), covered)}
        else
          _no_repeat -> {pairs, covered}
        end
      end)

    Enum.reverse(pairs)
  end

  defp longest_earlier(sigs, j) do
    0..(j - 1)//1
    |> Enum.map(&{&1, match_len(sigs, &1, j, 0)})
    |> Enum.sort_by(fn {i, len} -> {-len, i} end)
    |> List.first()
  end

  defp match_len(sigs, i, j, len) do
    if j + len < tuple_size(sigs) and i + len < j and elem(sigs, i + len) == elem(sigs, j + len),
      do: match_len(sigs, i, j, len + 1),
      else: len
  end

  defp verify_blocks(pairs, line, pos) do
    pairs
    |> Enum.with_index()
    |> Enum.flat_map(fn {{i, j, len}, p} ->
      [
        frame(Enum.slice(line, i, len), "VERIFY BLOCK #{circled(2 * p)}", 2 * p + 1, pos),
        frame(
          Enum.slice(line, j, len),
          "VERIFY BLOCK #{circled(2 * p + 1)} — byte-identical run commands",
          2 * p + 2,
          pos
        )
      ]
    end)
  end

  defp circled(n), do: Enum.at(@circled, n, Integer.to_string(n + 1))

  defp frame(keys, label, n, pos) do
    a = Map.fetch!(pos, hd(keys))
    b = Map.fetch!(pos, List.last(keys))

    %{
      id: "vs-verify-#{n}",
      keys: keys,
      label: label,
      x: a.x - 14,
      y: a.y - 16,
      w: b.x + b.w - a.x + 28,
      h: a.h + 32,
      label_x: a.x - 10,
      label_y: a.y + a.h + 30
    }
  end

  defp foreach_loop(edges, pos) do
    case Enum.find(edges, &(&1.when == :foreach_remaining and Map.has_key?(pos, &1.from) and Map.has_key?(pos, &1.to))) do
      nil ->
        nil

      edge ->
        a = Map.fetch!(pos, edge.from)
        b = Map.fetch!(pos, edge.to)
        ax = a.x + a.w / 2 + 30
        bx = b.x + b.w / 2 + 30

        %{
          from: edge.from,
          to: edge.to,
          d: "M#{VSL.num(ax)},#{a.y} C#{VSL.num(ax)},104 #{VSL.num(bx)},104 #{VSL.num(bx)},#{VSL.num(b.y - 7 * 1.2)}",
          arrow: VSL.arrow(bx, b.y, 7, :down),
          label: "foreach_remaining · next sub-task · planned, not waste",
          label_x: Float.round((ax + bx) / 2, 1),
          label_y: 95
        }
    end
  end

  defp parkable(edges, by_key) do
    sentinel = Flow.needs_input_sentinel()

    edges
    |> Enum.filter(&(&1.to == sentinel and Map.has_key?(by_key, &1.from)))
    |> Enum.map(& &1.from)
    |> Enum.uniq()
  end

  defp reentries(layout, edges) do
    for fix <- layout.fixes,
        edge <- edges,
        edge.from == fix and edge.on == :succeeded and Map.has_key?(layout.pos, edge.to),
        do: %{fix: fix, to: edge.to, rewind: rewind?(layout, fix, edge.to)}
  end

  # ── the data arcs ─────────────────────────────────────────────────────────

  @doc """
  The data arcs over `layout`, from `Relay.ValueStream.flow_stream/2`'s `sends`:

  - `:send` into a fix — grouped by `(from, to)`, a rose curve from the check's top up to the
    fix's bottom, labelled `×laps`;
  - `:send` into a line node (Code's `merge → resync`) — lands back on the line, labelled
    `<from> failed · ×N → <to>`;
  - `:return` — sends into a fix grouped by `(to, returns_to)`: the fix's re-entry, labelled
    `⟲ REWIND to <node> · N laps re-run every node between` when `rewind?/3`, else `→ <node> · ×N`.

  Stroke width is `2 + 13 × secs ÷ max secs` over every drawn arc (the artboard's `sw()`:
  thickness = minutes). A send naming a node the layout does not place, or with 0 laps, is skipped.
  """
  def arcs(layout, sends) do
    placed = Enum.filter(sends, &(placed?(layout, &1.from) and placed?(layout, &1.to) and &1.laps > 0))
    {into_fix, into_line} = Enum.split_with(placed, &(Map.get(layout.roles, &1.to) == :fix))
    returning = Enum.filter(into_fix, &(not is_nil(&1.returns_to) and placed?(layout, &1.returns_to)))

    groups = [
      {:send_fix, group(into_fix, & &1.from, & &1.to)},
      {:send_line, group(into_line, & &1.from, & &1.to)},
      {:return, group(returning, & &1.to, & &1.returns_to)}
    ]

    max_secs = groups |> Enum.flat_map(&elem(&1, 1)) |> Enum.map(& &1.secs) |> Enum.max(fn -> 0 end)

    Enum.flat_map(groups, fn {kind, gs} -> Enum.map(gs, &arc(kind, &1, layout, max_secs)) end)
  end

  defp placed?(layout, key), do: Map.has_key?(layout.pos, key)

  defp group(sends, a_fun, b_fun) do
    sends
    |> Enum.group_by(&{a_fun.(&1), b_fun.(&1)})
    |> Enum.map(fn {{a, b}, rows} ->
      %{a: a, b: b, laps: rows |> Enum.map(& &1.laps) |> Enum.sum(), secs: rows |> Enum.map(& &1.secs) |> Enum.sum()}
    end)
    |> Enum.sort_by(&{&1.a, &1.b})
  end

  defp arc(:send_fix, g, layout, max_secs) do
    {w, head} = stroke(g.secs, max_secs)
    {ax, ay} = top(layout.pos[g.a])
    b = layout.pos[g.b]
    {bx, by} = {b.x + b.w / 2, b.y + b.h}

    %{
      id: "vs-send-#{g.a}-#{g.b}",
      kind: :send,
      rewind: false,
      width: w,
      d: "M#{n(ax)},#{n(ay)} C#{n(ax)},#{n(ay - 40)} #{n(bx)},#{n(by + 40)} #{n(bx)},#{n(by + head * 1.2)}",
      arrow: VSL.arrow(bx, by, head, :up),
      label: "×#{g.laps}",
      label_x: Float.round((ax + bx) / 2 + 6, 1),
      label_y: Float.round((ay + by) / 2 + 3, 1),
      size: 9.5
    }
  end

  defp arc(:send_line, g, layout, max_secs) do
    {w, head} = stroke(g.secs, max_secs)
    {ax, ay} = top(layout.pos[g.a])
    {bx, by} = top(layout.pos[g.b])

    %{
      id: "vs-send-#{g.a}-#{g.b}",
      kind: :send,
      rewind: false,
      width: w,
      d: "M#{n(ax)},#{n(ay)} C#{n(ax)},128 #{n(bx)},128 #{n(bx)},#{n(by - head * 1.2)}",
      arrow: VSL.arrow(bx, by, head, :down),
      label: "#{g.a} failed · ×#{g.laps} → #{g.b}",
      label_x: Float.round((ax + bx) / 2, 1),
      label_y: 119,
      size: 10
    }
  end

  defp arc(:return, g, layout, max_secs) do
    {w, head} = stroke(g.secs, max_secs)
    {ax, ay} = top(layout.pos[g.a])
    {bx, by} = top(layout.pos[g.b])
    span = abs(layout.slots[g.a] - layout.slots[g.b])
    apex = max(44, 152 - span * 22)
    rewind = rewind?(layout, g.a, g.b)

    %{
      id: "vs-return-#{g.a}-#{g.b}",
      kind: :return,
      rewind: rewind,
      width: w,
      d: "M#{n(ax)},#{n(ay)} C#{n(ax)},#{n(apex)} #{n(bx)},#{n(apex)} #{n(bx)},#{n(by - head * 1.2)}",
      arrow: VSL.arrow(bx, by, head, :down),
      label: return_label(rewind, g),
      label_x: Float.round((ax + bx) / 2, 1),
      label_y: apex - 9,
      size: if(rewind, do: 11.5, else: 10)
    }
  end

  defp return_label(true, g), do: "⟲ REWIND to #{g.b} · #{g.laps} #{plural(g.laps, "lap")} re-run every node between"
  defp return_label(false, g), do: "→ #{g.b} · ×#{g.laps}"

  defp stroke(secs, max_secs) do
    w = if max_secs > 0, do: Float.round(2 + max(secs, 0) / max_secs * 13, 1), else: 2.0
    {w, w * 0.7 + 4}
  end

  defp top(box), do: {box.x + box.w / 2, box.y}

  defp n(x), do: VSL.num(x)

  # ── per-run presentation ──────────────────────────────────────────────────

  @doc """
  The layout's node boxes with their figures (`%{visits, visits_hot, rows, pass_pct}` merged in):
  visits = executions ÷ runs; a Do reads Work / Wait / $ per run, a Check Work / Pass / $ per run
  plus its pass strip (succeeded ÷ (succeeded + failed) — Flow Metrics' split), a Fix Rework /
  Laps / $ per lap. A node with no executions shows `—`.
  """
  def node_boxes(layout, stream) do
    rows = Map.new(stream.nodes, &{&1.node_key, &1})
    Enum.map(layout.nodes, &Map.merge(&1, figures(&1.role, Map.get(rows, &1.key), stream.runs)))
  end

  defp figures(role, nil, runs), do: %{visits: "", visits_hot: false, rows: box_rows(role, %{}, runs), pass_pct: nil}

  defp figures(role, row, runs) do
    visits = per_run(row.runs, runs) || 0.0

    %{
      visits: "×" <> :erlang.float_to_binary(visits * 1.0, decimals: 2),
      visits_hot: visits > @hot_visits,
      rows: box_rows(role, row, runs),
      pass_pct: if(role == :check, do: pass_rate(row) && round(pass_rate(row) * 100))
    }
  end

  defp box_rows(:fix, row, runs) do
    laps = Map.get(row, :runs)

    [
      row("Rework", fmt_minutes(per_run(row[:rework_total], runs)), :error, true),
      row("Laps", if(laps, do: Integer.to_string(laps), else: "—"), :error, true),
      row("$ / lap", VSL.fmt_money(money_per(row[:cost_total], laps || 0)), :secondary, false)
    ]
  end

  defp box_rows(:check, row, runs) do
    rate = pass_rate(row)
    low? = is_number(rate) and rate < @low_pass

    [
      row("Work", fmt_minutes(per_run(row[:work_total], runs)), :info, false),
      row("Pass", VSL.fmt_pct(rate), if(low?, do: :error, else: :ink), low?),
      row("$ / run", VSL.fmt_money(money_per(row[:cost_total], runs)), :secondary, false)
    ]
  end

  defp box_rows(_do, row, runs) do
    [
      row("Work", fmt_minutes(per_run(row[:work_total], runs)), :success, false),
      row("Wait", fmt_minutes(per_run(row[:wait_total], runs)), :warning, false),
      row("$ / run", VSL.fmt_money(money_per(row[:cost_total], runs)), :secondary, false)
    ]
  end

  defp row(k, v, tone, bold), do: %{k: k, v: v, tone: tone, bold: bold}

  defp pass_rate(row) do
    split = Map.get(row, :verdict_split) || %{}
    passed = Map.get(split, :succeeded, 0)
    decided = passed + Map.get(split, :failed, 0)
    if decided > 0, do: passed / decided
  end

  @doc """
  One ladder item per line node, aligned under its box (`ValueStreamComponents.ladder/1`'s shape):
  wait / work / rework per run, plus each fix's rework per run folded into the ONE line node that
  sends it the most seconds (else its first sender on the line). `color`: Do `success`, else `info`.
  """
  def ladder_items(layout, stream) do
    rows = Map.new(stream.nodes, &{&1.node_key, &1})
    folded = folded_rework(layout, stream, rows)

    Enum.map(layout.line, fn key ->
      box = Map.fetch!(layout.pos, key)
      row = Map.get(rows, key, %{})

      %{
        x: box.x,
        w: box.w,
        wait: per_run0(row[:wait_total], stream.runs),
        work: per_run0(row[:work_total], stream.runs),
        rework: per_run0(row[:rework_total], stream.runs) + Map.get(folded, key, 0.0),
        color: if(Map.get(layout.roles, key) == :do, do: role_token(:do), else: role_token(:check))
      }
    end)
  end

  defp folded_rework(layout, stream, rows) do
    Enum.reduce(layout.fixes, %{}, fn fix, acc ->
      case fold_target(layout, fix, stream.sends) do
        nil -> acc
        target -> Map.update(acc, target, rework_of(rows, fix, stream.runs), &(&1 + rework_of(rows, fix, stream.runs)))
      end
    end)
  end

  defp rework_of(rows, key, runs), do: rows |> Map.get(key, %{}) |> Map.get(:rework_total) |> per_run0(runs)

  defp fold_target(layout, fix, sends) do
    on_line = MapSet.new(layout.line)

    sends
    |> Enum.filter(&(&1.to == fix and MapSet.member?(on_line, &1.from)))
    |> Enum.group_by(& &1.from, & &1.secs)
    |> Enum.map(fn {from, secs} -> {from, Enum.sum(secs)} end)
    |> Enum.sort_by(fn {from, secs} -> {-secs, Map.fetch!(layout.slots, from)} end)
    |> case do
      [{from, _secs} | _] ->
        from

      [] ->
        layout.senders
        |> Map.get(fix, [])
        |> Enum.filter(&MapSet.member?(on_line, &1))
        |> Enum.min_by(&layout.slots[&1], fn -> nil end)
    end
  end

  @doc """
  The run's per-run totals: value-add (Σ Do `work_total`), checking (Σ Check `work_total`),
  rework (Σ `rework_total`), wait (Σ `wait_total`), `process = value_add + checking`, `wall =
  process + rework + wait` (held time excluded — it is the ⏸ terminal's). `rewind_cost` is
  Σ (`rework_total` + `rewind_total`) over the fixes with a REWIND re-entry ÷ runs (nil with none);
  `first_pass_run` / `first_pass_task` the rolled first-pass ratios; `spend` / `rework_spend`
  Σ `cost_total` (all nodes / fixes) ÷ runs.
  """
  def summary(layout, stream) do
    runs = stream.runs
    rows = stream.nodes
    by_role = fn role -> Enum.filter(rows, &(Map.get(layout.roles, &1.node_key) == role)) end
    value_add = sum_per_run(by_role.(:do), :work_total, runs)
    checking = sum_per_run(by_role.(:check), :work_total, runs)
    rework = sum_per_run(rows, :rework_total, runs)
    wait = sum_per_run(rows, :wait_total, runs)
    rewind_fixes = layout.reentries |> Enum.filter(& &1.rewind) |> Enum.map(& &1.fix) |> Enum.uniq()
    rewind_rows = Enum.filter(rows, &(&1.node_key in rewind_fixes))

    %{
      runs: runs,
      value_add: value_add,
      checking: checking,
      rework: rework,
      wait: wait,
      process: value_add + checking,
      wall: value_add + checking + rework + wait,
      rewind_fixes: rewind_fixes,
      rewind_cost:
        if(rewind_fixes != [],
          do: sum_per_run(rewind_rows, :rework_total, runs) + sum_per_run(rewind_rows, :rewind_total, runs)
        ),
      first_pass_run: ratio(stream.first_pass_runs, runs),
      first_pass_task: stream.foreach && ratio(stream.foreach.clean_copies, stream.foreach.copies),
      spend: money_sum_per(rows, runs),
      rework_spend: money_sum_per(by_role.(:fix), runs)
    }
  end

  @doc "The RUN LEAD TIME bar's two bands, from `summary/2`: PROCESS TIME and RUN WALL-CLOCK."
  def bands(s) do
    [
      %{
        id: "vs-band-process",
        k: "PROCESS TIME",
        sub: "touch time, critical path",
        total: fmt_minutes(s.process),
        tone: :success,
        segments: segments([{:value_add, s.value_add, "value-add "}, {:checking, s.checking, "checking "}])
      },
      %{
        id: "vs-band-wall",
        k: "RUN WALL-CLOCK",
        sub: "engine start → finish",
        total: fmt_minutes(s.wall),
        tone: :ink,
        segments:
          segments([
            {:value_add, s.value_add, ""},
            {:checking, s.checking, ""},
            {:rework, s.rework, "rework "},
            {:wait, s.wait, "wait "}
          ])
      }
    ]
  end

  defp segments(parts),
    do: for({key, secs, prefix} <- parts, secs > 0, do: %{key: key, grow: secs, label: prefix <> fmt_minutes(secs)})

  @doc "The queue triangle's copy: two label lines from the flow's isolation class and the mean wait."
  def queue(isolation, %{mean_secs: mean}) do
    {lead, slot} = slot_phrase(isolation)
    %{lead: lead, slot: slot, value: fmt_minutes(mean)}
  end

  defp slot_phrase(:exclusive), do: {"queued for the", "exclusive slot"}
  defp slot_phrase(_shared), do: {"queued for a", "shared slot"}

  @doc "The done / ⏸ needs_input terminals' copy, and the x of the park feeder (first park-able line node)."
  def terminals(layout, stream, landing) do
    %{runs: runs, done_runs: done, parked_runs: parked} = stream
    feeder = Enum.find(layout.line, &(&1 in layout.parkable))

    %{
      done_label: if(landing, do: "done → #{landing}", else: "done"),
      done_sub: "#{done} of #{runs} #{plural(runs, "run")} · #{VSL.fmt_pct(ratio(done, runs))}",
      park_sub: "#{parked} #{plural(parked, "run")} · the baton passes to a human",
      park_note: "#{length(layout.parkable)} of the #{layout.node_count} nodes can park here",
      feeder_x: feeder && Map.fetch!(layout.pos, feeder).x + 40
    }
  end

  @doc "The header's explainer line: node and edge counts plus the isolation class."
  def explainer(layout, isolation), do: "#{layout.node_count} nodes · #{layout.edge_count} edges · #{isolation} isolation"

  @doc "The daisyUI token a node role is drawn in: Do `success`, Check `info`, Fix `error`."
  def role_token(:do), do: "success"
  def role_token(:check), do: "info"
  def role_token(:fix), do: "error"

  @doc "The role chip's label."
  def role_label(role), do: role |> Atom.to_string() |> String.upcase()

  @doc "Seconds as the artboard's minutes: `N.Nm` under an hour, `Hh MMm` above; nil → `—`."
  def fmt_minutes(nil), do: "—"
  def fmt_minutes(secs) when secs < 3_600, do: "#{:erlang.float_to_binary(secs / 60, decimals: 1)}m"

  def fmt_minutes(secs) do
    total = round(secs / 60)
    "#{div(total, 60)}h #{total |> rem(60) |> Integer.to_string() |> String.pad_leading(2, "0")}m"
  end

  defp per_run(nil, _runs), do: nil
  defp per_run(_total, 0), do: nil
  defp per_run(total, runs), do: total / runs

  defp per_run0(total, runs), do: per_run(total, runs) || 0.0

  defp sum_per_run(rows, key, runs), do: rows |> Enum.map(&(Map.get(&1, key) || 0)) |> Enum.sum() |> per_run0(runs)

  defp money_per(nil, _n), do: nil
  defp money_per(_total, 0), do: nil
  defp money_per(%Decimal{} = total, n), do: total |> Decimal.div(n) |> Decimal.round(2)

  defp money_sum_per(rows, runs) do
    case rows |> Enum.map(&Map.get(&1, :cost_total)) |> Enum.reject(&is_nil/1) do
      [] -> nil
      costs -> costs |> Enum.reduce(Decimal.new(0), &Decimal.add/2) |> money_per(runs)
    end
  end

  defp ratio(_part, 0), do: nil
  defp ratio(part, whole), do: part / whole

  defp plural(1, word), do: word
  defp plural(_n, word), do: word <> "s"
end
