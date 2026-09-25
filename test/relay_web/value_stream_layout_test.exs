defmodule RelayWeb.ValueStreamLayoutTest do
  use ExUnit.Case, async: true

  import RelayWeb.ValueStreamStates

  alias RelayWeb.ValueStreamLayout, as: VSL

  describe "geometry — the artboard's cardLay() (W 186, GAP 58, H 132, x0 66, y 150)" do
    test "boxes sit on one line" do
      boxes = VSL.boxes(re_states())

      assert Enum.map(boxes, & &1.x) == [66, 310, 554, 798, 1042, 1286, 1530, 1774, 2018]
      assert Enum.all?(boxes, &(&1.y == 150 and &1.w == 186 and &1.h == 132))
    end

    test "the canvas fits nine boxes and puts the ladder rows under them" do
      assert VSL.geometry(9) == %{
               w: 2264,
               h: 488,
               line_end: 2204,
               mid_y: 216,
               box_y: 150,
               box_h: 132,
               t_y0: 334,
               t_y1: 392,
               gap: 58
             }
    end

    test "connectors join each right edge to the next box's arrowhead on the mid line" do
      [first | _] = connectors = VSL.connectors(VSL.boxes(re_states()))

      assert length(connectors) == 8
      assert Map.take(first, [:x1, :x2, :y]) == %{x1: 252, x2: 301, y: 216}
      assert String.ends_with?(first.arrow, " 310,216")
    end
  end

  describe "arcs/1 — Request-changes rework above the line" do
    test "each gate that sends work back arcs to its rework target, width 2.5 + rate × 26" do
      arcs = VSL.arcs(VSL.boxes(re_states()))
      assert Enum.map(arcs, & &1.stage_id) == [3, 8]

      [spec_review, review] = arcs
      assert spec_review.width == 7.7
      assert spec_review.label == "Request changes · 20% → re-runs Spec"
      assert review.width == 15.5
      assert review.label == "Request changes · 50% → re-runs Code"
      assert String.starts_with?(review.d, "M1867.0,150 C1867.0,76 1623.0,76 1623.0,")
      assert String.ends_with?(review.arrow, " 1623.0,150")
    end

    test "no arc for a gate with no rejections, no decisions or no rework target" do
      none = re_states() |> put_state(8, approve_rate: 1.0) |> put_state(3, approve_rate: nil)
      assert VSL.arcs(VSL.boxes(none)) == []

      no_target = re_states() |> put_state(8, rework_target: nil) |> put_state(3, approve_rate: 1.0)
      assert VSL.arcs(VSL.boxes(no_target)) == []
    end

    test "send_back_rate/1 is set only for a gate that rejected" do
      [_, spec, spec_review | _] = re_states()
      assert_in_delta VSL.send_back_rate(spec_review), 0.2, 1.0e-9
      assert VSL.send_back_rate(spec) == nil
      assert VSL.send_back_rate(%{spec_review | approve_rate: 1.0}) == nil
    end
  end

  describe "the ladder" do
    test "queues and gates rise by their wait; flows sink by first-visit work plus a rework tail" do
      items = VSL.ladder_items(VSL.boxes(re_states()))

      assert Enum.at(items, 0) == %{x: 66, w: 186, wait: 64_800.0, work: 0, rework: 0, color: "warning"}
      assert Enum.at(items, 1) == %{x: 310, w: 186, wait: 0, work: 360.0, rework: 360.0, color: "secondary"}
      assert Enum.at(items, 2).wait == 19_800.0
      assert List.last(items).color == "success"
    end

    test "rungs split each valley by work share and accumulate to the stream total" do
      {rungs, total} = VSL.rungs(VSL.ladder_items(VSL.boxes(re_states())), 58)
      spec = Enum.at(rungs, 1)

      assert spec.rise_x == 252
      assert spec.work_w == 93.0
      assert spec.cum == 65_520.0
      assert total == 140_940.0
    end
  end

  describe "box_rows/3" do
    test "averaged view (:flow) reads Mean … by kind, like the artboard" do
      [next_up, spec, spec_review | _] = states = re_states()
      pairs = &Enum.map(&1, fn r -> {r.k, r.v} end)

      assert pairs.(VSL.box_rows(next_up, :flow, %{})) == [
               {"Mean wait", "18.0h"},
               {"Cards here", "7"},
               {"Baton", "nobody"}
             ]

      assert pairs.(VSL.box_rows(spec, :flow, %{nodes: 1})) == [
               {"Mean work", "10m"},
               {"Nodes", "1"},
               {"$ / card", "$0.30"}
             ]

      assert pairs.(VSL.box_rows(spec_review, :flow, %{})) ==
               [{"Mean to decide", "5.5h"}, {"Approve", "80%"}, {"Sends back", "20%"}]

      assert pairs.(VSL.box_rows(List.last(states), :flow, %{cards_per_week: 14.0})) == [{"Cards / week", "14.0"}]
    end

    test "single-card view (:card) shows that card's actuals" do
      [next_up, spec, spec_review | _] = states = re_states()
      pairs = &Enum.map(&1, fn r -> {r.k, r.v} end)
      done = List.last(states)

      assert hd(VSL.box_rows(next_up, :card, %{})).k == "Wait"
      assert hd(VSL.box_rows(spec, :card, %{nodes: 1})).k == "Work"

      assert pairs.(VSL.box_rows(spec_review, :card, %{approved: 1, rejected: 1})) ==
               [{"Time to decide", "5.5h"}, {"Approved", "1"}, {"Rejected", "1"}]

      assert pairs.(VSL.box_rows(done, :card, %{done_at: ~U[2026-09-03 12:00:00Z]})) == [{"Done", "Sep 3"}]
      assert pairs.(VSL.box_rows(done, :card, %{done_at: nil})) == [{"Done", "in progress"}]
    end

    test "a flow with more than ten nodes is flagged hot" do
      code = Enum.at(re_states(), 6)
      assert Enum.at(VSL.box_rows(code, :flow, %{nodes: 21}), 1) == %{k: "Nodes", v: "21", tone: :error, bold: true}
    end
  end

  describe "the lead bar" do
    test "lead segments follow ValueStream.batons/0 and drop empty batons" do
      assert VSL.lead_segments(%{agent: 600, human: 0, nobody: 3_600}) == [
               %{key: :agent, grow: 600, label: "agent working 10m"},
               %{key: :nobody, grow: 3_600, label: "nobody · queued 1.0h"}
             ]
    end
  end

  describe "formatters" do
    test "durations read s / m / h / d like the artboard's hrs()" do
      assert VSL.fmt_duration(nil) == "—"
      assert VSL.fmt_duration(0) == "0s"
      assert VSL.fmt_duration(30) == "30s"
      assert VSL.fmt_duration(790) == "13m"
      assert VSL.fmt_duration(5_400) == "1.5h"
      assert VSL.fmt_duration(140_940.0) == "1.6d"
    end

    test "percentages, money, visits and rates" do
      assert VSL.fmt_pct(0.696) == "70%"
      assert VSL.fmt_pct(nil) == "—"
      assert VSL.fmt_pct1(100 / 790) == "12.7%"
      assert VSL.fmt_money(Decimal.new("1.5")) == "$1.50"
      assert VSL.fmt_money(Decimal.new("12.345")) == "$12.3"
      assert VSL.fmt_money(nil) == "—"
      assert VSL.fmt_visits(1.0) == ""
      assert VSL.fmt_visits(2.0) == "×2"
      assert VSL.fmt_visits(1.25) == "×1.25"
      assert VSL.fmt_rate(nil) == "—"
      assert VSL.fmt_rate(3.456) == "3.5"
    end
  end
end
