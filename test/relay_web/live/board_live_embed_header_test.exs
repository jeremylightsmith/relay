defmodule RelayWeb.BoardLiveEmbedHeaderTest do
  @moduledoc """
  RE393 · card mockup "Board tab — web large-title header at iOS sizes": embedded
  (`?embed=1`) the Board tab's pager header is an iOS large-title row — the board
  name with a `hero-chevron-down` switcher icon and a 44px circular `+` icon button.
  Plain web keeps its RLY-95 ‹ back and has no `+`, and no `data-embed` hook.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  test "embedded, the board-name switcher carries a hero-chevron-down icon, not a ▾",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

    assert has_element?(view, "#board-switch-board .board-pager-title", board.name)
    assert has_element?(view, "#board-switch-board span.hero-chevron-down")
    refute view |> element("#board-switch-board") |> render() =~ "▾"
  end

  test "embedded, + is a 44px primary circle icon button that keeps its native-bridge data",
       %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

    assert has_element?(view, "#board-create-card.btn.btn-primary.btn-circle.size-11")
    assert has_element?(view, "#board-create-card span.hero-plus")
    assert has_element?(view, ~s(#board-create-card[aria-label="New card"]))

    button = view |> element("#board-create-card") |> render() |> LazyHTML.from_fragment()

    assert LazyHTML.attribute(button, "data-board") == [board.slug]
    # The default board's top-level stages, grouped by category — exactly what it carried before RE393.
    assert LazyHTML.attribute(button, "data-stages") == [
             ~s(["Backlog","Next up","Spec","Plan","Code","Review","Deploy","Done"])
           ]
  end

  test "embedded, the dead render opts the viewport into viewport-fit=cover",
       %{conn: conn, board: board} do
    html = conn |> get(~p"/board/#{board.slug}?embed=1") |> html_response(200)

    assert html =~ ~s(content="width=device-width, initial-scale=1, viewport-fit=cover")
  end

  test "plain web: no data-embed on <main>, the ‹ back stays and there is no +",
       %{conn: conn, board: board} do
    html = conn |> get(~p"/board/#{board.slug}") |> html_response(200)
    refute html =~ "viewport-fit=cover"

    {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

    assert has_element?(view, "main #board-viewport")
    refute has_element?(view, "main[data-embed]")
    assert has_element?(view, "#board-pager-back")
    refute has_element?(view, "#board-create-card")
  end
end
