defmodule Relay.ValueStreamSummaryTest do
  use Relay.DataCase, async: true

  import Relay.ValueStreamFixtures

  alias Relay.Runs
  alias Relay.ValueStream

  # Four done cards and one in flight, relative to now so the 7d/30d windows bite:
  #   A  recent  Next up → Code@100 → Review@300 → Done@400 (approved)            lead 400
  #   B  recent  Next up → Code@100 → Review@200 → Code@250 (rejected)
  #                      → Review@350 → Done@450 (approved)                       lead 450
  #   C  20d ago Next up → Code@100 → Done@200                                     lead 200
  #   D  recent, ARCHIVED  Next up → Backlog@50 → Next up@100 → Code@150 → Done@250  lead 250
  #   E  recent, still in Code — never counted
  # done_at order, newest first: D, B, A, C.
  setup do
    s = re_board()
    recent = DateTime.add(DateTime.truncate(DateTime.utc_now(), :second), -2 * 86_400, :second)
    old = DateTime.add(recent, -18 * 86_400, :second)

    a = card_in(s.done, recent)
    walk(a, [{s.next_up, 0}, {s.code, 100}, {s.review, 300}, {s.done, 400}], recent)
    decided(a, :approved, s.review, s.done, at(400, recent))
    executed(a, "implement", at(120, recent), at(200, recent), cost: Decimal.new("2.00"))
    executed(a, "spec_review", at(200, recent), at(230, recent))

    b_base = at(1000, recent)
    b = card_in(s.done, b_base)
    walk(b, [{s.next_up, 0}, {s.code, 100}, {s.review, 200}, {s.code, 250}], b_base)
    decided(b, :rejected, s.review, s.code, at(250, b_base))
    walk(b, [{s.code, 250}, {s.review, 350}, {s.done, 450}], b_base)
    decided(b, :approved, s.review, s.done, at(450, b_base))

    c = card_in(s.done, old)
    walk(c, [{s.next_up, 0}, {s.code, 100}, {s.done, 200}], old)

    d_base = at(2000, recent)
    d = card_in(s.done, d_base, archived_at: d_base)
    walk(d, [{s.next_up, 0}, {s.backlog, 50}, {s.next_up, 100}, {s.code, 150}, {s.done, 250}], d_base)

    e = card_in(s.code, recent, status: :working)
    walk(e, [{s.next_up, 0}, {s.code, 100}], recent)

    %{s: s, a: a}
  end

  test "last: n keeps the n most recently done cards", %{s: s} do
    summary = ValueStream.stream_summary(s.board.id, last: 2)

    assert summary.cards == 2
    assert summary.mean_lead_secs == (250 + 450) / 2
  end

  test "window: keeps cards done inside the window; an unknown window falls back to the default", %{s: s} do
    assert ValueStream.stream_summary(s.board.id, window: "7d").cards == 3
    assert ValueStream.stream_summary(s.board.id, window: "30d").cards == 4
    assert ValueStream.stream_summary(s.board.id, window: "bogus").cards == 4
    assert ValueStream.stream_summary(s.board.id, window: "all").cards == 4
  end

  test "the default is the last 20; archived done cards count and unfinished ones don't", %{s: s} do
    assert ValueStream.default_last() == 20
    summary = ValueStream.stream_summary(s.board.id)

    assert summary.cards == 4
    assert summary.mean_lead_secs == (400 + 450 + 200 + 250) / 4
    assert summary.median_lead_secs == (250 + 400) / 2
  end

  test "per-state means plus outside time sum to the mean lead time, and so do the baton means", %{s: s} do
    summary = ValueStream.stream_summary(s.board.id)

    states_total = summary.states |> Enum.map(& &1.mean_secs) |> Enum.sum()
    assert_in_delta states_total + summary.outside_secs, summary.mean_lead_secs, 1.0e-6
    assert summary.outside_secs == 50 / 4

    baton_total = summary.baton_secs |> Map.values() |> Enum.sum()
    assert_in_delta baton_total, summary.mean_lead_secs, 1.0e-6
    assert summary.baton_secs |> Map.keys() |> Enum.sort() == Enum.sort(ValueStream.batons())

    for state <- summary.states do
      assert_in_delta state.mean_baton |> Map.values() |> Enum.sum(), state.mean_secs, 1.0e-6
    end
  end

  test "states follow stream_states/1 and carry visits and gate approve rates", %{s: s} do
    summary = ValueStream.stream_summary(s.board.id)

    assert Enum.map(summary.states, & &1.stage_id) == Enum.map(ValueStream.stream_states(s.board.id), & &1.stage_id)

    code = Enum.find(summary.states, &(&1.stage_id == s.code.id))
    assert code.mean_visits == 5 / 4
    assert code.approve_rate == nil

    review = Enum.find(summary.states, &(&1.stage_id == s.review.id))
    assert review.approve_rate == 2 / 3

    spec_review = Enum.find(summary.states, &(&1.stage_id == s.spec_review.id))
    assert spec_review.approve_rate == nil
  end

  test "cost is averaged per card and flow efficiency is Σvalue-add / Σlead", %{s: s} do
    code_flow(s.board)
    summary = ValueStream.stream_summary(s.board.id)

    assert Decimal.equal?(summary.mean_cost, Decimal.new("0.50"))
    # only A's `implement` (80s) is a :do node
    assert summary.flow_efficiency == 80 / (400 + 450 + 200 + 250)
  end

  test "an empty board summarizes to zero cards" do
    board = insert(:board)
    summary = ValueStream.stream_summary(board.id)

    assert summary.cards == 0
    assert summary.states == []
    assert summary.median_lead_secs == nil
    assert summary.flow_efficiency == nil
    assert summary.mean_cost == nil
  end

  describe "flow_agent_secs/3" do
    test "equals Flow Metrics' Σ duration_total for a card whose executions don't overlap", %{s: s, a: a} do
      flow = code_flow(s.board)

      metrics_total =
        flow |> Runs.node_metrics_for_flow(card_id: a.id) |> Enum.map(& &1.duration_total) |> Enum.sum()

      assert metrics_total == 110
      assert ValueStream.flow_agent_secs(s.board.id, "code", card_id: a.id) == metrics_total
    end

    test "counts overlapping executions once — never more than the Flow Metrics sum", %{s: s} do
      flow = code_flow(s.board)
      card = card_in(s.done, at(0))
      walk(card, [{s.next_up, 0}, {s.code, 10}, {s.done, 500}])
      executed(card, "implement", at(0), at(100))
      executed(card, "implement", at(50), at(150))

      metrics_total =
        flow |> Runs.node_metrics_for_flow(card_id: card.id) |> Enum.map(& &1.duration_total) |> Enum.sum()

      assert metrics_total == 200
      assert ValueStream.flow_agent_secs(s.board.id, "code", card_id: card.id) == 150
    end

    test "without card_id it sums over the same card set as the summary", %{s: s} do
      assert ValueStream.flow_agent_secs(s.board.id, "code", last: 20) == 110
      assert ValueStream.flow_agent_secs(s.board.id, "other", last: 20) == 0
    end
  end

  test "Runs.metric_window_since/1 is the one window → cutoff mapping" do
    assert Runs.metric_window_since("all") == nil
    assert_in_delta DateTime.diff(DateTime.utc_now(), Runs.metric_window_since("7d")), 7 * 86_400, 5
    assert Runs.metric_window_since("bogus") == Runs.metric_window_since(Runs.default_window())
  end
end
