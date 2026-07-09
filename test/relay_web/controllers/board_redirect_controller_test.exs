defmodule RelayWeb.BoardRedirectControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Boards

  describe "GET /board when logged out" do
    test "redirects logged-out users to the sign-in page", %{conn: conn} do
      conn = get(conn, ~p"/board")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "GET /board when logged in" do
    setup :register_and_log_in_user

    test "redirects to the user's default board slug, seeding one on first visit",
         %{conn: conn, user: user} do
      conn = get(conn, ~p"/board")

      board = Boards.get_or_create_default_board(user)
      assert redirected_to(conn) == ~p"/board/#{board.slug}"
    end

    test "does not create a second board when one already exists", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/board/#{board.slug}"
      assert Relay.Repo.aggregate(Schemas.Board, :count) == 1
    end
  end
end
