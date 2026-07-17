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

    test "chips carry counts (main lane + sublanes) and the header shows board name + total",
         %{conn: conn, board: board, spec: spec} do
      {:ok, _card} = Cards.create_card(spec, %{title: "Counted"})
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#stage-chip-#{spec.id} .board-pager-chip-count", "1")

      header = view |> element("#board-pager-header") |> render()
      assert header =~ board.name
      assert header =~ "1 card"
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

    test "pager mode expands every stage into a page (collapse is desktop-only)",
         %{conn: conn, board: board, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # Empty Backlog auto-collapses to its strip on desktop.
      assert has_element?(view, "#stage-strip-#{backlog.id}")

      # The hook reports phone width → every stage renders as a full page.
      view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => true})

      refute has_element?(view, "#stage-strip-#{backlog.id}")
      assert has_element?(view, "#stage-col-1[data-stage-id='#{backlog.id}']")

      # Back at desktop width the auto-collapse returns.
      view |> element("#board-pager-nav") |> render_hook("pager", %{"active" => false})
      assert has_element?(view, "#stage-strip-#{backlog.id}")
    end
  end
end
