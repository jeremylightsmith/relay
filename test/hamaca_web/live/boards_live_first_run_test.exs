defmodule HamacaWeb.BoardsLiveFirstRunTest do
  @moduledoc """
  RE470: a signed-in user with zero active boards lands on `/boards` in first-run mode — the New
  board picker forced open ("Make your first board", no ✕ / Cancel / copy card, no way out but
  Create or Sign out), its name and key prefilled from the user's first name, a "No boards yet"
  tile behind it, and a "Create your first board on a computer" screen at phone width.
  """
  use HamacaWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Hamaca.Boards
  alias Hamaca.Repo
  alias HamacaWeb.BoardsLive
  alias Schemas.Board
  alias Schemas.User

  defp first_run_user(conn, attrs \\ []) do
    user = Hamaca.Factory.insert(:user, Keyword.merge([name: "Jeremy Lightsmith"], attrs))
    {log_in_user(conn, user), user}
  end

  defp texts(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end

  defp value(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("value")
    |> List.first()
  end

  defp squish(text), do: text |> String.split() |> Enum.join(" ")

  describe "zero boards" do
    setup %{conn: conn} do
      {conn, user} = first_run_user(conn)
      %{conn: conn, user: user}
    end

    test "1. the picker is forced open as \"Make your first board\" without creating a board", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#template-picker")
      assert texts(view, "#template-picker-title") == ["Make your first board"]
      assert has_element?(view, "#first-run-picker.hidden #template-picker")
      assert Repo.aggregate(Board, :count) == 0
    end

    test "2. no ✕, Cancel or copy card — only a sign-out footer", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      refute has_element?(view, "#template-picker-close")
      refute has_element?(view, "#template-picker-cancel")
      refute has_element?(view, "#template-card-copy")
      assert has_element?(view, "#template-picker-sign-out")

      assert view |> texts("#template-picker") |> hd() |> squish() =~ "Signed in as #{user.email} · Sign out"
    end

    test "3. the name and key are prefilled from the first name", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert value(view, "#template-picker-name") == "Jeremy's board"
      assert value(view, "#template-picker-key") == "JE"
      assert view |> texts("#template-picker-key-preview") |> hd() |> squish() =~ "JE1, JE2, JE3…"
      assert texts(view, "#template-picker-create .pending-idle") == ["Create Jeremy's board"]
    end

    test "5. a forged close_template_picker leaves the picker open", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      render_hook(view, "close_template_picker", %{})

      assert has_element?(view, "#template-picker")
    end

    test "6. New board re-opens with the first-run prefill", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      view
      |> element("#template-picker-form")
      |> render_change(%{"_target" => ["name"], "name" => "Scratch"})

      assert value(view, "#template-picker-name") == "Scratch"

      view |> element("#top-bar-new-board") |> render_click()

      assert has_element?(view, "#template-picker")
      assert value(view, "#template-picker-name") == "Jeremy's board"
    end

    test "7. an empty tile on desktop and a create-on-a-computer screen on phones", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#boards-empty.border-dashed")
      assert texts(view, "#boards-empty > span") == ["No boards yet", "Your first board will show up here."]
      refute has_element?(view, "#new-board-button")

      assert has_element?(view, ~S(#first-run-mobile.drawer\:hidden))
      assert has_element?(view, ~S(#first-run-mobile.max-w-\[420px\]))
      assert texts(view, "#first-run-mobile h2") == ["Create your first board on a computer"]

      assert texts(view, "#first-run-mobile li") == [
               "Sign in with this Google account",
               "Name your board and pick a template",
               "Follow the setup steps on the board"
             ]

      assert view |> texts("#first-run-mobile") |> hd() |> squish() =~ "Signed in as #{user.email}"
    end

    test "8. Create makes the prefilled board and opens it", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert {:error, {:live_redirect, %{to: to}}} =
               view
               |> element("#template-picker-form")
               |> render_submit(%{"template" => "bare-minimum", "name" => "Jeremy's board", "key" => "JE"})

      assert [_, slug] = Regex.run(~r{^/board/([a-z0-9-]+)$}, to)

      board = Repo.get_by!(Board, slug: slug)
      assert board.name == "Jeremy's board"
      assert board.key == "JE"
    end

    test "9. a rejected key keeps the first-run picker open with the inline error", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards")

      html =
        view
        |> element("#template-picker-form")
        |> render_submit(%{"template" => "bare-minimum", "name" => "Jeremy's board", "key" => "J"})

      assert is_binary(html)
      assert Repo.aggregate(Board, :count) == 0
      assert has_element?(view, "#template-picker")
      refute has_element?(view, "#template-picker-cancel")

      [hint] = texts(view, "#template-picker-key-hint")
      assert hint != ""
      refute hint == "2 letters · A–Z"
      assert has_element?(view, "#template-picker-key-hint.text-error")
    end

    test "10. ?template= preselects inside the first-run picker", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/boards?template=design-led")

      assert texts(view, "#template-picker-title") == ["Make your first board"]
      assert has_element?(view, "#template-radio-design-led[checked]")
    end
  end

  test "4. a nameless user's prefill comes from the email local part", %{conn: conn} do
    {conn, _user} = first_run_user(conn, name: nil, email: "ada.lovelace@example.com")
    {:ok, view, _html} = live(conn, ~p"/boards")

    assert value(view, "#template-picker-name") == "ada's board"
    assert value(view, "#template-picker-key") == "AD"
  end

  test "14. a one-letter first name derives its key from the whole prefill", %{conn: conn} do
    {conn, _user} = first_run_user(conn, name: "Q")
    {:ok, view, _html} = live(conn, ~p"/boards")

    assert value(view, "#template-picker-name") == "Q's board"
    assert value(view, "#template-picker-key") == "QS"
  end

  test "11. a user whose only board is archived is in first-run", %{conn: conn} do
    {conn, user} = first_run_user(conn)
    {:ok, board} = Boards.create_board(user, %{name: "Old one", key: "OL", template: "bare-minimum"})
    {:ok, _} = Boards.archive_board(board)

    {:ok, view, _html} = live(conn, ~p"/boards")

    assert texts(view, "#template-picker-title") == ["Make your first board"]
  end

  test "12. a user with a board sees today's /boards and New board picker", %{conn: conn} do
    {conn, user} = first_run_user(conn)
    _board = Boards.get_or_create_default_board(user)

    {:ok, view, _html} = live(conn, ~p"/boards")

    refute has_element?(view, "#template-picker")
    refute has_element?(view, "#boards-empty")
    refute has_element?(view, "#first-run-mobile")
    refute has_element?(view, "#first-run-picker")
    assert has_element?(view, "#new-board-button")

    view |> element("#top-bar-new-board") |> render_click()

    assert texts(view, "#template-picker-title") == ["New board"]
    assert value(view, "#template-picker-name") == ""
    assert has_element?(view, "#template-picker-close")
    assert has_element?(view, "#template-picker-cancel")
    assert has_element?(view, "#template-card-copy")
  end

  describe "first_name/1" do
    test "13. the first word of the name, else the email local part cut at . + or _" do
      assert BoardsLive.first_name(%User{name: "Jeremy Lightsmith"}) == "Jeremy"
      assert BoardsLive.first_name(%User{name: "  Ada  "}) == "Ada"
      assert BoardsLive.first_name(%User{name: nil, email: "jeremy.lightsmith@gmail.com"}) == "jeremy"
      assert BoardsLive.first_name(%User{name: "", email: "a+b@x.io"}) == "a"
      assert BoardsLive.first_name(%User{name: "   ", email: "sam_smith@x.io"}) == "sam"
      assert BoardsLive.first_name(%User{name: nil, email: "q@x.io"}) == "q"
    end
  end
end
