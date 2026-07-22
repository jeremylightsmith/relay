defmodule RelayWeb.FlowMetricsLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  # Seed `n` completed runs on the default "code" flow, each with a node execution on `node`.
  # Reuses one of the default board's own (preloaded) stages rather than inserting a new one —
  # a fresh stage's factory-sequenced position can collide with the default board's seeded
  # stage positions and trip `stages_board_id_position_index`.
  defp seed_runs(board, node, n, opts \\ []) do
    outcome = Keyword.get(opts, :outcome, :succeeded)
    stage = List.first(board.stages)

    for _ <- 1..n do
      card = insert(:card, board: board, stage: stage)
      run = insert(:run, card: card, flow_key: "code", status: :done)
      insert(:node_execution, run: run, node: node, outcome: outcome, duration_s: 60)
    end
  end

  test "the Editor tab navigates to Metrics and back", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code")
    assert has_element?(view, "#flow-tab-metrics")

    {:ok, metrics, _html} =
      view |> element("#flow-tab-metrics") |> render_click() |> follow_redirect(conn)

    assert has_element?(metrics, "#flow-metrics-title")
    assert has_element?(metrics, "#flow-tab-editor")
    refute has_element?(metrics, "#flow-graph")
  end

  test "renders the stat band and a per-node table row with type tag once past threshold", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert has_element?(view, "#stat-total-runs")
    assert has_element?(view, "#stat-completed")
    assert has_element?(view, "#stat-total-spend")
    assert has_element?(view, "#stat-median")

    assert has_element?(view, "#flow-metrics-table")
    assert has_element?(view, "#node-row-implement")
    assert has_element?(view, "#node-type-implement", "agent")
    assert has_element?(view, "#verdict-implement")
  end

  test "table header lists the columns in the artboard order", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    # NODE · RUNS · DURATION · COST · ATTEMPTS · VERDICT SPLIT · LOOP-LAPS (Relay Flow Metrics.dc.html:143-149)
    assert html =~ ~r/NODE.*RUNS.*DURATION.*COST.*ATTEMPTS.*VERDICT SPLIT.*LOOP-LAPS/s
  end

  test "verdict bar uses the artboard's three colors", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert html =~ "oklch(0.60 0.13 155)"
    assert html =~ "oklch(0.70 0.13 65)"
    assert html =~ "oklch(0.62 0.16 22)"
  end

  test "cost is blank and the cost note shows when no cost data exists", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert has_element?(view, "#stat-total-spend", "—")
    assert has_element?(view, "#cost-blank-note")
  end

  test "window selector re-queries via URL patch", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    view |> element("#flow-metrics-window-7d") |> render_click()
    assert_patched(view, ~p"/board/#{board.slug}/flows/code/metrics?window=7d")
  end

  test "empty state below threshold, and Widen to all-time switches the window", %{conn: conn, board: board} do
    seed_runs(board, "implement", 3)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert has_element?(view, "#flow-metrics-empty")
    refute has_element?(view, "#flow-metrics-table")

    view |> element("#widen-to-all") |> render_click()
    assert_patched(view, ~p"/board/#{board.slug}/flows/code/metrics?window=all")
  end

  test "deep-link highlights the node row and shows the banner", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)

    {:ok, view, html} =
      live(conn, ~p"/board/#{board.slug}/flows/code/metrics?node=implement&from=RLY-42")

    assert has_element?(view, "#deep-link-banner", "RLY-42")
    assert has_element?(view, "#node-here-implement")
    assert html =~ "inset 3px 0 0 oklch(0.60 0.14 250)"
  end
end
