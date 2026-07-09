defmodule RelayWeb.BoardSlugRoutingTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "when logged out" do
    test "GET /board/:slug redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board/anything")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "renders the board for a slug the user owns", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#board-title", board.name)
    end

    test "a slug the user does not own is a 404", %{conn: conn} do
      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/board/nope-not-mine") end
    end

    test "another user's board slug is a 404", %{conn: conn} do
      other = Relay.Factory.insert(:user)
      other_board = Boards.get_or_create_default_board(other)

      assert_raise Ecto.NoResultsError, fn -> live(conn, ~p"/board/#{other_board.slug}") end
    end

    test "settings loads by slug", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      assert has_element?(view, "#board-settings")
    end

    test "the board header links to the boards home carrying ?from", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert view
             |> element("#all-boards-link")
             |> render() =~ "/boards?from=#{board.slug}"
    end
  end
end
