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

    # Every card-drawer mutation (title/description/status/owners/comments/
    # review actions) must be rejected server-side too — not just the
    # add-work path — so an archived board can't be mutated by driving the
    # drawer directly, regardless of what's rendered client-side.
    test "rejects every drawer mutation event server-side", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      events = [
        {"save_card_title", %{"card" => %{"title" => "sneaky"}}},
        {"save_card_description", %{"card" => %{"description" => "sneaky"}}},
        {"set_card_status", %{"card" => %{"status" => "in_review"}}},
        {"add_owner", %{"actor_type" => "agent"}},
        {"remove_owner", %{"actor_type" => "agent"}},
        {"post_comment", %{"comment" => %{"body" => "sneaky"}}},
        {"answer_input", %{"answer" => %{"body" => "sneaky"}}},
        {"review_approve", %{}},
        {"review_reject", %{"reject" => %{"note" => "nope"}}},
        {"review_mark_done", %{}},
        {"review_pull", %{}},
        {"send_back", %{"send_back" => %{"note" => "sneaky"}}}
      ]

      for {event, params} <- events do
        html = render_hook(view, event, params)
        assert html =~ "(read-only)", "expected #{event} to be rejected as read-only"
      end
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

  describe "a read-only archived board's settings" do
    setup %{user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "Archived"})
      {:ok, board} = Boards.archive_board(board)
      %{board: board}
    end

    # The Stages pane's mutations must be rejected server-side on an archived
    # board too, not just General's Save — otherwise "read-only" is only
    # skin-deep and stages can still be edited, reordered, or deleted.
    test "rejects every Stages-pane mutation event server-side", %{conn: conn, board: board} do
      stage = hd(board.stages)
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/settings")

      events = [
        {"save_stage", %{"stage_id" => "#{stage.id}", "stage" => %{"name" => "sneaky"}}},
        {"add_stage", %{"category" => "unstarted"}},
        {"delete_stage", %{"stage-id" => "#{stage.id}"}},
        {"toggle_gate", %{"stage-id" => "#{stage.id}"}},
        {"set_owner", %{"stage-id" => "#{stage.id}", "owner" => "ai"}},
        {"toggle_wip", %{"stage-id" => "#{stage.id}"}},
        {"bump_wip", %{"stage-id" => "#{stage.id}", "delta" => "1"}},
        {"reorder_stage", %{"stage-id" => "#{stage.id}", "direction" => "down"}},
        {"set_reject_target", %{"stage_id" => "#{stage.id}", "reject_to_stage_id" => ""}},
        {"toggle_lane", %{"stage-id" => "#{stage.id}", "lane" => "review"}}
      ]

      for {event, params} <- events do
        html = render_hook(view, event, params)
        assert html =~ "(read-only)", "expected #{event} to be rejected as read-only"
      end

      assert Enum.map(Boards.list_stages(board), & &1.name) == Enum.map(board.stages, & &1.name)
    end
  end
end
