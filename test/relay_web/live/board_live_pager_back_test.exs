defmodule RelayWeb.BoardLivePagerBackTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  # RLY-95 · BOARD-01 (docs/designs/Relay Mobile.dc.html, 2026-07-15 pull): the
  # phone-width pager header row is `‹ back · board name` — the ‹ navigates to
  # /boards?from=<slug> (the only route back once embed hides the top bar), and
  # the header card count RLY-94 shipped is dropped per the updated artboard.

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "the pager header carries a ‹ link to /boards with ?from=<slug>",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, ~s(#board-pager-back[href="/boards?from=#{board.slug}"]))
    assert view |> element("#board-pager-header") |> render() =~ "board-pager-back"
  end

  test "clicking ‹ live-navigates to the boards list, which badges the origin board CURRENT",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    {:ok, boards_view, _html} =
      view
      |> element("#board-pager-back")
      |> render_click()
      |> follow_redirect(conn, ~p"/boards?from=#{board.slug}")

    assert has_element?(boards_view, "#board-card-#{board.slug}-current", "CURRENT")
  end

  test "the header card count is gone (the updated BOARD-01 artboard dropped it)",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    refute has_element?(view, "#board-pager-header .board-pager-count")
  end

  test "the back button renders on the embedded board too — one rule for all phone width",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

    assert has_element?(view, "#board-pager-back")
  end
end
