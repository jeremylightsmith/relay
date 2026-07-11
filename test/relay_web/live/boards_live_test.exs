defmodule RelayWeb.BoardsLiveTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Repo
  alias Schemas.Board

  describe "when logged out" do
    test "GET /boards redirects to sign-in", %{conn: conn} do
      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/boards")
    end
  end

  describe "when logged in" do
    setup :register_and_log_in_user

    test "lists the user's active boards as cards", %{conn: conn, user: user} do
      first = Boards.get_or_create_default_board(user)
      {:ok, second} = Boards.create_board(user, %{name: "Launch"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#board-card-#{first.slug}")
      assert has_element?(view, "#board-card-#{second.slug}", "Launch")
    end

    test "does not list another user's boards", %{conn: conn, user: user} do
      _mine = Boards.get_or_create_default_board(user)
      other = Relay.Factory.insert(:user)
      {:ok, theirs} = Boards.create_board(other, %{name: "Theirs"})

      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#board-card-#{theirs.slug}")
    end

    test "badges the board named by ?from=<slug> as CURRENT", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards?from=#{board.slug}")

      assert has_element?(view, "#board-card-#{board.slug}-current", "CURRENT")
    end

    test "New board creates a board and navigates to its settings", %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards")

      assert {:error, {:live_redirect, %{to: to}}} =
               view |> element("#new-board-button") |> render_click()

      assert to =~ ~r{^/board/[a-z0-9-]+/settings$}
      assert Repo.aggregate(Board, :count) == 2
    end

    test "a board tile shows its needs-you count", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      review = Enum.find(board.stages, &(&1.type == :review))
      Relay.Factory.insert(:card, board: board, stage: review, status: :in_review)

      {:ok, view, _html} = live(conn, ~p"/boards")
      assert has_element?(view, "#board-needs-you-#{board.slug}")
    end

    test "no needs-you badge when nothing needs a human", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/boards")
      refute has_element?(view, "#board-needs-you-#{board.slug}")
    end
  end
end
