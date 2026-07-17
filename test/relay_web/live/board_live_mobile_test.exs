defmodule RelayWeb.BoardLiveMobileTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "board at mobile widths (RLY-94 · BOARD-01 pager)" do
    setup :register_and_log_in_user

    test "below 720px the pager CSS owns #board-bands; the desktop scroller returns at >=720px",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      bands = view |> element("#board-bands") |> render()

      # RLY-94 supersedes RLY-62's board-as-document below the drawer breakpoint: the
      # app.css `@media (width < 45rem)` block turns #board-bands into a scroll-snap
      # pager, so the document-flow utility classes are gone.
      refute bands =~ "min-w-full"
      refute bands =~ "w-max"
      refute bands =~ "overflow-x-visible"
      refute bands =~ "overflow-y-visible"

      # At >=720px the desktop app-shell's internal horizontal scroller is intact.
      assert bands =~ "drawer:w-auto"
      assert bands =~ "drawer:min-w-0"
      assert bands =~ "drawer:overflow-x-auto"
      assert bands =~ "drawer:overflow-y-hidden"
      assert bands =~ "drawer:[-webkit-overflow-scrolling:touch]"
      assert bands =~ "drawer:[overscroll-behavior-x:contain]"
    end
  end

  describe "board top bar at narrow widths" do
    setup :register_and_log_in_user

    test "the title truncates and the header actions keep ≥44px tap targets",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      # The bar title truncates instead of pushing actions off-screen on narrow screens.
      assert view |> element("#top-bar-title") |> render() =~ "min-w-0"
      # The plain board-name <span> itself ellipsis-truncates (truncate sits on the span).
      assert view |> element("#board-name") |> render() =~ "truncate"

      # The interactive bar controls are ≥44px tap targets.
      assert view |> element("#board-settings-link") |> render() =~ "min-h-[44px]"
      assert view |> element("#board-settings-link") |> render() =~ "min-w-[44px]"
      assert view |> element("#user-avatar") |> render() =~ "min-h-[44px]"
      assert view |> element("#user-avatar") |> render() =~ "min-w-[44px]"
    end
  end

  describe "board scroll behavior below the mobile breakpoint" do
    setup :register_and_log_in_user

    test "#board-viewport owns a bounded height at every width (RLY-94 supersedes RLY-62's document flow)",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      viewport = view |> element("#board-viewport") |> render()

      # The pager pages scroll internally at every width now (RLY-94), so the viewport is
      # always a bounded, non-document-flow height — no width-conditional `drawer:` variant.
      # 53px == the top bar's exact height (no gap between the bar border and the board panel).
      assert viewport =~ "h-[calc(100dvh_-_53px)]"
      refute viewport =~ "min-h-[calc(100dvh_-_53px)]"
      # The old fixed viewport-height lock (and the static-viewport `vh` unit) is gone.
      refute viewport =~ "100vh"
      refute viewport =~ "height:calc"
    end
  end
end
