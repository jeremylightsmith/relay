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
end
