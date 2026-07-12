defmodule RelayWeb.BoardLiveMobileTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "board at mobile widths" do
    setup :register_and_log_in_user

    test "below 720px the band strip flows in the document; the inner scroller returns at >=720px",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      bands = view |> element("#board-bands") |> render()

      # Below 720px there is NO inner horizontal scroll container: the band strip is
      # document-flow — content-width (w-max) but at least full width (min-w-full) so the
      # gray board canvas covers the whole scrollable width — with visible overflow, so
      # <body> owns the horizontal scroll and iOS pinch-zoom magnifies the real document
      # instead of a composited inner scroller going white.
      assert bands =~ "min-w-full"
      assert bands =~ "w-max"
      assert bands =~ "overflow-x-visible"
      assert bands =~ "overflow-y-visible"

      # The inline inner-scroller declarations that created the composited momentum layer
      # are gone (Tailwind class forms use hyphens, e.g. `overflow-x-auto`, so these
      # colon-form substrings match only the old inline style).
      refute bands =~ "overflow-x:auto"
      refute bands =~ "overflow-y:hidden"

      # At >=720px the desktop app-shell's internal horizontal scroller is restored exactly.
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

    test "#board-viewport uses a dvh-based min-height and drops the fixed 100vh lock",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      viewport = view |> element("#board-viewport") |> render()

      # Below 720px the board is a normal scrolling document: a dvh-based min-height,
      # never a fixed height that would let iOS treat it as a non-scrolling canvas.
      assert viewport =~ "min-h-[calc(100dvh_-_61px)]"
      # The old fixed viewport-height lock (and the static-viewport `vh` unit) is gone.
      refute viewport =~ "100vh"
      refute viewport =~ "height:calc"
    end

    test "at >=720px the board keeps its fixed viewport-height app shell",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      viewport = view |> element("#board-viewport") |> render()

      # The desktop app-shell is preserved: the fixed height is restored at the
      # 720px `drawer:` breakpoint (with min-height reset so it can't linger).
      assert viewport =~ "drawer:h-[calc(100dvh_-_61px)]"
      assert viewport =~ "drawer:min-h-0"
    end
  end
end
