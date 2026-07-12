defmodule RelayWeb.BoardsLiveMembersTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  setup :register_and_log_in_user

  test "each tile renders the member avatar stack", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/boards")

    assert has_element?(view, "#board-members-#{board.slug}[data-role=member-stack]")
  end

  test "shows a +N overflow chip when a board has more than four members", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    for i <- 1..5, do: insert(:membership, board: board, email: "extra#{i}@example.com", user: nil)

    {:ok, view, _html} = live(conn, ~p"/boards")

    assert has_element?(
             view,
             "#board-members-#{board.slug} [data-role=member-overflow]",
             "+2"
           )
  end

  test "the member stack and the Updated label share one space-between footer row", %{
    conn: conn,
    user: user
  } do
    board = Boards.get_or_create_default_board(user)
    {:ok, view, _html} = live(conn, ~p"/boards")

    # Mockup "Relay Board.dc.html" line 113: avatars (left) and "Updated ..."
    # (right) sit in a single `justify-content:space-between` footer row, not
    # stacked as independent flex-col children.
    assert has_element?(view, "#board-card-#{board.slug} .justify-between > [data-role=member-stack]")

    assert has_element?(
             view,
             "#board-card-#{board.slug} .justify-between > span",
             "Updated"
           )
  end
end
