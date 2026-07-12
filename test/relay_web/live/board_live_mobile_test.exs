defmodule RelayWeb.BoardLiveMobileTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "board at mobile widths" do
    setup :register_and_log_in_user

    test "the horizontal band container allows momentum touch scrolling",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      style = view |> element("#board-bands") |> render()
      assert style =~ "-webkit-overflow-scrolling:touch"
      assert style =~ "overscroll-behavior-x:contain"
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
      # The editable board-name <input> itself ellipsis-truncates (truncate must sit on the input).
      assert view |> element("#board-name-input") |> render() =~ "truncate"

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
