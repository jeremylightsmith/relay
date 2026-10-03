defmodule RelayWeb.BoardLivePagerTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  # RLY-94 · BOARD-01 (docs/designs/Relay Mobile.dc.html lines ~395–443): below the
  # 45rem drawer breakpoint the board is a one-stage-at-a-time scroll-snap pager with
  # a chip strip. The DOM is width-independent (app.css + the BoardPager hook do the
  # restyling), so these tests assert the markup contract the pager CSS and hook key on.

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog, spec | _rest] = board.stages
    %{board: board, backlog: backlog, spec: spec}
  end

  describe "chip strip (BOARD-01)" do
    test "renders one chip per top-level stage, in board order, hidden on desktop",
         %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      nav = view |> element("#board-pager-nav") |> render()
      assert nav =~ "drawer:hidden"

      top_level = Enum.filter(board.stages, &is_nil(&1.parent_id))

      for stage <- top_level do
        assert has_element?(
                 view,
                 "#stage-chip-#{stage.id}[data-chip-stage-id='#{stage.id}']",
                 stage.name
               )
      end

      # Category bands flatten into one ordered chip list (unstarted → planning →
      # in_progress → complete, position-ordered within each category).
      chip_ids =
        ~r/stage-chip-(\d+)/
        |> Regex.scan(nav)
        |> Enum.map(fn [_, id] -> String.to_integer(id) end)
        |> Enum.uniq()

      expected =
        for category <- [:unstarted, :planning, :in_progress, :complete],
            stage <- top_level,
            stage.category == category,
            do: stage.id

      assert chip_ids == expected
    end

    test "chips carry counts (main lane + sublanes) and the header shows the board name",
         %{conn: conn, board: board, spec: spec} do
      {:ok, _card} = Cards.create_card(spec, %{title: "Counted"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-chip-#{spec.id} .board-pager-chip-count", "1")

      header = view |> element("#board-pager-header") |> render()
      assert header =~ board.name
      refute header =~ "1 card"
    end

    test "chip counts update live when a card is created elsewhere",
         %{conn: conn, board: board, spec: spec} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      {:ok, _card} = Cards.create_card(spec, %{title: "Live count"})

      assert has_element?(view, "#stage-chip-#{spec.id} .board-pager-chip-count", "1")
    end

    test "an AI stage's chip is marked for the violet dot treatment",
         %{conn: conn, board: board} do
      ai_stage = Enum.find(board.stages, &(is_nil(&1.parent_id) and &1.ai_enabled))
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-chip-#{ai_stage.id}[data-ai='true'] .board-pager-chip-dot")
    end
  end

  describe "pager markup contract" do
    test "the pager hook and snap-page hooks are wired", %{conn: conn, board: board, spec: spec} do
      {:ok, _card} = Cards.create_card(spec, %{title: "Page me"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # The hook that syncs scroll ↔ chips (and reports pager mode) sits on the nav.
      assert view |> element("#board-pager-nav") |> render() =~ ~s(phx-hook="BoardPager")

      # Category wrappers carry the classes the `@media (width < 45rem)` pager CSS
      # flattens (display: contents) and hides (band headers).
      html = render(view)
      assert html =~ "category-band-header"
      assert html =~ "category-stages"

      # An expanded stage column is addressable by the hook: .stage-column + data-stage-id.
      assert has_element?(view, "#stage-col-2.stage-column[data-stage-id='#{spec.id}']")
    end

    test "pager mode keeps a collapsed stage collapsed, as a compact page (RE377 reverses RLY-94)",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # Empty Backlog auto-collapses to its strip on desktop.
      assert has_element?(view, "#stage-strip-#{backlog.id}")

      # The hook reports phone width → the collapsed stage is a compact snap page.
      view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => true})

      refute has_element?(view, "#stage-strip-#{backlog.id}")

      assert has_element?(
               view,
               "#stage-col-1.stage-column.stage-compact[data-stage-id='#{backlog.id}'][data-collapsed='true']"
             )

      assert has_element?(view, "#stage-col-1-compact-empty", "No cards yet")

      # Back at desktop width the strip returns.
      view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => false})
      assert has_element?(view, "#stage-strip-#{backlog.id}")
      refute has_element?(view, "#stage-col-1.stage-compact")
    end
  end

  describe "collapsed stage in pager mode (RE377)" do
    setup %{board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, code} = Boards.update_stage(code, %{collapsed_by_default: true})
      %{code: code, col: "stage-col-#{code.position}"}
    end

    test "a collapsed stage's cards appear as rows once the pager turns on (empty-page regression)",
         %{conn: conn, board: board, code: code, col: col} do
      {:ok, _} = Cards.create_card(code, %{title: "Not lost"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # Desktop render: strip, so the card stream had no container to land in.
      assert has_element?(view, "#stage-strip-#{code.id}")

      pager_on(view)

      assert has_element?(view, "##{col}-rows .compact-card-row .compact-card-row-title", "Not lost")
      refute has_element?(view, "#stage-strip-#{code.id}")
    end

    test "the compact page has the collapsed badge and Show cards, and no compose +",
         %{conn: conn, board: board, code: code, col: col} do
      {:ok, _} = Cards.create_card(code, %{title: "Held"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pager_on(view)

      assert has_element?(view, "##{col}-collapsed-badge", "collapsed")
      assert has_element?(view, "##{col}-show-cards", "Show cards")
      refute has_element?(view, "##{col}-new-card")
    end

    test "Show cards expands to full faces with Show as list; Show as list folds back to rows",
         %{conn: conn, board: board, code: code, col: col} do
      {:ok, _} = Cards.create_card(code, %{title: "Round trip"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pager_on(view)

      view |> element("##{col}-show-cards") |> render_click()

      assert has_element?(view, "##{col}-cards .board-card .card-title", "Round trip")
      assert has_element?(view, "##{col}-show-as-list", "Show as list")
      refute has_element?(view, "##{col}-collapsed-badge")
      refute has_element?(view, "##{col}.stage-compact")

      view |> element("##{col}-show-as-list") |> render_click()

      # collapse_stage restreams, so the rows are present, not an empty list.
      assert has_element?(view, "##{col}-rows .compact-card-row-title", "Round trip")
      assert has_element?(view, "##{col}-show-cards")
      refute has_element?(view, "##{col}-show-as-list")
    end

    test "phone and desktop share one collapse state",
         %{conn: conn, board: board, code: code, col: col} do
      {:ok, _} = Cards.create_card(code, %{title: "Shared"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pager_on(view)

      view |> element("##{col}-show-cards") |> render_click()
      pager_off(view)

      refute has_element?(view, "#stage-strip-#{code.id}")
      assert has_element?(view, "##{col}-cards .board-card .card-title", "Shared")
      refute has_element?(view, "##{col}-show-as-list")
    end

    test "tapping a row opens the card drawer",
         %{conn: conn, board: board, code: code, col: col} do
      {:ok, card} = Cards.create_card(code, %{title: "Open me"})
      ref = Cards.format_ref(board.key, card.ref_number)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pager_on(view)

      view |> element("##{col}-rows .compact-card-row[data-ref='#{ref}']") |> render_click()

      assert_patch(view, ~p"/board/#{board.slug}?card=#{ref}")
    end

    test "a collapsed Done pages its rows with 'N more'", %{conn: conn, board: board} do
      done = Boards.terminal_stage(board.stages)
      {:ok, _} = Boards.update_stage(done, %{collapsed_by_default: true})
      done_col = "stage-col-#{done.position}"

      for i <- 1..12 do
        insert(:card,
          stage: done,
          title: "Done #{i}",
          updated_at: DateTime.add(~U[2026-07-01 00:00:00Z], i, :second)
        )
      end

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")
      pager_on(view)

      assert length(row_titles(view, "##{done_col}-rows .compact-card-row-title")) == 8
      assert has_element?(view, "##{done_col}-rows-more", "4 more")

      view |> element("##{done_col}-rows-more") |> render_click()

      assert length(row_titles(view, "##{done_col}-rows .compact-card-row-title")) == 12
      refute has_element?(view, "##{done_col}-rows-more")
    end

    test "desktop (pager off) still renders the strip with no rows",
         %{conn: conn, board: board, code: code} do
      {:ok, _} = Cards.create_card(code, %{title: "Desk"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-strip-#{code.id}")
      refute has_element?(view, ".compact-card-row")
    end
  end

  defp pager_on(view), do: view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => true})
  defp pager_off(view), do: view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => false})

  defp row_titles(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
end
