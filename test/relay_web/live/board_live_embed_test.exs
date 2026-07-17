defmodule RelayWeb.BoardLiveEmbedTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

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

      assert viewport =~ "h-dvh"
      refute viewport =~ "min-h-dvh"
      refute viewport =~ "calc(100dvh_-_53px)"
    end
  end

  describe "non-embedded board (default)" do
    setup :register_and_log_in_user

    test "renders the top-bar header and the 53px-offset viewport", %{conn: conn, user: user} do
      board = Boards.get_or_create_default_board(user)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#top-bar")

      viewport = view |> element("#board-viewport") |> render()

      assert viewport =~ "h-[calc(100dvh_-_53px)]"
      refute viewport =~ "min-h-[calc(100dvh_-_53px)]"
      refute viewport =~ "h-dvh"
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

  describe "embedded card drawer (?card=&embed=1)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      review = Enum.find(board.stages, &(&1.name == "Review"))
      {:ok, card} = Cards.create_card(review, %{title: "Review me"})
      {:ok, _card} = Cards.set_status(card, %{status: :in_review})

      %{board: board, ref: Cards.ref(board, card)}
    end

    test "keeps the review context but drops the web actions", %{conn: conn, board: board, ref: ref} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}&embed=1")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      refute has_element?(view, "#review-approve")
      refute has_element?(view, "#review-request-changes")
      refute has_element?(view, "#card-drawer-scrim")
      refute has_element?(view, "#card-drawer-close")
    end

    test "the web board is unchanged — no embed, all actions present", %{
      conn: conn,
      board: board,
      ref: ref
    } do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}?card=#{ref}")
      render_async(view)

      assert has_element?(view, "#review-panel", "READY FOR YOUR REVIEW")
      assert has_element?(view, "#review-approve")
      assert has_element?(view, "#review-request-changes")
      assert has_element?(view, "#card-drawer-scrim")
      assert has_element?(view, "#card-drawer-close")
    end
  end
end
