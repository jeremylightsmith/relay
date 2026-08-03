defmodule RelayWeb.BoardArchiveReadOnlyTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.StoryMap

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
        {"add_owner", %{"actor_type" => "agent"}},
        {"remove_owner", %{"actor_type" => "agent"}},
        {"post_comment", %{"comment" => %{"body" => "sneaky"}}},
        {"answer_input", %{"answer" => %{"body" => "sneaky"}}},
        {"review_approve", %{}},
        {"review_reject", %{"reject" => %{"note" => "nope"}}},
        {"archive_card", %{"ref" => "RLY-1"}},
        {"restore_card", %{"ref" => "RLY-1"}},
        {"toggle_sub_task", %{"id" => "1"}}
      ]

      for {event, params} <- events do
        html = render_hook(view, event, params)
        assert html =~ "(read-only)", "expected #{event} to be rejected as read-only"
      end
    end

    # RE247 — a fresh view (not the shared one above, whose flash is already pinned to
    # this exact sentence by an earlier iteration and would mask a regression here) so a
    # missing `restart_one` guard entry fails this assertion for real.
    test "rejects restart_one as read-only", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html = render_hook(view, "restart_one", %{"ref" => "RLY-1"})

      assert html =~ "(read-only)"
    end

    # RE262 — same reasoning as restart_one above: a fresh view per event, because folding
    # these into the shared "every drawer mutation" list above would let an earlier
    # iteration's "(read-only)" flash persist across render_hook calls and mask a missing
    # assign_card/unassign_card guard entry (verified by temporarily dropping both from the
    # guard clause: appended to the shared list the suite stayed green regardless; in a
    # fresh view it fails as expected).
    test "rejects assign_card as read-only", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html =
        render_hook(view, "assign_card", %{
          "ref" => "RLY-1",
          "column" => "t:1",
          "lane" => "r:1",
          "index" => 0
        })

      assert html =~ "(read-only)"
    end

    test "rejects unassign_card as read-only", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html = render_hook(view, "unassign_card", %{"ref" => "RLY-1"})

      assert html =~ "(read-only)"
    end

    # RE262 — same reasoning as assign_card above: a fresh view per event, so an earlier
    # iteration's "(read-only)" flash can't mask a missing compose_cell/create_card_in_cell
    # guard entry.
    test "rejects compose_cell as read-only", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html = render_hook(view, "compose_cell", %{"column" => "t:1", "lane" => "r:1"})

      assert html =~ "(read-only)"
    end

    test "rejects create_card_in_cell as read-only", %{conn: conn, board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}")

      html =
        render_hook(view, "create_card_in_cell", %{
          "column" => "t:1",
          "lane" => "r:1",
          "card" => %{"title" => "sneaky"}
        })

      assert html =~ "(read-only)"
      assert Cards.list_cards(board) == []
    end

    # RE262 — the server-side guard above rejects compose_cell, but the story map must not
    # render the affordance either: every body cell would otherwise show a dead `＋` whose
    # only outcome is a "(read-only)" flash, the way the board hides its own add-work button.
    test "the story map renders no inline add button", %{conn: conn, board: board} do
      {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard", position: 1})
      {:ok, task} = StoryMap.create_task(activity, %{name: "Sign in", position: 1})
      [release | _rest] = StoryMap.list_releases(board)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/story-map")

      # The grid itself renders — this is the read-only gate, not an empty story map.
      assert has_element?(view, "#story-map-cell-t-#{task.id}-r-#{release.id}")
      refute has_element?(view, "#story-map-add-t-#{task.id}-r-#{release.id}")
      refute has_element?(view, "[id^='story-map-add-']")
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
        {"set_type", %{"stage-id" => "#{stage.id}", "type" => "work"}},
        {"toggle_ai", %{"stage-id" => "#{stage.id}"}},
        {"toggle_wip", %{"stage-id" => "#{stage.id}"}},
        {"bump_wip", %{"stage-id" => "#{stage.id}", "delta" => "1"}},
        {"reorder_stage", %{"stage-id" => "#{stage.id}", "direction" => "down"}},
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
