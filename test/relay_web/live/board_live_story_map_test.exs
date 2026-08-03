defmodule RelayWeb.BoardLiveStoryMapTest do
  @moduledoc """
  RE264 — the story map as a `BoardLive` live_action: the grid, the tray, the empty state, the
  Board ↔ Story map switch, the drawer opening *in place*, and the two realtime paths.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.StoryMap

  setup :register_and_log_in_user

  setup %{user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog | _rest] = board.stages

    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_task(onboard, %{name: "Sign in", position: 1})
    {:ok, organize} = StoryMap.create_task(plan, %{name: "Organize cards", position: 1})
    [mvp, fast_follow, later] = StoryMap.list_releases(board)

    {:ok, sso} = Cards.create_card(backlog, %{title: "Add SSO"})
    {:ok, bulk} = Cards.create_card(backlog, %{title: "Bulk edit"})
    {:ok, audit} = Cards.create_card(backlog, %{title: "Audit auth errors"})
    {:ok, limits} = Cards.create_card(backlog, %{title: "Rate limits"})
    {:ok, dashboards} = Cards.create_card(backlog, %{title: "Shared dashboards"})

    {:ok, sso} = StoryMap.assign_card(sso, %{story_task_id: sign_in.id, release_id: mvp.id})
    {:ok, bulk} = StoryMap.assign_card(bulk, %{story_task_id: organize.id, release_id: fast_follow.id})
    {:ok, audit} = StoryMap.assign_card(audit, %{story_activity_id: onboard.id, release_id: mvp.id})
    {:ok, limits} = StoryMap.assign_card(limits, %{story_task_id: sign_in.id})

    %{
      board: board,
      backlog: backlog,
      onboard: onboard,
      plan: plan,
      sign_in: sign_in,
      organize: organize,
      mvp: mvp,
      later: later,
      sso: sso,
      bulk: bulk,
      audit: audit,
      limits: limits,
      dashboards: dashboards
    }
  end

  describe "the grid" do
    test "renders the activity bands, task headers and lane labels", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-grid")
      # Text filter without the `&` — the band renders it HTML-escaped.
      assert has_element?(view, "#story-map-activity-#{ctx.onboard.id}", "Onboard")
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}", "Plan the backlog")
      assert has_element?(view, "#story-map-task-#{ctx.sign_in.id}", "Sign in")
      assert has_element?(view, "#story-map-task-#{ctx.organize.id}", "Organize cards")

      for release <- StoryMap.list_releases(ctx.board) do
        assert has_element?(view, "#story-map-release-#{release.id}", release.name)
      end
    end

    test "a card renders in the cell its assignment implies", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      sso_cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{sso_cell} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "an activity's task-less card gets a No task yet column, and an activity without one does not",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-no-task-#{ctx.onboard.id}", "— No task yet")
      refute has_element?(view, "#story-map-no-task-#{ctx.plan.id}")

      cell = "#story-map-cell-nt-#{ctx.onboard.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.audit)}")
    end

    test "a mapped card with no release renders in the last lane", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.later.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.limits)}")
      refute has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.limits)}")
    end
  end

  describe "the UNMAPPED tray" do
    test "lists the unmapped cards and collapses and expands", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")
      assert has_element?(view, "#story-map-tray-count", "1")

      view |> element("#story-map-tray-toggle") |> render_click()
      refute has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")
      assert has_element?(view, "#story-map-tray-count", "1")

      view |> element("#story-map-tray-toggle") |> render_click()
      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")
    end
  end

  describe "the empty state" do
    test "a board with no activities renders the panel and still renders the tray",
         %{conn: conn, user: user} do
      # create_board/2 returns the board with its stages preloaded in position order.
      {:ok, board} = Boards.create_board(user, %{name: "Empty map"})
      [stage | _rest] = board.stages
      {:ok, card} = Cards.create_card(stage, %{title: "Nothing placed yet"})

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/story-map")

      assert has_element?(view, "#story-map-empty")
      refute has_element?(view, "#story-map-grid")
      assert has_element?(view, "#story-map-tray ##{tray_dom_id(board, card)}")
    end
  end

  describe "the Board ↔ Story map switch" do
    test "navigates to the map and back", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}")

      assert has_element?(view, "#board-view-tab-board[aria-current='page']")

      {:ok, map_view, _html} =
        view |> element("#board-view-tab-story-map") |> render_click() |> follow_redirect(conn)

      assert has_element?(map_view, "#story-map-grid")
      assert has_element?(map_view, "#board-view-tab-story-map[aria-current='page']")
      refute has_element?(map_view, "#board-view-tab-board[aria-current='page']")
      refute has_element?(map_view, "#board-viewport")

      {:ok, board_view, _html} =
        map_view |> element("#board-view-tab-board") |> render_click() |> follow_redirect(conn)

      assert has_element?(board_view, "#board-viewport")
    end
  end

  describe "the card drawer opens in place" do
    test "clicking a cell card opens the drawer and closing lands back on the map",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("##{card_dom_id(ctx.board, ctx.sso)}") |> render_click()

      assert has_element?(view, "#card-drawer")
      assert_patched(view, "/board/#{ctx.board.slug}/story-map?card=#{Cards.ref(ctx.board, ctx.sso)}")

      view |> element("#card-drawer-close") |> render_click()

      assert_patched(view, "/board/#{ctx.board.slug}/story-map")
      refute has_element?(view, "#card-drawer")
      assert has_element?(view, "#story-map-grid")
    end
  end

  describe "realtime" do
    test "a new activity appears without a reload", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, shipped} = StoryMap.create_activity(ctx.board, %{name: "Ship work with AI", position: 3})

      assert has_element?(view, "#story-map-activity-#{shipped.id}", "Ship work with AI")
    end

    test "assigning a card moves it out of the tray and into its cell, live",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")

      {:ok, _card} =
        StoryMap.assign_card(ctx.dashboards, %{
          story_task_id: ctx.sign_in.id,
          release_id: ctx.mvp.id
        })

      cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.dashboards)}")
      # Nothing is unmapped any more, so the tray disappears entirely (artboard: `trayShown`).
      refute has_element?(view, "#story-map-tray")
    end

    test "an archived card leaves the map", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, _archived} = Cards.archive_card(ctx.sso)

      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "the board view ignores a story_map_changed broadcast", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}")

      Events.broadcast(ctx.board.id, {:story_map_changed, ctx.board.id})

      assert render(view) =~ "board-viewport"
    end
  end

  describe "the card count" do
    test "reports the board's card total", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-count", "5 cards")
    end
  end

  defp card_dom_id(board, card), do: "story-map-card-#{Cards.ref(board, card)}"
  defp tray_dom_id(board, card), do: "story-map-tray-card-#{Cards.ref(board, card)}"
end
