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
  alias Relay.Repo
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
      # The card leaves the tray list, but the tray itself stays: it is the only drop target
      # that unmaps a card, so it may never vanish (see "the tray is a permanent rail").
      refute has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")
      assert has_element?(view, "#story-map-tray")
      assert has_element?(view, "#story-map-tray-count", "0")
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

  describe "dragging a card" do
    test "assign_card moves a card from one cell to another", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.sso),
        "column" => "t:#{ctx.organize.id}",
        "lane" => "r:#{ctx.later.id}",
        "index" => 0
      })

      target = "#story-map-cell-t-#{ctx.organize.id}-r-#{ctx.later.id}"
      source = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"

      assert has_element?(view, "#{target} ##{card_dom_id(ctx.board, ctx.sso)}")
      refute has_element?(view, "#{source} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "assign_card from the tray places the card and drops the tray count",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-tray-count", "1")

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.dashboards),
        "column" => "t:#{ctx.sign_in.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.dashboards)}")
      assert has_element?(view, "#story-map-tray-count", "0")
    end

    test "assign_card onto a No task yet column sets the activity and leaves the task nil",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.dashboards),
        "column" => "nt:#{ctx.onboard.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      cell = "#story-map-cell-nt-#{ctx.onboard.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.dashboards)}")

      placed = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.dashboards))
      assert placed.story_activity_id == ctx.onboard.id
      assert placed.story_task_id == nil
      assert placed.release_id == ctx.mvp.id
    end

    test "the index the hook sends orders the cell, and never touches the board's order",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, second} =
        StoryMap.assign_card(ctx.dashboards, %{
          story_task_id: ctx.sign_in.id,
          release_id: ctx.mvp.id
        })

      board_positions = fn -> Enum.map([ctx.sso, second], &Repo.get!(Schemas.Card, &1.id).position) end
      before = board_positions.()

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, second),
        "column" => "t:#{ctx.sign_in.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      # Sync with the view before asserting: render_hook returns as soon as handle_event
      # completes, but the write broadcasts {:card_upserted, _} and the view re-renders off
      # that echo. Without waiting for it, the test process (the sandbox connection owner)
      # can exit while the view is still mid-query, logging a spurious Postgrex disconnect.
      cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, second)}")

      assert Repo.get!(Schemas.Card, second.id).story_map_position == 1
      assert Repo.get!(Schemas.Card, ctx.sso.id).story_map_position == 2
      assert board_positions.() == before
    end

    test "unassign_card returns a mapped card to the tray and expands a collapsed tray",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-tray-toggle") |> render_click()
      refute has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")

      render_hook(view, "unassign_card", %{"ref" => Cards.ref(ctx.board, ctx.audit)})

      # The artboard's onTrayDrop sets trayOpen:true — the drop re-expands the rail.
      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.audit)}")
      assert has_element?(view, "#story-map-tray-count", "2")
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.audit)}")

      cleared = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.audit))
      assert cleared.story_map_position == nil
    end

    test "unmapping still works once every card is placed", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      # Place the last unmapped card: the tray list is now empty, which is the steady state
      # this feature drives a board toward. The tray is the ONLY drop target that unmaps,
      # so if it renders away here, unmapping is unreachable through the UI.
      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.dashboards),
        "column" => "t:#{ctx.sign_in.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      assert has_element?(view, "#story-map-tray-count", "0")

      render_hook(view, "unassign_card", %{"ref" => Cards.ref(ctx.board, ctx.audit)})

      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.audit)}")
      assert has_element?(view, "#story-map-tray-count", "1")
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.audit)}")
    end

    test "an undecodable column key and an unknown ref are both silent no-ops",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.sso),
        "column" => "garbage",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      render_hook(view, "assign_card", %{
        "ref" => "NOPE-999",
        "column" => "t:#{ctx.organize.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      render_hook(view, "unassign_card", %{"ref" => "NOPE-999"})

      # The page still renders and the card never moved.
      assert has_element?(view, "#story-map-grid")

      source = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{source} ##{card_dom_id(ctx.board, ctx.sso)}")
    end
  end

  describe "the card count" do
    test "reports the board's card total", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-count", "5 cards")
    end
  end

  describe "RE263 — creating activities" do
    test "clicking ＋ opens the draft; Enter creates at the end and reopens the input empty",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      refute has_element?(view, "#story-map-draft-input")
      view |> element("#story-map-add-activity") |> render_click()
      assert has_element?(view, "#story-map-draft-input")

      submit_draft(view, "Ship work with AI")

      assert_push_event(view, "story_map_draft_cleared", %{})

      assert Enum.map(StoryMap.list_activities(ctx.board), &{&1.name, &1.position}) == [
               {"Onboard & access", 1},
               {"Plan the backlog", 2},
               {"Ship work with AI", 3}
             ]

      shipped = List.last(StoryMap.list_activities(ctx.board))
      assert has_element?(view, "#story-map-activity-#{shipped.id}", "Ship work with AI")
      # Still open and empty, ready for the next sibling.
      assert has_element?(view, "#story-map-draft-input")
      refute render(view) =~ ~s(value="Ship work with AI")
    end

    test "a second Enter appends after the first, so a backbone can be typed", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      submit_draft(view, "Ship work with AI")
      submit_draft(view, "Review & polish")

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Onboard & access",
               "Plan the backlog",
               "Ship work with AI",
               "Review & polish"
             ]
    end

    test "a blank or whitespace-only name creates nothing and leaves the input open",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      submit_draft(view, "   ")

      assert length(StoryMap.list_activities(ctx.board)) == 2
      assert has_element?(view, "#story-map-draft-input")
      refute_push_event(view, "story_map_draft_cleared", %{})
      # "nothing flashes" — `CoreComponents.flash/1` renders the error toast as `#flash-error`.
      refute has_element?(view, "#flash-error")
    end

    test "Escape closes the draft and creates nothing", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      view |> element("#story-map-draft-input") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#story-map-draft-input")
      assert has_element?(view, "#story-map-add-activity")
      assert length(StoryMap.list_activities(ctx.board)) == 2
    end

    # Clicking away cancels — and it MUST be phx-click-away, not phx-blur: in a real browser
    # LiveView blurs this input itself before pushing the submit, so phx-blur cancels the draft
    # the submit is about to commit and Enter creates nothing. render_submit/2 never blurs, so
    # the fast suite cannot see that; it pins the binding here and
    # RelayWeb.Browser.StoryMapCreateTest drives the real keypress.
    test "clicking away closes the draft and creates nothing, and blur is not bound at all",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()

      input = view |> element("#story-map-draft-input") |> render()
      assert input =~ ~s(phx-click-away="story_map_draft_cancel")
      refute input =~ "phx-blur"

      render_click(view, "story_map_draft_cancel", %{})

      refute has_element?(view, "#story-map-draft-input")
      assert length(StoryMap.list_activities(ctx.board)) == 2
    end
  end

  describe "RE263 — the empty panel creates the first activity" do
    setup %{user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "Empty map"})
      %{empty_board: board}
    end

    test "the panel offers Add your first activity, and committing replaces it with the grid",
         %{conn: conn, empty_board: board} do
      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/story-map")

      assert has_element?(view, "#story-map-empty #story-map-empty-add-activity")
      view |> element("#story-map-empty-add-activity") |> render_click()
      assert has_element?(view, "#story-map-empty #story-map-draft-input")

      submit_draft(view, "Onboard & access")

      [activity] = StoryMap.list_activities(board)
      assert activity.name == "Onboard & access"
      assert activity.position == 1
      refute has_element?(view, "#story-map-empty")
      assert has_element?(view, "#story-map-grid #story-map-activity-#{activity.id}")
      # The draft is unchanged — only the render branch flipped, so it is now in the grid's
      # trailing add-activity cell.
      assert has_element?(view, "#story-map-grid #story-map-draft-input")
    end
  end

  describe "RE263 — creating tasks" do
    test "the header ＋ opens a draft column and Enter appends tasks under that activity",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-task-#{ctx.onboard.id}") |> render_click()
      assert has_element?(view, "#story-map-draft-#{ctx.onboard.id} #story-map-draft-input")

      submit_draft(view, "Watch it live")
      submit_draft(view, "Run big changes")

      tasks =
        ctx.board
        |> StoryMap.list_tasks()
        |> Enum.filter(&(&1.story_activity_id == ctx.onboard.id))

      assert Enum.map(tasks, &{&1.name, &1.position}) == [
               {"Sign in", 1},
               {"Watch it live", 2},
               {"Run big changes", 3}
             ]

      for task <- tasks, do: assert(has_element?(view, "#story-map-task-#{task.id}", task.name))
    end

    test "an activity with no tasks shows a clickable ＋ Add task header that opens the draft",
         %{conn: conn} = ctx do
      {:ok, shipped} = StoryMap.create_activity(ctx.board, %{name: "Ship work with AI", position: 3})
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-no-task-#{shipped.id}", "＋ Add task")
      view |> element("#story-map-no-task-#{shipped.id}") |> render_click()

      # The draft column REPLACES the placeholder — never both at once.
      assert has_element?(view, "#story-map-draft-#{shipped.id} #story-map-draft-input")
      refute has_element?(view, "#story-map-no-task-#{shipped.id}")

      submit_draft(view, "Watch it live")

      shipped_tasks =
        ctx.board |> StoryMap.list_tasks() |> Enum.filter(&(&1.story_activity_id == shipped.id))

      assert [%{name: "Watch it live", position: 1}] = shipped_tasks
    end

    test "an activity id this board does not have is ignored", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_click(view, "story_map_add_task", %{"activity-id" => "999999"})

      refute has_element?(view, "#story-map-draft-input")
      assert length(StoryMap.list_tasks(ctx.board)) == 2
    end
  end

  describe "RE263 — creating releases" do
    test "＋ Release appends a fourth swimlane below Later", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-release") |> render_click()
      submit_draft(view, "Someday")

      releases = StoryMap.list_releases(ctx.board)
      assert Enum.map(releases, & &1.name) == ["MVP", "Fast follow", "Later", "Someday"]
      assert List.last(releases).position == 4
      assert has_element?(view, "#story-map-release-#{List.last(releases).id}", "Someday")
    end
  end

  describe "RE263 — an invalid name" do
    test "an over-long name creates nothing, flashes the field, and leaves the draft intact",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      long = String.duplicate("a", 81)
      html = submit_draft(view, long)

      assert length(StoryMap.list_activities(ctx.board)) == 2
      assert html =~ "name should be at most 80 character(s)"
      assert has_element?(view, "#story-map-draft-input")
      assert render(view) =~ ~s(value="#{long}")
    end
  end

  describe "RE263 — realtime and the draft" do
    test "a second tab sees a newly created activity without a reload", %{conn: conn} = ctx do
      {:ok, first, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, second, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      first |> element("#story-map-add-activity") |> render_click()
      submit_draft(first, "Report & share")

      reported = List.last(StoryMap.list_activities(ctx.board))
      assert has_element?(second, "#story-map-activity-#{reported.id}", "Report")
    end

    test "an open draft survives a story_map_changed broadcast from another tab",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      render_change(view, "story_map_draft_change", %{"name" => "Half typed"})

      {:ok, _elsewhere} = StoryMap.create_activity(ctx.board, %{name: "From another tab", position: 9})

      assert has_element?(view, "#story-map-draft-input")
      assert render(view) =~ ~s(value="Half typed")
    end
  end

  describe "RE263 — nothing from RE261 leaked in" do
    test "no delete button, no drag grip, and a name is not an editable field", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      # Scoped to the map itself — the surrounding board chrome is not this card's business.
      refute has_element?(view, "#story-map [draggable]")
      # The map's ONLY text input is the create draft, and none is open here.
      refute has_element?(view, "#story-map input[type=text]")
      refute has_element?(view, "#story-map-grid", "✕")
      refute has_element?(view, "#story-map-grid", "⠿")
      refute render(view) =~ "story_map_rename"
      refute render(view) =~ "story_map_delete"
    end
  end

  describe "RE263 — an archived board cannot create structure" do
    test "the create events are refused with the read-only flash", %{conn: conn} = ctx do
      {:ok, _archived} = Boards.archive_board(ctx.board)
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert render_click(view, "story_map_add_activity", %{}) =~ "archived"
      refute has_element?(view, "#story-map-draft-input")
      assert length(StoryMap.list_activities(ctx.board)) == 2
    end

    test "no create affordance renders at all, matching the board's stage columns",
         %{conn: conn} = ctx do
      # A task-less activity so the `＋ Add task` header branch is on the page too.
      {:ok, shipped} = StoryMap.create_activity(ctx.board, %{name: "Ship work with AI", position: 3})
      {:ok, _archived} = Boards.archive_board(ctx.board)
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-grid")
      refute has_element?(view, "#story-map-add-activity")
      refute has_element?(view, "#story-map-add-release")
      refute has_element?(view, "#story-map-add-task-#{ctx.onboard.id}")

      # The bare header falls through to the plain `— No task yet` label rather than the
      # clickable button, so the column keeps its place in the grid without inviting a click.
      assert has_element?(view, "#story-map-no-task-#{shipped.id}", "— No task yet")
      refute has_element?(view, "#story-map-no-task-#{shipped.id}[phx-click]")
    end

    test "the empty-board panel offers no button either", %{conn: conn, user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "Empty map"})
      {:ok, _archived} = Boards.archive_board(board)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/story-map")

      assert has_element?(view, "#story-map-empty")
      refute has_element?(view, "#story-map-empty-add-activity")
    end
  end

  describe "the inline ＋ add-card" do
    test "creates a real card in the board's intake column, places it, and reopens the composer",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      cell = "#story-map-cell-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"
      add = "#story-map-add-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"
      compose = "#story-map-compose-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"

      assert has_element?(view, add)
      view |> element(add) |> render_click()
      assert has_element?(view, compose)

      view |> form(compose, card: %{title: "Export to CSV"}) |> render_submit()

      created = card_by_title(ctx.board, "Export to CSV")
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, created)}")
      # Q4 — the composer reopens empty in the same cell, so a whole cell can be typed.
      assert has_element?(view, compose)

      assert created.stage_id == Boards.intake_stage(ctx.board).id
      assert created.story_task_id == ctx.organize.id
      assert created.release_id == ctx.mvp.id
    end

    test "a No task yet cell creates the card with an activity and no task", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      cell = "#story-map-cell-nt-#{ctx.onboard.id}-r-#{ctx.mvp.id}"
      add = "#story-map-add-nt-#{ctx.onboard.id}-r-#{ctx.mvp.id}"
      compose = "#story-map-compose-nt-#{ctx.onboard.id}-r-#{ctx.mvp.id}"

      view |> element(add) |> render_click()
      view |> form(compose, card: %{title: "Audit the audit"}) |> render_submit()

      created = card_by_title(ctx.board, "Audit the audit")

      # Sync with the view before asserting on the DB: render_submit returns as soon as
      # handle_event completes, but the write broadcasts {:card_upserted, _} and the view
      # re-renders off that echo. Without waiting for it, the test process (the sandbox
      # connection owner) can exit while the view is still mid-query, logging a spurious
      # Postgrex disconnect.
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, created)}")

      assert created.story_activity_id == ctx.onboard.id
      assert created.story_task_id == nil
      assert created.release_id == ctx.mvp.id
    end

    test "a blank title creates nothing and keeps the composer open", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      before = length(Cards.list_cards(ctx.board))
      compose = "#story-map-compose-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"

      view |> element("#story-map-add-t-#{ctx.organize.id}-r-#{ctx.mvp.id}") |> render_click()
      view |> form(compose, card: %{title: ""}) |> render_submit()

      assert length(Cards.list_cards(ctx.board)) == before
      assert has_element?(view, compose)
    end

    test "cancel closes the composer and brings the ＋ back", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      add = "#story-map-add-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"
      compose = "#story-map-compose-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"

      view |> element(add) |> render_click()
      refute has_element?(view, add)

      view |> element("#{compose}-cancel") |> render_click()
      assert has_element?(view, add)
      refute has_element?(view, compose)
    end

    test "only one cell's composer is open at a time", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      first = "#story-map-compose-t-#{ctx.organize.id}-r-#{ctx.mvp.id}"
      second = "#story-map-compose-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"

      view |> element("#story-map-add-t-#{ctx.organize.id}-r-#{ctx.mvp.id}") |> render_click()
      view |> element("#story-map-add-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}") |> render_click()

      assert has_element?(view, second)
      refute has_element?(view, first)
    end
  end

  # Type into the open draft and press Enter — the phx-change every keystroke fires, then the
  # phx-submit. Both are needed: the change is what lets the server clear the box afterwards.
  defp submit_draft(view, name) do
    render_change(view, "story_map_draft_change", %{"name" => name})
    view |> form("#story-map-draft-input-form", %{"name" => name}) |> render_submit()
  end

  defp card_by_title(board, title) do
    board |> Cards.list_cards() |> Enum.find(&(&1.title == title))
  end

  defp card_dom_id(board, card), do: "story-map-card-#{Cards.ref(board, card)}"
  defp tray_dom_id(board, card), do: "story-map-tray-card-#{Cards.ref(board, card)}"
end
