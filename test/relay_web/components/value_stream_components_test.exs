defmodule RelayWeb.ValueStreamComponentsTest do
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest
  import RelayWeb.ValueStreamStates

  alias RelayWeb.ValueStreamComponents, as: C
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
        href: "/board/b/flows/spec/metrics?window=7d"
      )

    assert html =~ ~s(id="vs-box-2")
    assert html =~ ~s(href="/board/b/flows/spec/metrics?window=7d")
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

  test "stream_list: one row per state with a baton-coloured bar to scale and the rework note" do
    rows = VSL.list_rows(re_states(), 140_940.0)
    html = render_component(&C.stream_list/1, rows: rows, class: "md:hidden")

    doc = LazyHTML.from_fragment(html)
    assert doc |> LazyHTML.query("#vs-list > li") |> Enum.count() == 9
    assert doc |> LazyHTML.query(".vs-row-bar") |> Enum.count() == 9
    assert html =~ "md:hidden"
    assert html =~ "width:46.0%"
    assert text(html, "#vs-row-8-rework") == "Request changes 50% → re-runs Code"
  end
end
