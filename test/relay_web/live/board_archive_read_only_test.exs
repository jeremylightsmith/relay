defmodule RelayWeb.BoardArchiveReadOnlyTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  describe "archiving from settings" do
    test "Archive removes the board from /boards and lands the user there",
         %{conn: conn, user: user} do
      _default = Boards.get_or_create_default_board(user)
      {:ok, board} = Boards.create_board(user, %{name: "Retire me"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings?section=general")

      assert {:error, {:live_redirect, %{to: "/boards"}}} =
               view |> element("#archive-board-button") |> render_click()

      {:ok, home, _html} = live(conn, ~p"/boards")
      refute has_element?(home, "#board-card-#{board.slug}")
      assert Schemas.Board |> Relay.Repo.get!(board.id) |> Schemas.Board.archived?()
    end
  end

  describe "a read-only archived board" do
    setup %{user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "Archived"})
      {:ok, board} = Boards.archive_board(board)
      %{board: board}
    end

    test "shows the read-only banner and hides the add-work control",
         %{conn: conn, board: board} do
      stage = hd(board.stages)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      assert has_element?(view, "#read-only-banner")

      # Force the stage open (a fresh empty stage otherwise renders as its
      # collapsed strip regardless of read-only) so this asserts the
      # read-only gate itself, not the unrelated empty-stage collapse.
      view |> element("#stage-strip-#{stage.id}") |> render_click()
      refute has_element?(view, "#stage-col-1-new-card")
    end

    test "rejects a mutating event server-side", %{conn: conn, board: board} do
      stage = hd(board.stages)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html =
        render_hook(view, "create_card", %{
          "stage_id" => "#{stage.id}",
          "card" => %{"title" => "sneaky"}
        })

      assert html =~ "archived"
      assert Cards.list_cards(board) == []
    end

    test "Restore re-activates the board and clears read-only",
         %{conn: conn, user: user, board: board} do
      stage = hd(board.stages)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      view |> element("#restore-board-button") |> render_click()

      refute has_element?(view, "#read-only-banner")
      view |> element("#stage-strip-#{stage.id}") |> render_click()
      assert has_element?(view, "#stage-col-1-new-card")
      refute user |> Boards.get_board(board.slug) |> Schemas.Board.archived?()
    end
  end
end
