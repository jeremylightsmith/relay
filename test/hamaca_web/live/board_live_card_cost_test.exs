defmodule HamacaWeb.BoardLiveCardCostTest do
  @moduledoc """
  RE514 — the drawer's card cost: the header chip (every tab, a click opens Run), the Run tab's
  `RUNS · N · $X TOTAL` heading with live `so far` / `· N unpriced`, and the BY STAGE panel.
  Everything is hidden while nothing on the card is priced.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Hamaca.Runs

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))
    %{board: board, code: code}
  end

  defp open(conn, board, ref, query \\ "") do
    {:ok, view, _html} = live(conn, "/board/#{board.slug}?card=#{ref}#{query}")
    render_async(view)
    view
  end

  defp ai_card(stage, title) do
    {:ok, card} = Cards.create_card(stage, %{title: title})
    {:ok, card} = Cards.assign_ai(card)
    {:ok, card} = Cards.set_status(card, %{status: :working})
    card
  end

  defp doc(view), do: view |> render() |> LazyHTML.from_fragment()
  defp text(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.text() |> String.trim()
  defp texts(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> Enum.map(&String.trim(LazyHTML.text(&1)))
  defp styles(view, selector), do: view |> doc() |> LazyHTML.query(selector) |> LazyHTML.attribute("style")

  # A finished run labelled by its flow key (no flow row, so RunDetail.stage_label/1 falls back to it).
  defp finished_run(card, flow_key, status, costs, inserted_at) do
    run =
      insert(:run,
        card: card,
        flow_key: flow_key,
        status: status,
        current_node: nil,
        inserted_at: inserted_at,
        finished_at: DateTime.add(inserted_at, 600, :second)
      )

    for cost <- costs, do: insert(:node_execution, run: run, cost: cost && Decimal.new(cost))
    run
  end

  # The settled card: Design 1.03 + Spec 0.31 + Code 1.84 = $3.18.
  defp settled_card(ctx) do
    card = ai_card(ctx.code, "Settled")
    finished_run(card, "Design", :done, ["1.03"], ~U[2026-07-01 10:00:00Z])
    finished_run(card, "Spec", :done, ["0.31"], ~U[2026-07-02 10:00:00Z])
    finished_run(card, "Code", :done, ["1.84"], ~U[2026-07-03 10:00:00Z])
    card
  end

  test "10: the chip reads the card total on Detail and a click opens the Run tab", ctx do
    card = settled_card(ctx)
    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))
    view |> element("#card-drawer-tab-detail") |> render_click()

    assert text(view, "#card-drawer-cost-chip") == "$3.18"

    view |> element("#card-drawer-cost-chip") |> render_click()

    refute has_element?(view, "#card-drawer-tab-panel-run.hidden")
    assert has_element?(view, "#card-drawer-tab-panel-run")
    assert text(view, "#run-cost-total") == "$3.18"
    assert has_element?(view, "#card-drawer-tab-panel-run #run-list", "RUNS · 3")
  end

  test "11: the BY STAGE panel has one row per stage and no failed row for a settled card", ctx do
    card = settled_card(ctx)
    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))
    view |> element("#card-drawer-tab-run") |> render_click()

    assert texts(view, "#run-cost-by-stage .run-cost-stage .run-cost-stage-name") == ["Design", "Spec", "Code"]
    assert [_design, _spec, code_bar] = styles(view, "#run-cost-by-stage .run-cost-stage .run-cost-bar")
    assert code_bar =~ "width:100%"
    refute has_element?(view, "#run-cost-failed")
  end

  test "12: failed and cancelled runs fill the failed row and count against their stage", ctx do
    card = ai_card(ctx.code, "Rough ride")
    finished_run(card, "Design", :cancelled, ["0.50"], ~U[2026-07-01 10:00:00Z])
    finished_run(card, "Spec", :done, ["0.25"], ~U[2026-07-02 10:00:00Z])
    finished_run(card, "Code", :failed, ["1.00"], ~U[2026-07-03 10:00:00Z])
    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))
    view |> element("#card-drawer-tab-run") |> render_click()

    rows =
      Enum.zip(texts(view, ".run-cost-stage .run-cost-stage-name"), texts(view, ".run-cost-stage .run-cost-stage-runs"))

    assert {"Code", "1 run · 1 failed"} in rows
    assert text(view, "#run-cost-failed .run-cost-stage-runs") == "2 runs"
    assert text(view, "#run-cost-failed .run-cost-stage-cost") == "$1.50"
    assert text(view, "#run-cost-total") == "$1.75"
  end

  test "13: an in-flight card shows ≥ and so far, then settles live on a run broadcast", ctx do
    card = ai_card(ctx.code, "In flight")
    run = insert(:run, card: card, flow_key: "Code", current_node: "implement")
    in_flight = insert(:node_execution, run: run, node: "implement", attempt: 2, outcome: nil, duration_s: nil)
    unpriced = insert(:node_execution, run: run, node: "spec_review", cost: nil)
    insert(:node_job, node_execution: unpriced, harness_key: "claude")
    insert(:node_execution, run: run, node: "branch", cost: Decimal.new("0.90"))

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert text(view, "#card-drawer-cost-chip") == "≥ $0.90"
    assert has_element?(view, "#card-drawer-cost-chip .card-cost-chip-pulse")
    assert text(view, "#run-cost-total") == "≥ $0.90"
    assert has_element?(view, "#run-cost-so-far")
    assert text(view, "#run-cost-unpriced") == "· 1 unpriced"

    in_flight
    |> Ecto.Changeset.change(
      finished_at: DateTime.add(in_flight.started_at, 60, :second),
      outcome: :succeeded,
      cost: Decimal.new("0.40")
    )
    |> Repo.update!()

    unpriced |> Ecto.Changeset.change(cost: Decimal.new("0.10")) |> Repo.update!()

    run
    |> Ecto.Changeset.change(
      status: :done,
      current_node: nil,
      finished_at: DateTime.truncate(DateTime.utc_now(), :second)
    )
    |> Repo.update!()

    board_id = ctx.board.id
    attach_run_flush_telemetry()
    Runs.broadcast_run_changed(ctx.board.id, card.id)
    assert_receive {:run_flush, %{card_count: 1}, %{board_id: ^board_id}}, 500

    assert text(view, "#run-cost-total") == "$1.40"
    assert text(view, "#card-drawer-cost-chip") == "$1.40"
    refute has_element?(view, "#run-cost-so-far")
    refute has_element?(view, "#run-cost-unpriced")
  end

  test "14: shell and blocked executions with no cost are never unpriced", ctx do
    card = ai_card(ctx.code, "Shell and blocked")
    run = finished_run(card, "Code", :done, ["0.60"], ~U[2026-07-01 10:00:00Z])
    shell = insert(:node_execution, run: run, node: "precommit", cost: nil)
    insert(:node_job, node_execution: shell, harness_key: nil)
    blocked = insert(:node_execution, run: run, node: "implement", outcome: :blocked, cost: nil)
    insert(:node_job, node_execution: blocked, harness_key: "claude")

    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    assert text(view, "#card-drawer-cost-chip") == "$0.60"
    refute text(view, "#card-drawer-cost-chip") =~ "≥"
    refute has_element?(view, "#run-cost-unpriced")
  end

  test "15: a card with nothing priced shows no cost anywhere", ctx do
    card = ai_card(ctx.code, "Never priced")
    finished_run(card, "Spec", :done, [nil], ~U[2026-07-01 10:00:00Z])
    finished_run(card, "Code", :done, [nil, nil], ~U[2026-07-02 10:00:00Z])
    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card))

    view |> element("#card-drawer-tab-detail") |> render_click()
    refute has_element?(view, "#card-drawer-cost-chip")

    view |> element("#card-drawer-tab-run") |> render_click()
    refute has_element?(view, "#card-drawer-cost-chip")
    refute has_element?(view, "#run-cost-total")
    refute has_element?(view, "#run-cost-by-stage")
    assert has_element?(view, "#card-drawer-tab-panel-run", "RUNS · 2")
  end

  test "16: embedded, the chip rides the native nav bar title instead of the header", ctx do
    card = settled_card(ctx)
    view = open(ctx.conn, ctx.board, Cards.ref(ctx.board, card), "&embed=1")

    assert has_element?(view, "#card-drawer-nav-bar #card-drawer-nav-bar-cost-chip")
    assert text(view, "#card-drawer-nav-bar-cost-chip") == "$3.18"
    refute has_element?(view, "#card-drawer-cost-chip")
  end

  # The RLY-204 flush event, forwarded to the test process (as in board_live_run_realtime_test.exs).
  defp attach_run_flush_telemetry do
    handler_id = "test-card-cost-flush-#{System.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach(
      handler_id,
      [:hamaca, :board, :run_flush],
      fn _event, measurements, metadata, _config -> send(test_pid, {:run_flush, measurements, metadata}) end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)
  end
end
