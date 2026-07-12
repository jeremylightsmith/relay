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
end
