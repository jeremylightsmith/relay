defmodule RelayWeb.BoardRedirectControllerTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Boards
  alias Relay.Repo

  describe "GET /board when logged out" do
    test "redirects logged-out users to the sign-in page", %{conn: conn} do
      conn = get(conn, ~p"/board")
      assert redirected_to(conn) == ~p"/"
    end
  end

  describe "GET /board when logged in" do
    setup :register_and_log_in_user

    test "sends a user with zero boards to the /boards first-run picker without seeding one",
         %{conn: conn} do
      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/boards"
      assert Repo.aggregate(Schemas.Board, :count) == 0
    end

    test "redirects to the user's existing board without creating a second one",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/board/#{board.slug}"
      assert Repo.aggregate(Schemas.Board, :count) == 1
    end

    test "redirects to the first-created of several boards", %{conn: conn, user: user} do
      {:ok, first} = Boards.create_board(user, %{name: "First", slug: unique_slug("first")})
      {:ok, _second} = Boards.create_board(user, %{name: "Second", slug: unique_slug("second")})

      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/board/#{first.slug}"
    end

    test "sends a user whose only board is archived to /boards without creating a board",
         %{conn: conn, user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "Old", slug: unique_slug("old")})
      {:ok, _archived} = Boards.archive_board(board)

      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/boards"
      assert Repo.aggregate(Schemas.Board, :count) == 1
    end

    test "redirects an invited member who owns no board to the board they belong to",
         %{conn: conn, user: user} do
      owner = Relay.Factory.insert(:user)
      board = Boards.get_or_create_default_board(owner)
      Relay.Factory.insert(:membership, board: board, user: user, email: user.email)

      conn = get(conn, ~p"/board")

      assert redirected_to(conn) == ~p"/board/#{board.slug}"
    end
  end
end
