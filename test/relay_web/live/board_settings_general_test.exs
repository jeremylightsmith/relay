defmodule RelayWeb.BoardSettingsGeneralTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "General pane" do
    setup :register_and_log_in_user

    test "the rail links to General and its pane shows the Board name field", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert has_element?(view, "#settings-nav-general")
      assert has_element?(view, "#general-pane")
      assert has_element?(view, "#board-name-form #board-name-input")
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
        |> form("#board-name-form", board: %{name: "Launch board"})
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
        |> form("#board-name-form", board: %{name: "   "})
        |> render_submit()

      assert html =~ "should be at least 1 character"
      assert Boards.get_or_create_default_board(user).name == original
    end

    test "cancelling a name edit reverts the field without saving", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      view |> element("#board-name-cancel") |> render_click()

      assert view |> element("#board-name-input") |> render() =~ board.name
      assert Boards.get_or_create_default_board(user).name == board.name
    end

    test "renaming never changes the board slug or key", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      view |> form("#board-name-form", board: %{name: "Renamed"}) |> render_submit()

      updated = Boards.get_or_create_default_board(user)
      assert updated.slug == board.slug
      assert updated.key == board.key
    end

    test "the General pane shows the Board URL slug field prefilled with the slug",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert has_element?(view, "#board-slug-input")
      assert view |> element("#board-slug-input") |> render() =~ board.slug
    end

    test "saving a new slug changes the board URL and navigates to it",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> form("#board-slug-form", board: %{slug: "launch-2027"})
               |> render_submit()

      assert to == ~p"/board/launch-2027/settings?section=general"
      assert Boards.get_board(user, "launch-2027")
    end

    test "a taken slug shows an inline error and does not navigate",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, other} = Boards.create_board(user, %{name: "Other"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#board-slug-form", board: %{slug: other.slug})
        |> render_submit()

      assert html =~ "has already been taken"
      assert Boards.get_board(user, board.slug)
    end

    test "an invalid slug format shows an inline error", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#board-slug-form", board: %{slug: "Not Valid!"})
        |> render_submit()

      assert html =~ "must be lowercase letters, numbers, and hyphens"
      assert Boards.get_board(user, board.slug)
    end

    test "cancelling a slug edit reverts the field without saving", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      view |> element("#board-slug-cancel") |> render_click()

      assert view |> element("#board-slug-input") |> render() =~ board.slug
      assert Boards.get_board(user, board.slug)
    end

    test "settings expose no pencil icons or legacy editable-text controls",
         %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=stages")

      refute has_element?(view, ".hero-pencil-square")
      refute has_element?(view, ".editable-text")
    end

    test "the General pane shows the Card key field and the rename warning", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert has_element?(view, "#board-key-form #board-key-input")
      assert view |> element("#board-key-input") |> render() =~ board.key
      assert has_element?(view, "#board-key-warning")
      assert view |> element("#board-key-warning") |> render() =~ "renames every card"
    end

    test "saving a valid Card key persists it and re-renders the field uppercased", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#board-key-form", board: %{key: "ab"})
        |> render_submit()

      assert html =~ "Card key saved."
      assert Boards.get_or_create_default_board(user).key == "AB"
      assert view |> element("#board-key-input") |> render() =~ "AB"
    end

    test "an invalid Card key shows the validation message and does not change the key", %{conn: conn, user: user} do
      original = Boards.get_or_create_default_board(user).key
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      html =
        view
        |> form("#board-key-form", board: %{key: "ABC"})
        |> render_submit()

      assert html =~ "must be exactly 2 letters"
      assert Boards.get_or_create_default_board(user).key == original
    end

    test "cancelling a Card key edit reverts the field without saving", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      view |> element("#board-key-cancel") |> render_click()

      assert view |> element("#board-key-input") |> render() =~ board.key
      assert Boards.get_or_create_default_board(user).key == board.key
    end
  end
end
