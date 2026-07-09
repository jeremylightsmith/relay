defmodule RelayWeb.BoardSettingsGeneralTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "General pane" do
    setup :register_and_log_in_user

    test "the rail links to General and its pane shows the Board name field + Save", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert has_element?(view, "#settings-nav-general")
      assert has_element?(view, "#general-pane")
      assert has_element?(view, "#board-name-input")
      assert has_element?(view, "#general-form button", "Save")
    end

    test "the Board name field is pre-filled with the current name", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert view |> element("#board-name-input") |> render() =~ board.name
    end

    test "saving a new name persists it, flashes success, and reflects it in the field", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#general-form", board: %{name: "Launch board"})
        |> render_submit()

      assert html =~ "Board name saved."
      assert Boards.get_or_create_default_board(user).name == "Launch board"
      assert view |> element("#board-name-input") |> render() =~ "Launch board"
    end

    test "saving a blank name shows a validation error and leaves the name unchanged", %{conn: conn, user: user} do
      original = Boards.get_or_create_default_board(user).name

      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#general-form", board: %{name: "   "})
        |> render_submit()

      assert html =~ "should be at least 1 character"
      assert Boards.get_or_create_default_board(user).name == original
    end

    test "renaming never changes the board slug or key", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      view |> form("#general-form", board: %{name: "Renamed"}) |> render_submit()

      updated = Boards.get_or_create_default_board(user)
      assert updated.slug == board.slug
      assert updated.key == board.key
    end
  end
end
