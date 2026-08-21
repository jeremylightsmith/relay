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

  # One card on `board` with a completed "code" run and `execs` executions on `node`.
  # Returns `{card, ref}` — `ref` is what `?from=` carries, so it must come from
  # `Cards.ref/2` rather than a hand-built string.
  defp seed_card_run(board, node, opts \\ []) do
    card = insert(:card, board: board, stage: List.first(board.stages))
    run = insert(:run, card: card, flow_key: "code", status: :done)

    for _ <- 1..Keyword.get(opts, :execs, 1) do
      insert(:node_execution,
        run: run,
        node: node,
        outcome: Keyword.get(opts, :outcome, :succeeded),
        duration_s: 60
      )
    end

    {card, Relay.Cards.ref(board, card)}
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

  test "verdict bar uses the succeeded/needs-input/failed theme tokens", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert html =~ "var(--color-success)"
    assert html =~ "var(--color-warning)"
    assert html =~ "var(--color-error)"
  end

  test "cost is blank and the cost note shows when no cost data exists", %{conn: conn, board: board} do
    seed_runs(board, "implement", 10)
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert has_element?(view, "#stat-total-spend", "—")
    assert has_element?(view, "#cost-blank-note")
  end

  test "version chip, window selector and a shell node's type tag use the field-hover token", %{
    conn: conn,
    board: board
  } do
    seed_runs(board, "branch", 10)
    {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

    assert html =~
             ~r/id="flow-metrics-version-chip"\s*style="[^"]*background:var\(--color-field-hover\)/

    assert html =~
             ~r/id="flow-metrics-window"\s*style="[^"]*background:var\(--color-field-hover\)/

    assert html =~ ~r/id="node-type-branch"[^>]*background:var\(--color-field-hover\)/
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
    {_card, ref} = seed_card_run(board, "implement")

    {:ok, view, html} =
      live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[node: "implement", from: ref]}")

    assert has_element?(view, "#deep-link-banner", ref)
    assert has_element?(view, "#node-here-implement")
    assert html =~ "inset 3px 0 0 var(--color-primary)"
  end

  test "deep-link with an empty node param omits the 'jumped to' clause", %{
    conn: conn,
    board: board
  } do
    seed_runs(board, "implement", 10)
    {_card, ref} = seed_card_run(board, "implement")

    {:ok, view, _html} =
      live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[node: "", from: ref]}")

    assert has_element?(view, "#deep-link-banner", ref)
    refute has_element?(view, "#deep-link-banner", "jumped to")
  end

  describe "per-card scope (RE235)" do
    test "?from= a resolvable ref opens in This-card scope with the toggle selected", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)
      {_card, ref} = seed_card_run(board, "implement")

      {:ok, view, html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      assert has_element?(view, "#flow-metrics-scope")
      assert has_element?(view, "#flow-metrics-scope-flow", "All cards")
      assert has_element?(view, "#flow-metrics-scope-card", "This card")
      # the selected segment carries the artboard picker's raised treatment
      assert html =~ ~r/id="flow-metrics-scope-card"[^>]*box-shadow:0 1px 2px/
      refute html =~ ~r/id="flow-metrics-scope-flow"[^>]*box-shadow:0 1px 2px/
    end

    test "the toggle container reuses the window picker's field-hover treatment", %{
      conn: conn,
      board: board
    } do
      {_card, ref} = seed_card_run(board, "implement")
      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      assert html =~
               ~r/id="flow-metrics-scope"\s*style="[^"]*background:var\(--color-field-hover\)/

      assert html =~ ~r/id="flow-metrics-scope"\s*style="[^"]*border-radius:9px/
    end

    test "no ?from= renders no toggle at all", %{conn: conn, board: board} do
      seed_runs(board, "implement", 10)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

      refute has_element?(view, "#flow-metrics-scope")
      assert has_element?(view, "#flow-metrics-window")
    end

    test "the window picker is hidden in card scope and returns on All cards", %{
      conn: conn,
      board: board
    } do
      {_card, ref} = seed_card_run(board, "implement")
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      refute has_element?(view, "#flow-metrics-window")

      view |> element("#flow-metrics-scope-flow") |> render_click()

      assert_patched(
        view,
        ~p"/board/#{board.slug}/flows/code/metrics?#{[window: "30d", scope: "flow", from: ref]}"
      )

      assert has_element?(view, "#flow-metrics-window")
      assert has_element?(view, "#flow-metrics-scope")
    end

    test "the 10-run gate does not apply in card scope", %{conn: conn, board: board} do
      {_card, ref} = seed_card_run(board, "implement")

      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      # one single execution — nowhere near min_runs_for_percentiles()
      assert has_element?(view, "#flow-metrics-table")
      assert has_element?(view, "#node-row-implement")
      refute has_element?(view, "#flow-metrics-empty")
      refute has_element?(view, "#widen-to-all")
      # the artboard's column grid is untouched
      assert html =~ "grid-template-columns:minmax(220px,1.3fr) 62px 130px 130px 92px 170px 84px"
    end

    test "duration and cost read as single totals under TOTAL headers", %{conn: conn, board: board} do
      # the flow-wide assertion below needs the aggregate table past the 10-run gate — the
      # card-scope one under test bypasses that gate regardless of how many runs exist.
      seed_runs(board, "implement", 10)
      {_card, ref} = seed_card_run(board, "implement", execs: 2)

      {:ok, view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      assert html =~ "DURATION TOTAL"
      assert html =~ "COST TOTAL"
      # 2 executions x 60s, summed, rendered once — not a `x / y` pair
      assert has_element?(view, "#node-row-implement", "2m")
      refute html =~ ~r/DURATION<\/span>/

      # ...and the aggregate view keeps the artboard's headers
      {:ok, _flow_view, flow_html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics")

      assert flow_html =~ ~r/NODE.*RUNS.*DURATION.*COST.*ATTEMPTS.*VERDICT SPLIT.*LOOP-LAPS/s
      refute flow_html =~ "DURATION TOTAL"
    end

    test "the verdict cell reads counts, not percentages, in card scope", %{conn: conn, board: board} do
      {_card, ref} = seed_card_run(board, "implement", execs: 1)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      assert has_element?(view, "#verdict-implement", "1 ok")
      refute has_element?(view, "#verdict-implement", "% ok")
    end

    test "the stat band swaps MEDIAN END-TO-END for the card's END-TO-END total", %{
      conn: conn,
      board: board
    } do
      {_card, ref} = seed_card_run(board, "implement")

      {:ok, _view, html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")
      assert html =~ "END-TO-END"
      refute html =~ "MEDIAN END-TO-END"

      {:ok, _flow_view, flow_html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")
      assert flow_html =~ "MEDIAN END-TO-END"
    end

    test "an unresolvable ?from= degrades to All cards with no toggle and no banner", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)

      {:ok, view, _html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: "ZZ999"]}")

      assert has_element?(view, "#flow-metrics-table")
      refute has_element?(view, "#flow-metrics-scope")
      refute has_element?(view, "#deep-link-banner")
    end

    test "another board's card ref never resolves, even with a matching key", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)
      other_board = insert(:board, key: board.key)
      other_card = insert(:card, board: other_board, stage: insert(:stage, board: other_board))
      other_ref = Relay.Cards.ref(other_board, other_card)

      {:ok, view, _html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: other_ref]}")

      assert has_element?(view, "#flow-metrics-table")
      refute has_element?(view, "#flow-metrics-scope")
    end

    test "an explicit ?scope=card without a resolvable card falls back to flow scope", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)

      {:ok, view, _html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[scope: "card"]}")

      refute has_element?(view, "#flow-metrics-scope")
      assert has_element?(view, "#flow-metrics-window")
      assert has_element?(view, "#flow-metrics-table")
    end

    test "a card with no executions gets the per-card empty state, not Widen to all-time", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)
      quiet = insert(:card, board: board, stage: List.first(board.stages))
      ref = Relay.Cards.ref(board, quiet)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")

      assert has_element?(view, "#flow-metrics-card-empty")
      refute has_element?(view, "#flow-metrics-table")
      refute has_element?(view, "#widen-to-all")

      view |> element("#show-all-cards") |> render_click()

      assert_patched(
        view,
        ~p"/board/#{board.slug}/flows/code/metrics?#{[window: "30d", scope: "flow", from: ref]}"
      )
    end

    test "the footnote links back to the card in card scope only", %{conn: conn, board: board} do
      seed_runs(board, "implement", 10)
      {_card, ref} = seed_card_run(board, "implement")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[from: ref]}")
      assert has_element?(view, ~s|#flow-metrics-footnote a[href="/board/#{board.slug}?card=#{ref}"]|)

      {:ok, flow_view, _html} = live(conn, ~p"/board/#{board.slug}/flows/code/metrics")
      assert has_element?(flow_view, "#flow-metrics-footnote", "Per-card totals live in the card's Run panel.")
      refute has_element?(flow_view, "#flow-metrics-footnote a")
    end

    test "switching window in card scope is impossible but the window survives the round trip", %{
      conn: conn,
      board: board
    } do
      seed_runs(board, "implement", 10)
      {_card, ref} = seed_card_run(board, "implement")

      {:ok, view, _html} =
        live(conn, ~p"/board/#{board.slug}/flows/code/metrics?#{[window: "7d", from: ref]}")

      refute has_element?(view, "#flow-metrics-window")

      view |> element("#flow-metrics-scope-flow") |> render_click()

      assert_patched(
        view,
        ~p"/board/#{board.slug}/flows/code/metrics?#{[window: "7d", scope: "flow", from: ref]}"
      )
    end
  end
end
