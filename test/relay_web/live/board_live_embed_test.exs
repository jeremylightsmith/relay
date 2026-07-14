defmodule RelayWeb.BoardLiveEmbedTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards

  describe "embedded board (?embed=1)" do
    setup :register_and_log_in_user

    test "suppresses the top-bar header while keeping the board content", %{
      conn: conn,
      user: user
    } do
      board = Boards.get_or_create_default_board(user)

      # Dead render: the header is already gone before the socket connects, so
      # there is no header flash under the native AppBar.
      html = conn |> get(~p"/board/#{board.slug}?embed=1") |> html_response(200)
      refute html =~ ~s(id="top-bar")

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      refute has_element?(view, "#top-bar")
      assert has_element?(view, "#board")
    end

    test "reclaims the 53px — the viewport is full-height", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?embed=1")

      viewport = view |> element("#board-viewport") |> render()

      assert viewport =~ "min-h-dvh"
      assert viewport =~ "drawer:h-dvh"
      refute viewport =~ "min-h-[calc(100dvh_-_53px)]"
      refute viewport =~ "drawer:h-[calc(100dvh_-_53px)]"
    end
  end

  describe "non-embedded board (default)" do
    setup :register_and_log_in_user

    test "renders the top-bar header and the 53px-offset viewport", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#top-bar")

      viewport = view |> element("#board-viewport") |> render()

      assert viewport =~ "min-h-[calc(100dvh_-_53px)]"
      assert viewport =~ "drawer:h-[calc(100dvh_-_53px)]"
      refute viewport =~ "min-h-dvh drawer:h-dvh"
    end
  end

  describe "embedded boards list (?embed=1)" do
    setup :register_and_log_in_user

    test "suppresses the top-bar header while keeping the boards grid", %{
      conn: conn,
      user: user
    } do
      _board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards?embed=1")

      refute has_element?(view, "#top-bar")
      assert has_element?(view, "#boards-home")
    end

    test "default (no flag) renders the top-bar header", %{conn: conn, user: user} do
      _board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/boards")

      assert has_element?(view, "#top-bar")
    end
  end
end
