defmodule RelayWeb.ValueStreamComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RelayWeb.ValueStreamStates

  alias RelayWeb.ValueStreamComponents, as: C
  alias RelayWeb.ValueStreamFlowLayout, as: FL
  alias RelayWeb.ValueStreamLayout, as: VSL

  @hatch "repeating-linear-gradient(45deg, color-mix(in oklab, var(--color-warning) 55%, var(--color-base-100)) 0 5px, color-mix(in oklab, var(--color-warning) 25%, var(--color-base-100)) 5px 10px)"

  defp text(html, selector),
    do: html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()

  test "stream_box: a flow box links out, is tinted with its baton token and shows its visits badge" do
    box = re_states() |> VSL.boxes() |> Enum.at(1)

    html =
      render_component(&C.stream_box/1,
        box: box,
        rows: VSL.box_rows(box.state, :flow, %{nodes: 1}),
        href: "/board/b/value-stream/spec?window=7d",
        metrics_href: "/board/b/flows/spec/metrics?window=7d"
      )

    assert html =~ ~s(id="vs-box-2")
    assert html =~ ~s(href="/board/b/value-stream/spec?window=7d")
    assert html =~ ~s(id="vs-box-2-metrics")
    assert text(html, "#vs-box-2-metrics") == "Flow metrics →"
    assert html =~ "left:310px;top:150px;width:186px;height:132px"
    assert html =~ "border-radius:10px"
    assert html =~ "background:color-mix(in oklab, var(--color-secondary) 6%, var(--color-base-100))"
    assert text(html, ".vs-kind") == "AI"
    assert text(html, ".vs-visits") == "×2"
    assert html =~ "Mean work"
  end

  test "stream_box: a queue box is a plain box with no visits badge" do
    box = re_states() |> VSL.boxes() |> hd()
    html = render_component(&C.stream_box/1, box: box, rows: VSL.box_rows(box.state, :flow, %{}))

    refute html =~ "<a"
    refute html =~ "vs-visits"
    assert text(html, ".vs-kind") == "QUEUE"
    assert html =~ "var(--color-warning) 6%"
  end

  test "stream_line: connectors, the section labels and a rose arc per sending-back gate" do
    boxes = VSL.boxes(re_states())

    html =
      render_component(&C.stream_line/1, boxes: boxes, geometry: VSL.geometry(9), first: "Next up", last: "Done")

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query(".vs-connector") |> Enum.count() == 8
    assert html =~ ~s(id="vs-arc-8")
    assert html =~ ~s(id="vs-arc-3")
    assert html =~ "Request changes · 50% → re-runs Code"
    assert html =~ "stroke:var(--color-error);stroke-opacity:0.85;stroke-width:15.5;"
    assert html =~ "REWORK — Request changes sends the card back"
    assert html =~ "THE CARD STREAM — Next up → Done"
  end

  test "ladder: aligned rungs, a rose rework tail and Δ at the right end (off-stream time included)" do
    items = VSL.ladder_items(VSL.boxes(re_states()))

    html = render_component(&C.ladder/1, items: items, geometry: VSL.geometry(9))
    assert text(html, "#vs-ladder-total") == "Δ 1.6d"
    assert html =~ "stroke:var(--color-error);stroke-width:6;"
    assert html =~ "TIME — rise = the card sitting still, valley = something happening to it"

    with_outside = render_component(&C.ladder/1, items: items, geometry: VSL.geometry(9), outside: 86_400)
    assert text(with_outside, "#vs-ladder-total") == "Δ 2.6d"
    assert with_outside =~ "incl. 1.0d off-stream"
  end

  test "lead_bar: three to-scale segments — agent violet, human blue, nobody hatched amber — and the total" do
    html = render_component(&C.lead_bar/1, baton: %{agent: 600, human: 1_800, nobody: 3_600}, total: "1.7h")

    assert html =~ "CARD LEAD TIME · to scale"
    assert text(html, "#vs-lead-bar-agent") == "agent working 10m"
    assert text(html, "#vs-lead-bar-human") == "human deciding 30m"
    assert text(html, "#vs-lead-bar-nobody") == "nobody · queued 1.0h"
    assert html =~ "background:var(--color-secondary)"
    assert html =~ "background:var(--color-primary)"
    assert html =~ @hatch
    assert text(html, "#vs-lead-bar-total") == "1.7h"
  end

  test "stat_tile: a hot tile is error-tinted; a plain one sits on base-100" do
    hot = render_component(&C.stat_tile/1, id: "t1", label: "FLOW EFFICIENCY", value: "2.0%", tone: :error, hot: true)
    assert hot =~ "border:1px solid color-mix(in oklab, var(--color-error) 35%, var(--color-base-100))"
    assert hot =~ "background:color-mix(in oklab, var(--color-error) 4%, var(--color-base-100))"
    assert text(hot, "#t1-value") == "2.0%"

    plain = render_component(&C.stat_tile/1, id: "t2", label: "$ / CARD", value: "$1.50", sub: "all flows")
    assert plain =~ "border:1px solid var(--color-base-300);background:var(--color-base-100)"
    assert text(plain, "#t2-sub") == "all flows"
  end

  test "baton_legend: AI and HUMAN chips, the hatched queue swatch and the rose rework bar" do
    html = render_component(&C.baton_legend/1, %{})

    assert html =~ "agent flow"
    assert html =~ "review gate — Approve / Request changes"
    assert html =~ "queue — nobody holds the baton"
    assert html =~ "Request changes — the card-level rework loop"
    assert html =~ @hatch
    assert html =~ "background:var(--color-error)"
  end

  test "ladder: a custom label and footnote (level 2)" do
    items = VSL.ladder_items(VSL.boxes(re_states()))

    html =
      render_component(&C.ladder/1,
        id: "vs-flow-ladder",
        items: items,
        geometry: VSL.geometry(9),
        label: "TIME — each rung sits under the node it measures",
        footnote: "a fix’s minutes are folded into the rung of the check that causes most of them"
      )

    assert html =~ "TIME — each rung sits under the node it measures"
    refute html =~ "rise = the card sitting still"
    assert text(html, "#vs-flow-ladder-footnote") =~ "folded into the rung of the check"
  end

  defp node_row(key, attrs) do
    base = %{node_key: key, runs: 1, work_total: nil, rework_total: nil, wait_total: nil, cost_total: nil}
    base |> Map.put(:verdict_split, %{}) |> Map.merge(Map.new(attrs))
  end

  describe "level 2 (RE349)" do
    setup do
      attrs = Enum.find(Relay.Flows.DefaultLibrary.all(), &(&1.key == "code"))
      flow = %Schemas.Flow{board_id: 1} |> Schemas.Flow.changeset(attrs) |> Ecto.Changeset.apply_action!(:build)
      %{layout: FL.layout(flow)}
    end

    test "flow_node_box: a fix is dashed rose with FIX; a check carries its pass strip; hot visits are rose",
         %{layout: layout} do
      stream = %{
        runs: 2,
        nodes: [
          node_row("final_fix", rework_total: 360, cost_total: Decimal.new("0.90")),
          node_row("precommit", runs: 3, work_total: 480, verdict_split: %{succeeded: 2, failed: 1})
        ]
      }

      boxes = Map.new(FL.node_boxes(layout, stream), &{&1.key, &1})

      fix = render_component(&C.flow_node_box/1, box: boxes["final_fix"])
      assert fix =~ ~s(id="vs-node-final_fix")
      assert fix =~ "vs-node-fix"
      assert fix =~ "border:1px dashed color-mix(in oklab, var(--color-error) 55%, var(--color-base-100))"
      assert fix =~ "width:136px;height:92px"
      assert text(fix, ".vs-role") == "FIX"
      assert text(fix, ".vs-node-type") == "agent"
      assert fix =~ "Rework"
      refute fix =~ "vs-pass-strip"

      check = render_component(&C.flow_node_box/1, box: boxes["precommit"])
      assert text(check, ".vs-role") == "CHECK"
      assert check =~ "background:var(--color-info)"
      assert check =~ "width:67%;background:var(--color-success)"
      assert text(check, ".vs-node-visits") == "×1.50"
      assert check =~ "color:color-mix(in oklab, var(--color-error) 70%, var(--color-base-content))"

      plain = render_component(&C.flow_node_box/1, box: boxes["branch"])
      assert text(plain, ".vs-role") == "DO"
      assert plain =~ "background:var(--color-success)"
      assert plain =~ "border:1px solid var(--color-base-300)"
      refute plain =~ "vs-node-visits"
    end

    test "flow_map: band labels, both verify frames, the foreach loop, arcs, the queue and both terminals",
         %{layout: layout} do
      sends = [
        %{
          from: "acceptance",
          to: "final_fix",
          returns_to: "precommit",
          laps: 2,
          to_secs: 600,
          rewind_secs: 900,
          secs: 1_500
        }
      ]

      html =
        render_component(&C.flow_map/1,
          layout: layout,
          arcs: FL.arcs(layout, sends),
          queue: FL.queue(:exclusive, %{mean_secs: 150, jobs: 2}),
          terminals: FL.terminals(layout, %{runs: 2, done_runs: 2, parked_runs: 1}, "Review")
        )

      assert text(html, "#vs-band-rework") ==
               "REWORK — everything above the line exists only because something failed"

      assert text(html, "#vs-band-stream") == "THE STREAM — one line, in execution order"
      assert text(html, "#vs-verify-1") == "VERIFY BLOCK ①"
      assert text(html, "#vs-verify-2") == "VERIFY BLOCK ② — byte-identical run commands"
      assert html =~ "stroke-dasharray:6 5"
      assert text(html, "#vs-foreach-loop") == "foreach_remaining · next sub-task · planned, not waste"
      assert html =~ "stroke-dasharray:8 6"
      assert text(html, "#vs-send-acceptance-final_fix") == "×2"
      assert text(html, "#vs-return-final_fix-precommit") == "⟲ REWIND to precommit · 2 laps re-run every node between"
      assert html =~ "stroke:var(--color-error);stroke-opacity:0.85;stroke-width:15.0;"
      assert text(html, "#vs-queue") =~ "2.5m"
      assert text(html, "#vs-queue") =~ "queued for the"
      assert text(html, "#vs-queue") =~ "exclusive slot"
      assert html =~ "fill:var(--color-warning)"
      assert text(html, "#vs-term-done") =~ "done → Review"
      assert text(html, "#vs-term-done") =~ "2 of 2 runs · 100%"
      assert text(html, "#vs-term-park") =~ "⏸ needs_input"
      assert text(html, "#vs-term-park") =~ "1 run · the baton passes to a human"
      assert text(html, "#vs-park-note") == "8 of the 21 nodes can park here"
      assert html |> LazyHTML.from_fragment() |> LazyHTML.query(".vs-connector") |> Enum.count() == 15
      refute html =~ "oklch("
    end

    test "flow_legend: DO / CHECK / FIX chips, the send-back and foreach swatches, the visits note" do
      html = render_component(&C.flow_legend/1, runs: 128)

      assert html =~ "value-add"
      assert html =~ "necessary, not value-add"
      assert html =~ "rework only · above the line"
      assert html =~ "thickness = minutes"
      assert html =~ "label = laps / 128 runs"
      assert html =~ "border-top:2px dashed"
      assert html =~ "×n in a header = visits per run"
      assert html =~ "background:var(--color-success)"
      assert html =~ "background:var(--color-info)"
      assert html =~ "background:var(--color-error)"
    end

    test "run_lead_bands: PROCESS TIME and RUN WALL-CLOCK, coloured by class, with totals" do
      bands =
        FL.bands(%{value_add: 600.0, checking: 240.0, rework: 300.0, wait: 60.0, process: 840.0, wall: 1_200.0})

      html = render_component(&C.run_lead_bands/1, bands: bands)

      assert html =~ "RUN LEAD TIME · to scale"
      assert text(html, "#vs-band-process-value_add") == "value-add 10.0m"
      assert text(html, "#vs-band-process-checking") == "checking 4.0m"
      assert text(html, "#vs-band-wall-rework") == "rework 5.0m"
      assert text(html, "#vs-band-wall-wait") == "wait 1.0m"
      assert text(html, "#vs-band-process-total") == "14.0m"
      assert text(html, "#vs-band-wall-total") == "20.0m"
      assert html =~ "background:var(--color-success)"
      assert html =~ "background:var(--color-info)"
      assert html =~ "background:var(--color-error)"
      assert html =~ @hatch
    end
  end
end
