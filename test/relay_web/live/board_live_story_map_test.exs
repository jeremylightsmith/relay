defmodule RelayWeb.BoardLiveStoryMapTest do
  @moduledoc """
  RE264 — the story map as a `BoardLive` live_action: the grid, the tray, the empty state, the
  Board ↔ Story map switch, the drawer opening *in place*, and the two realtime paths.
  """
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Phoenix.Socket.Broadcast
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Relay.Members
  alias Relay.Presence
  alias Relay.Repo
  alias Relay.StoryMap
  alias RelayWeb.StoryMapFilter

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
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-tray-toggle") |> render_click()
      refute has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.dashboards)}")

      render_hook(view, "unassign_card", %{"ref" => Cards.ref(ctx.board, ctx.audit)})

      # The artboard's onTrayDrop sets trayOpen:true — the drop re-expands the rail.
      assert has_element?(view, "#story-map-tray ##{tray_dom_id(ctx.board, ctx.audit)}")
      assert has_element?(view, "#story-map-tray-count", "2")
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.audit)}")

      cleared = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.audit))
      assert cleared.story_map_position == nil

      # RE257 — the tray is a SHARED view setting, so the re-expand goes through put_view/3:
      # it is persisted and every other viewer follows. An optimistic local assign here would
      # leave B collapsed and the row saying false, which is the divergence this pins against.
      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["tray_open"] == true
      assert has_element?(view_b, "#story-map-tray-toggle[aria-expanded='true']")
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

  describe "RE261 — renaming a structure inline" do
    test "clicking an activity name opens the input, and Enter renames it", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      refute has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      assert has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")

      submit_rename(view, "activity", ctx.onboard.id, "Onboarding v2")

      refute has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-activity-#{ctx.onboard.id}", "Onboarding v2")
      assert Repo.get!(Schemas.StoryActivity, ctx.onboard.id).name == "Onboarding v2"
    end

    test "a task and a release rename through the same events", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-task-#{ctx.sign_in.id}") |> render_click()
      submit_rename(view, "task", ctx.sign_in.id, "Sign in with SSO")
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).name == "Sign in with SSO"

      view |> element("#story-map-name-release-#{ctx.mvp.id}") |> render_click()
      submit_rename(view, "release", ctx.mvp.id, "MVP 2")
      assert Repo.get!(Schemas.Release, ctx.mvp.id).name == "MVP 2"
    end

    test "a blank name CANCELS rather than writing", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-task-#{ctx.sign_in.id}") |> render_click()
      submit_rename(view, "task", ctx.sign_in.id, "   ")

      refute has_element?(view, "#story-map-rename-task-#{ctx.sign_in.id}")
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).name == "Sign in"
      refute has_element?(view, "#flash-error")
    end

    test "Escape closes the rename and writes nothing", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-task-#{ctx.sign_in.id}") |> render_click()
      view |> element("#story-map-rename-task-#{ctx.sign_in.id}") |> render_keydown(%{"key" => "Escape"})

      refute has_element?(view, "#story-map-rename-task-#{ctx.sign_in.id}")
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).name == "Sign in"
    end

    test "clicking away cancels, and blur is not bound at all", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      input = view |> element("#story-map-rename-activity-#{ctx.onboard.id}") |> render()
      assert input =~ ~s(phx-click-away="story_map_rename_cancel")
      refute input =~ "phx-blur"

      render_click(view, "story_map_rename_cancel", %{})
      refute has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
    end

    test "an open rename survives a story_map_changed broadcast from another tab",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      render_change(view, "story_map_rename_change", %{"name" => "Half typed"})

      {:ok, _elsewhere} = StoryMap.create_activity(ctx.board, %{name: "From another tab", position: 9})

      assert has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      assert render(view) =~ ~s(value="Half typed")
    end

    test "opening a rename closes an open create draft, and vice versa", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-add-activity") |> render_click()
      assert has_element?(view, "#story-map-draft-input")

      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      refute has_element?(view, "#story-map-draft-input")
      assert has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")

      view |> element("#story-map-add-activity") |> render_click()
      refute has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-draft-input")
    end

    test "only one rename is open anywhere on the page", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      view |> element("#story-map-name-task-#{ctx.sign_in.id}") |> render_click()

      refute has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-rename-task-#{ctx.sign_in.id}")
    end

    test "an over-long name flashes and leaves the rename open", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-name-activity-#{ctx.onboard.id}") |> render_click()
      submit_rename(view, "activity", ctx.onboard.id, String.duplicate("a", 81))

      assert has_element?(view, "#flash-error")
      assert has_element?(view, "#story-map-rename-activity-#{ctx.onboard.id}")
      assert Repo.get!(Schemas.StoryActivity, ctx.onboard.id).name == "Onboard & access"
    end

    test "a forged kind or id is a silent no-op", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      other_board = insert(:board)
      foreign = insert(:story_activity, board: other_board, name: "Elsewhere")

      render_click(view, "story_map_rename_start", %{"kind" => "activity", "id" => to_string(foreign.id)})
      render_click(view, "story_map_rename_start", %{"kind" => "nonsense", "id" => "1"})

      assert has_element?(view, "#story-map-grid")
      refute has_element?(view, "#story-map input[type=text]")
      assert Repo.get!(Schemas.StoryActivity, foreign.id).name == "Elsewhere"
    end
  end

  describe "RE261 — deleting a structure" do
    test "an activity that still holds cards renders a disabled ✕ with the blocking tooltip",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      button = "#story-map-delete-activity-#{ctx.onboard.id}"
      assert has_element?(view, "#{button}[disabled]")

      html = view |> element(button) |> render()
      assert html =~ "Move 3 cards out of this activity before deleting it"
      # The artboard's `delOff` (line ~398), not the enabled `delStyle`.
      assert html =~ "color:oklch(0.82 0.01 255);cursor:not-allowed;"

      render_click(view, "story_map_delete", %{"kind" => "activity", "id" => to_string(ctx.onboard.id)})

      assert Repo.get(Schemas.StoryActivity, ctx.onboard.id)
      assert has_element?(view, "#flash-error")
    end

    test "the tooltip says card, singular, at one", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      html = view |> element("#story-map-delete-task-#{ctx.organize.id}") |> render()
      assert html =~ "Move 1 card out of this task before deleting it"
    end

    test "an empty task's ✕ is enabled, deletes the column, and never loses a card",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      # Empty "Organize cards" by dragging its one card into the neighbouring task column.
      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.bulk),
        "column" => "t:#{ctx.sign_in.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      button = "#story-map-delete-task-#{ctx.organize.id}"
      refute has_element?(view, "#{button}[disabled]")
      assert view |> element(button) |> render() =~ "Delete task"
      # The artboard's enabled `delStyle` (line ~397).
      assert view |> element(button) |> render() =~ "color:oklch(0.62 0.03 25);"

      view |> element(button) |> render_click()

      assert Repo.get(Schemas.StoryTask, ctx.organize.id) == nil
      refute has_element?(view, "#story-map-task-#{ctx.organize.id}")
      # The card that moved out is still on the board, in the column it was dropped into.
      assert has_element?(
               view,
               "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id} ##{card_dom_id(ctx.board, ctx.bulk)}"
             )
    end

    test "the last remaining release renders no ✕ at all", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      [mvp, fast_follow, later] = StoryMap.list_releases(ctx.board)
      assert has_element?(view, "#story-map-delete-release-#{mvp.id}")

      # `bulk` sits in Fast follow, and a swimlane holding a card cannot be deleted — empty it
      # first (this is exactly the acceptance criterion's "emptying each one first").
      {:ok, _} = StoryMap.assign_card(ctx.bulk, %{story_task_id: ctx.organize.id})
      {:ok, _} = StoryMap.delete_release(fast_follow)
      {:ok, _} = StoryMap.delete_release(later)
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-release-#{mvp.id}")
      refute has_element?(view, "#story-map-delete-release-#{mvp.id}")
    end

    test "the synthetic (No release) lane carries no grip, rename or ✕", %{conn: conn, user: user} do
      {:ok, board} = Boards.create_board(user, %{name: "No releases"})
      {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard", position: 1})
      for release <- StoryMap.list_releases(board), do: {:ok, _} = StoryMap.delete_release(release)

      {:ok, view, _html} = live(conn, ~p"/board/#{board.slug}/story-map")

      assert has_element?(view, "#story-map-activity-#{activity.id}")
      assert has_element?(view, "#story-map-release-none")
      refute has_element?(view, "#story-map-release-none [phx-click='story_map_rename_start']")
      refute render(view) =~ "story-map-delete-release-"
    end

    test "a forged delete for another board's structure is a silent no-op",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      foreign = insert(:story_activity, board: insert(:board))
      render_click(view, "story_map_delete", %{"kind" => "activity", "id" => to_string(foreign.id)})

      assert Repo.get(Schemas.StoryActivity, foreign.id)
      assert has_element?(view, "#story-map-grid")
    end
  end

  describe "RE261 — an archived board shows no editing affordances" do
    setup ctx do
      {:ok, _archived} = Boards.archive_board(ctx.board)
      :ok
    end

    test "no grips, no ✕ and no clickable names render", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-grid")
      refute has_element?(view, "#story-map-grid", "⠿")
      refute render(view) =~ "story-map-delete-"
      refute render(view) =~ "story_map_rename_start"
      # The names are still THERE, just not clickable.
      assert has_element?(view, "#story-map-name-activity-#{ctx.onboard.id}", "Onboard & access")
      refute has_element?(view, "#story-map-name-activity-#{ctx.onboard.id}[phx-click]")
    end

    test "the rename and delete events are refused with the read-only flash",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert render_click(view, "story_map_rename_start", %{
               "kind" => "activity",
               "id" => to_string(ctx.onboard.id)
             }) =~ "archived"

      assert render_click(view, "story_map_delete", %{
               "kind" => "task",
               "id" => to_string(ctx.organize.id)
             }) =~ "archived"

      assert Repo.get(Schemas.StoryTask, ctx.organize.id)
    end
  end

  describe "RE261 — dragging a header to reorder" do
    test "activity onto activity reorders the backbone", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      reorder(view, "activity", ctx.plan.id, "activity", ctx.onboard.id)

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Plan the backlog",
               "Onboard & access"
             ]
    end

    test "activity onto a TASK header targets that task's activity", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      reorder(view, "activity", ctx.plan.id, "task", ctx.sign_in.id)

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Plan the backlog",
               "Onboard & access"
             ]
    end

    test "task onto a task in another activity moves it there, at the target's index, with its cards",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      reorder(view, "task", ctx.sign_in.id, "task", ctx.organize.id)

      moved = Repo.get!(Schemas.StoryTask, ctx.sign_in.id)
      assert moved.story_activity_id == ctx.plan.id
      assert moved.position == 1
      assert Repo.get!(Schemas.StoryTask, ctx.organize.id).position == 2

      # The cards came with it — and none landed in the tray.
      assert Repo.get!(Schemas.Card, ctx.sso.id).story_activity_id == ctx.plan.id
      assert Repo.get!(Schemas.Card, ctx.limits.id).story_activity_id == ctx.plan.id
      assert has_element?(view, "#story-map-tray-count", "1")
    end

    test "task onto an ACTIVITY header appends it last in that activity", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      reorder(view, "task", ctx.sign_in.id, "activity", ctx.plan.id)

      moved = Repo.get!(Schemas.StoryTask, ctx.sign_in.id)
      assert moved.story_activity_id == ctx.plan.id
      assert moved.position == 2
      assert Repo.get!(Schemas.StoryTask, ctx.organize.id).position == 1
    end

    test "task onto a task in its OWN activity is a pure renumber", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, second} = StoryMap.create_task(ctx.onboard, %{name: "Reset password", position: 2})
      # Force the {:story_map_changed, _} refresh to land before the drop, so @story_tasks
      # actually holds the new column when the server computes the order.
      assert has_element?(view, "#story-map-task-#{second.id}")

      reorder(view, "task", second.id, "task", ctx.sign_in.id)

      assert Repo.get!(Schemas.StoryTask, second.id).position == 1
      assert Repo.get!(Schemas.StoryTask, second.id).story_activity_id == ctx.onboard.id
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).position == 2
    end

    # Unlike an activity dropped on itself (below), the artboard's moveTask/4 does NOT no-op a
    # task self-drop: it always pushes the dragged task to the end of `targetAct`'s order. With
    # a second task already after it, sign_in visibly moves — this pins that behavior rather
    # than relying on it happening to fall out of the general "task onto task" clause.
    test "dropping a task on itself moves it to the end of its own activity", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, second} = StoryMap.create_task(ctx.onboard, %{name: "Reset password", position: 2})
      assert has_element?(view, "#story-map-task-#{second.id}")

      reorder(view, "task", ctx.sign_in.id, "task", ctx.sign_in.id)

      assert Repo.get!(Schemas.StoryTask, second.id).position == 1
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).position == 2
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).story_activity_id == ctx.onboard.id
    end

    test "release onto release reorders the swimlanes", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      [mvp, _fast_follow, later] = StoryMap.list_releases(ctx.board)
      reorder(view, "release", later.id, "release", mvp.id)

      assert Enum.map(StoryMap.list_releases(ctx.board), & &1.name) == [
               "Later",
               "MVP",
               "Fast follow"
             ]
    end

    test "a release dropped on the backbone, and a backbone header dropped on a release, do nothing",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      before_activities = Enum.map(StoryMap.list_activities(ctx.board), & &1.id)
      before_releases = Enum.map(StoryMap.list_releases(ctx.board), & &1.id)

      reorder(view, "release", ctx.mvp.id, "activity", ctx.onboard.id)
      reorder(view, "activity", ctx.onboard.id, "release", ctx.mvp.id)
      reorder(view, "task", ctx.sign_in.id, "release", ctx.mvp.id)

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.id) == before_activities
      assert Enum.map(StoryMap.list_releases(ctx.board), & &1.id) == before_releases
      assert Repo.get!(Schemas.StoryTask, ctx.sign_in.id).story_activity_id == ctx.onboard.id
    end

    test "dropping a header on itself changes nothing", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      reorder(view, "activity", ctx.onboard.id, "activity", ctx.onboard.id)

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Onboard & access",
               "Plan the backlog"
             ]
    end

    test "a forged id on either end is a silent no-op", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      foreign = insert(:story_activity, board: insert(:board))
      reorder(view, "activity", foreign.id, "activity", ctx.onboard.id)
      reorder(view, "activity", ctx.onboard.id, "activity", foreign.id)
      reorder(view, "nonsense", ctx.onboard.id, "activity", ctx.plan.id)

      assert has_element?(view, "#story-map-grid")

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Onboard & access",
               "Plan the backlog"
             ]
    end

    test "the headers carry the drag contract the hook reads", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      band = view |> element("#story-map-activity-#{ctx.onboard.id}") |> render()
      assert band =~ ~s(data-kind="activity")
      assert band =~ ~s(data-id="#{ctx.onboard.id}")
      assert band =~ "story-map-header-drop"
      assert band =~ ~s(draggable="true")

      column = view |> element("#story-map-task-#{ctx.sign_in.id}") |> render()
      assert column =~ ~s(data-kind="task")
      assert column =~ "story-map-header-drop"

      lane = view |> element("#story-map-release-#{ctx.mvp.id}") |> render()
      assert lane =~ ~s(data-kind="release")
      assert lane =~ "story-map-header-drop"
    end

    test "an archived board refuses the reorder event and drops the drag contract",
         %{conn: conn} = ctx do
      {:ok, _archived} = Boards.archive_board(ctx.board)
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      refute render(view) =~ "story-map-header-drop"
      assert view |> element("#story-map-activity-#{ctx.onboard.id}") |> render() =~ ~s(draggable="false")

      assert render_hook(view, "story_map_reorder", %{
               "kind" => "activity",
               "id" => to_string(ctx.plan.id),
               "target_kind" => "activity",
               "target_id" => to_string(ctx.onboard.id)
             }) =~ "archived"

      assert Enum.map(StoryMap.list_activities(ctx.board), & &1.name) == [
               "Onboard & access",
               "Plan the backlog"
             ]
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

  describe "RE260 — zoom" do
    test "a fresh mount opens at Compact, with no ref, badge or bar on a card",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert attr_of(view, "#story-map-zoom-compact", "aria-pressed") == "true"
      assert attr_of(view, "#story-map-zoom-map", "aria-pressed") == "false"
      assert attr_of(view, "#story-map-zoom-full", "aria-pressed") == "false"

      face = card_face_html(view, ctx.board, ctx.sso)
      assert face =~ "border-radius:6px;"
      refute face =~ "BACKLOG"
    end

    test "clicking Full re-renders every face with its ref, badge and 9px box",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-zoom-full") |> render_click()

      face = card_face_html(view, ctx.board, ctx.sso)
      assert face =~ "border-radius:9px;"
      assert face =~ "BACKLOG"
      assert attr_of(view, "#story-map-zoom-full", "aria-pressed") == "true"
    end

    test "clicking Map renders title lines and hides every cell's ＋", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-add-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}")

      view |> element("#story-map-zoom-map") |> render_click()

      face = card_face_html(view, ctx.board, ctx.sso)
      assert face =~ "border-left:2px solid"
      refute face =~ "border-radius"
      refute face =~ "BACKLOG"

      refute has_element?(view, "#story-map-add-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}")
    end

    test "a card stays draggable and clickable at Map zoom", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-zoom-map") |> render_click()

      ref = Cards.ref(ctx.board, ctx.sso)
      assert has_element?(view, ".story-map-card[data-ref='#{ref}'][draggable='true']")

      # And the drop the hook would send still lands.
      render_hook(view, "assign_card", %{
        "ref" => ref,
        "column" => "t:#{ctx.organize.id}",
        "lane" => "r:#{ctx.later.id}",
        "index" => 0
      })

      cell = "#story-map-cell-t-#{ctx.organize.id}-r-#{ctx.later.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "an unknown zoom off the wire is a silent no-op", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_click(view, "set_story_map_zoom", %{"zoom" => "gigantic"})

      assert attr_of(view, "#story-map-zoom-compact", "aria-pressed") == "true"
      assert card_face_html(view, ctx.board, ctx.sso) =~ "border-radius:6px;"
    end

    test "the toolbar is absent on the board view", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}")

      refute has_element?(view, "#story-map-toolbar")
    end
  end

  describe "RE260 — Hide tasks" do
    test "merges each activity into one column and flips the button's label",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-task-#{ctx.sign_in.id}")

      view |> element("#story-map-hide-tasks") |> render_click()

      assert has_element?(view, "#story-map-merged-#{ctx.onboard.id}", "1 tasks · merged")
      assert has_element?(view, "#story-map-merged-#{ctx.plan.id}", "1 tasks · merged")
      refute has_element?(view, "#story-map-task-#{ctx.sign_in.id}")
      refute has_element?(view, "#story-map-no-task-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-hide-tasks", "Show tasks")

      # The tasked card and the task-less card share the activity's one cell.
      cell = "#story-map-cell-m-#{ctx.onboard.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.sso)}")
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.audit)}")
    end

    test "clicking again shows the tasks", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-hide-tasks") |> render_click()
      view |> element("#story-map-hide-tasks") |> render_click()

      assert has_element?(view, "#story-map-task-#{ctx.sign_in.id}")
      assert has_element?(view, "#story-map-hide-tasks", "Hide tasks")
    end

    test "opening a task draft turns Hide tasks off — there is nowhere to render a new column",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-hide-tasks") |> render_click()
      view |> element("#story-map-add-task-#{ctx.onboard.id}") |> render_click()

      assert has_element?(view, "#story-map-hide-tasks", "Hide tasks")
      assert has_element?(view, "#story-map-task-#{ctx.sign_in.id}")
      assert has_element?(view, "#story-map-draft-#{ctx.onboard.id}")
    end

    # RE257 inverted this: zoom and Hide tasks used to be per-socket assigns that reset on
    # reload. They are shared view settings now — both drive grid geometry, and raw-pixel
    # cursors only land on the right card while every viewer's geometry agrees — so a reload
    # (and a post-deploy reconnect) must come back on the view the board is on.
    test "zoom and Hide tasks SURVIVE a reload, because they are shared", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-zoom-map") |> render_click()
      view |> element("#story-map-hide-tasks") |> render_click()

      {:ok, reloaded, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert attr_of(reloaded, "#story-map-zoom-map", "aria-pressed") == "true"
      assert has_element?(reloaded, "#story-map-hide-tasks", "Show tasks")
    end

    # RE257 — opening a task draft turns Hide tasks off through put_view/3, not a local assign,
    # so it can never become a second writer that leaves other viewers merged.
    test "opening a task draft shows tasks for EVERY viewer, not just the drafter",
         %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      view_a |> element("#story-map-hide-tasks") |> render_click()
      refute has_element?(view_b, "#story-map-task-#{ctx.sign_in.id}")

      view_a |> element("#story-map-add-task-#{ctx.onboard.id}") |> render_click()

      assert has_element?(view_b, "#story-map-task-#{ctx.sign_in.id}")
      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["hide_tasks"] == false
    end
  end

  describe "RE260 — a merged drop keeps the card's task" do
    test "within one activity it changes only the release", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-hide-tasks") |> render_click()

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.sso),
        "column" => "m:#{ctx.onboard.id}",
        "lane" => "r:#{ctx.later.id}",
        "index" => 0
      })

      moved = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.sso))
      assert moved.story_task_id == ctx.sign_in.id
      assert moved.story_activity_id == ctx.onboard.id
      assert moved.release_id == ctx.later.id

      # And with tasks shown again it is still in its task's column, one lane down.
      view |> element("#story-map-hide-tasks") |> render_click()
      cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.later.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "across activities it clears the task, which belonged to the old activity",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-hide-tasks") |> render_click()

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.sso),
        "column" => "m:#{ctx.plan.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      moved = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.sso))
      assert moved.story_task_id == nil
      assert moved.story_activity_id == ctx.plan.id
      assert moved.release_id == ctx.mvp.id

      view |> element("#story-map-hide-tasks") |> render_click()
      cell = "#story-map-cell-nt-#{ctx.plan.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{cell} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "a card with no task still has none after a merged drop", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-hide-tasks") |> render_click()

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.audit),
        "column" => "m:#{ctx.onboard.id}",
        "lane" => "r:#{ctx.later.id}",
        "index" => 0
      })

      moved = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.audit))
      assert moved.story_task_id == nil
      assert moved.story_activity_id == ctx.onboard.id
      assert moved.release_id == ctx.later.id
    end

    test "a No task yet drop still CLEARS the task — that is the point of that column",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view, "assign_card", %{
        "ref" => Cards.ref(ctx.board, ctx.sso),
        "column" => "nt:#{ctx.onboard.id}",
        "lane" => "r:#{ctx.mvp.id}",
        "index" => 0
      })

      moved = Cards.get_card_by_ref(ctx.board, Cards.ref(ctx.board, ctx.sso))
      assert moved.story_task_id == nil
      assert moved.story_activity_id == ctx.onboard.id
    end
  end

  # Type into the open draft and press Enter — the phx-change every keystroke fires, then the
  # phx-submit. Both are needed: the change is what lets the server clear the box afterwards.
  defp submit_draft(view, name) do
    render_change(view, "story_map_draft_change", %{"name" => name})
    view |> form("#story-map-draft-input-form", %{"name" => name}) |> render_submit()
  end

  # Type into the open rename and press Enter — the phx-change every keystroke fires, then the
  # phx-submit, exactly like submit_draft/2.
  defp submit_rename(view, kind, id, name) do
    render_change(view, "story_map_rename_change", %{"name" => name})

    view
    |> form("#story-map-rename-#{kind}-#{id}-form", %{"name" => name})
    |> render_submit()
  end

  # Exactly what assets/js/hooks/story_map_dnd.js pushes on a header drop: ids only, as strings.
  defp reorder(view, kind, id, target_kind, target_id) do
    render_hook(view, "story_map_reorder", %{
      "kind" => kind,
      "id" => to_string(id),
      "target_kind" => target_kind,
      "target_id" => to_string(target_id)
    })
  end

  defp card_by_title(board, title) do
    board |> Cards.list_cards() |> Enum.find(&(&1.title == title))
  end

  defp attr_of(view, selector, attribute) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  defp card_face_html(view, board, card) do
    view |> element("##{card_dom_id(board, card)}") |> render()
  end

  defp card_dom_id(board, card), do: "story-map-card-#{Cards.ref(board, card)}"
  defp tray_dom_id(board, card), do: "story-map-tray-card-#{Cards.ref(board, card)}"

  # RE257 — a second signed-in member of the same board, and their own connection. `insert/2`
  # and `build_conn/0` come from ConnCase's `import Relay.Factory` / `import Phoenix.ConnTest`.
  defp second_member(board) do
    other = insert(:user, name: "Mara Lopez", avatar_url: nil)
    {:ok, _membership} = Members.invite(board, other.email)

    {other, log_in_user(build_conn(), other)}
  end

  # The presence roster is re-derived from Relay.Presence, never patched from the diff payload,
  # so a synthetic diff exercises exactly the shipped code path — deterministically. The REAL
  # diff is asynchronous (Phoenix computes it in a Task), and that it genuinely arrives is
  # pinned by Relay.PresenceTest rather than raced here.
  defp presence_diff(board, leaves \\ %{}) do
    %Broadcast{
      topic: Presence.presence_topic(board.id),
      event: "presence_diff",
      payload: %{joins: %{}, leaves: leaves}
    }
  end

  defp deliver_presence_diff(view, board) do
    send(view.pid, presence_diff(board))
    render(view)
  end

  describe "live presence — the avatar stack (RE257)" do
    test "alone on the map, no stack renders", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-count")
      refute has_element?(view, "#story-map-presence")
    end

    test "a second viewer puts two faces in the stack, yours first", %{conn: conn} = ctx do
      {other, other_conn} = second_member(ctx.board)
      {:ok, _view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      # Mounting AFTER the other viewer is tracked reads the roster straight out of the
      # tracker — no async diff to wait on.
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view_a, "#story-map-presence")
      html = render(view_a)
      assert html =~ "(you)"
      assert html =~ other.name
      assert :binary.match(html, "(you)") < :binary.match(html, other.name)
    end

    test "a viewer who joins while you watch appears without a reload", %{conn: conn} = ctx do
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      refute has_element?(view_a, "#story-map-presence")

      {other, other_conn} = second_member(ctx.board)
      {:ok, _view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      html = deliver_presence_diff(view_a, ctx.board)

      assert html =~ ~s(id="story-map-presence")
      assert html =~ other.name
    end

    test "the kanban board renders no stack and tracks nobody", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, _view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}")

      refute has_element?(view_a, "#story-map-presence")
      # Only the story-map viewer is counted.
      assert [%{user_id: _}] = Presence.list_people(ctx.board.id)
    end

    test "navigating off the map stops counting you", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      :ok = Presence.subscribe(ctx.board.id)
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")
      assert_receive %Broadcast{event: "presence_diff", payload: %{joins: joins}}, 1000
      assert map_size(joins) == 1

      assert {:error, {:live_redirect, %{to: to}}} =
               view_b |> element("#board-view-tab-board") |> render_click()

      assert to == "/board/#{ctx.board.slug}"
      assert_receive %Broadcast{event: "presence_diff", payload: %{leaves: leaves}}, 1000
      assert map_size(leaves) == 1
      assert Presence.list_people(ctx.board.id) == []

      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      refute has_element?(view_a, "#story-map-presence")
    end
  end

  describe "shared map view settings (RE257)" do
    test "a tray toggle in one session moves the tray in another", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view_b, "#story-map-tray-toggle[aria-expanded='true']")

      render_click(view_a, "toggle_story_map_tray")

      # Local PubSub dispatch happens synchronously in the writer's process, so B's mailbox
      # already holds the broadcast by the time render_click/2 returns.
      assert has_element?(view_b, "#story-map-tray-toggle[aria-expanded='false']")
      # The clicker re-renders from the SAME broadcast — one path, no optimistic assign.
      assert has_element?(view_a, "#story-map-tray-toggle[aria-expanded='false']")
      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["tray_open"] == false
    end

    test "a late joiner opens on the view everyone else is already on", %{conn: conn} = ctx do
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      render_click(view_a, "toggle_story_map_tray")

      {:ok, view_c, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view_c, "#story-map-tray-toggle[aria-expanded='false']")
    end

    # RE257 — zoom and Hide tasks are shared for a HARDER reason than the tray: both change the
    # grid geometry that raw-pixel cursors are measured in, so a viewer left behind on the old
    # value sees everyone else's cursor over the wrong card.
    test "a zoom change in one session moves the other, and a late joiner opens on it",
         %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert attr_of(view_b, "#story-map-zoom-compact", "aria-pressed") == "true"

      view_a |> element("#story-map-zoom-full") |> render_click()

      assert attr_of(view_b, "#story-map-zoom-full", "aria-pressed") == "true"
      assert attr_of(view_a, "#story-map-zoom-full", "aria-pressed") == "true"
      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["zoom"] == "full"

      {:ok, view_c, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      assert attr_of(view_c, "#story-map-zoom-full", "aria-pressed") == "true"
    end

    test "a Hide tasks click in one session merges the other's columns too",
         %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view_b, "#story-map-task-#{ctx.sign_in.id}")

      view_a |> element("#story-map-hide-tasks") |> render_click()

      refute has_element?(view_b, "#story-map-task-#{ctx.sign_in.id}")
      assert has_element?(view_b, "#story-map-merged-#{ctx.onboard.id}")
      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["hide_tasks"] == true

      {:ok, view_c, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      refute has_element?(view_c, "#story-map-task-#{ctx.sign_in.id}")
    end

    # An unparseable zoom can only reach the row by hand, but it must not take the map down.
    test "a stored zoom the parser rejects falls back to the default", %{conn: conn} = ctx do
      {:ok, _view} = StoryMap.put_view(ctx.board, "zoom", "gigantic")

      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert attr_of(view, "#story-map-zoom-compact", "aria-pressed") == "true"
    end
  end

  describe "live cursors (RE257)" do
    test "the map renders the cursor overlay the hook owns", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-surface")

      assert has_element?(
               view,
               ~s(#story-map-cursor-layer[phx-hook="StoryMapCursors"][phx-update="ignore"])
             )
    end

    test "a cursor move relays to the other session, coloured, and never to itself",
         %{conn: conn} = ctx do
      {other, other_conn} = second_member(ctx.board)
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view_b, "cursor_moved", %{"x" => 120, "y" => 340})
      _ = render(view_a)
      _ = render(view_b)

      other_id = other.id
      color = RelayWeb.CoreComponents.identity_color(other.email)

      assert_push_event(view_a, "story_map_cursor", %{
        user_id: ^other_id,
        name: _name,
        color: ^color,
        x: 120,
        y: 340
      })

      refute_push_event(view_b, "story_map_cursor", %{})
    end

    test "the server-side floor drops a too-fast second move", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      # Two synchronous round trips, microseconds apart against a 40ms floor.
      render_hook(view_b, "cursor_moved", %{"x" => 1, "y" => 1})
      render_hook(view_b, "cursor_moved", %{"x" => 2, "y" => 2})
      _ = render(view_a)

      assert_push_event(view_a, "story_map_cursor", %{x: 1, y: 1})
      refute_push_event(view_a, "story_map_cursor", %{x: 2, y: 2})
    end

    test "cursor_left clears the cursor everywhere else", %{conn: conn} = ctx do
      {other, other_conn} = second_member(ctx.board)
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_hook(view_b, "cursor_left", %{})
      _ = render(view_a)

      other_id = other.id
      assert_push_event(view_a, "story_map_cursor_gone", %{user_id: ^other_id})
    end

    test "a presence leave clears a cursor only when that person is really gone",
         %{conn: conn} = ctx do
      {other, other_conn} = second_member(ctx.board)
      {:ok, _view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      _ = render(view_a)

      # One of their TABS closed while they are still on the map: the cursor must stay, because
      # the other tab is still driving it.
      send(view_a.pid, presence_diff(ctx.board, %{to_string(other.id) => %{metas: []}}))
      _ = render(view_a)
      refute_push_event(view_a, "story_map_cursor_gone", %{})

      # Someone the fresh roster no longer knows: their cursor goes.
      ghost_id = other.id + 10_000
      send(view_a.pid, presence_diff(ctx.board, %{to_string(ghost_id) => %{metas: []}}))
      _ = render(view_a)
      assert_push_event(view_a, "story_map_cursor_gone", %{user_id: ^ghost_id})
    end

    test "the kanban board never relays a cursor", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      # A forged cursor_moved from the board view must reach nobody.
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}")

      render_hook(view_b, "cursor_moved", %{"x" => 5, "y" => 5})
      _ = render(view_a)

      refute_push_event(view_a, "story_map_cursor", %{})
    end
  end

  describe "filter & focus (RE259)" do
    # `sso` is on Sign in / MVP, `audit` on Onboard with no task, `limits` on Sign in with no
    # release, `bulk` under Plan the backlog, `dashboards` unmapped.
    setup ctx do
      {:ok, ai_card} = Cards.add_owner(ctx.audit, :agent)
      {:ok, mine} = Cards.add_owner(ctx.sso, {:user, ctx.user.id})
      {:ok, blocked} = Cards.set_status(ctx.bulk, %{status: :needs_input})
      {:ok, failed} = Cards.set_status(ctx.limits, %{status: :failed})

      %{ai_card: ai_card, mine: mine, blocked: blocked, failed: failed}
    end

    test "the bar renders on the map with a chip per owner, and nowhere else",
         %{conn: conn} = ctx do
      {:ok, board_view, _html} = live(conn, ~p"/board/#{ctx.board.slug}")
      refute has_element?(board_view, "#story-map-filter-bar")

      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view, "#story-map-filter-bar")
      assert has_element?(view, "##{StoryMapFilter.chip_dom_id("agent")}")
      assert has_element?(view, "##{StoryMapFilter.chip_dom_id("u:#{ctx.user.id}")}")
      assert has_element?(view, "#story-map-needs-input-filter")
      assert has_element?(view, "#story-map-count", "5 cards")
      refute has_element?(view, "#story-map-clear-filters")
    end

    test "an owner chip narrows the map and the count, and Clear restores it",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("##{StoryMapFilter.chip_dom_id("agent")}") |> render_click()

      assert has_element?(view, "##{StoryMapFilter.chip_dom_id("agent")}[aria-pressed='true']")
      assert has_element?(view, "#story-map-count", "1 of 5")
      assert has_element?(view, "##{card_dom_id(ctx.board, ctx.ai_card)}")
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.mine)}")
      # The tray narrows with the map — it renders grid.unmapped, built from the same list.
      refute has_element?(view, "##{tray_dom_id(ctx.board, ctx.dashboards)}")

      view |> element("#story-map-clear-filters") |> render_click()

      assert has_element?(view, "#story-map-count", "5 cards")
      assert has_element?(view, "##{StoryMapFilter.chip_dom_id("agent")}[aria-pressed='false']")
      assert has_element?(view, "##{card_dom_id(ctx.board, ctx.mine)}")
    end

    test "Needs input keeps only :needs_input cards — not every human-blocked one",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-needs-input-filter") |> render_click()

      assert has_element?(view, "#story-map-needs-input-filter[aria-pressed='true']")
      assert has_element?(view, "##{card_dom_id(ctx.board, ctx.blocked)}")
      # `:failed` is human-blocked too, and is deliberately NOT "needs input".
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.failed)}")
      assert has_element?(view, "#story-map-count", "1 of 5")
    end

    test "a forged owner key is a silent no-op that writes nothing", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      render_click(view, "toggle_story_map_owner_filter", %{"owner" => "u:nope"})

      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["owner_filter"] == []
      assert has_element?(view, "#story-map-count", "5 cards")
    end

    test "▾ collapses the band to a counted stub and removes its cells",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-collapse-#{ctx.onboard.id}") |> render_click()

      assert has_element?(view, "#story-map-stub-#{ctx.onboard.id}", "Onboard")
      # All three of Onboard's cards (sso, audit, limits) are hidden, and the stub's badge
      # is the only thing that says how many.
      assert has_element?(view, "#story-map-stub-#{ctx.onboard.id}", "3")
      refute has_element?(view, "#story-map-activity-#{ctx.onboard.id}")
      refute has_element?(view, "##{card_dom_id(ctx.board, ctx.sso)}")
      # The neighbour is untouched.
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}")
    end

    test "clicking the stub expands it again, cards back in their cells",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-collapse-#{ctx.onboard.id}") |> render_click()
      view |> element("#story-map-stub-#{ctx.onboard.id}") |> render_click()

      refute has_element?(view, "#story-map-stub-#{ctx.onboard.id}")
      sso_cell = "#story-map-cell-t-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"
      assert has_element?(view, "#{sso_cell} ##{card_dom_id(ctx.board, ctx.sso)}")
    end

    test "◎ stubs every other band, and the chip's ✕ exits", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-focus-#{ctx.onboard.id}") |> render_click()

      assert has_element?(view, "#story-map-exit-focus", "Onboard")
      assert has_element?(view, "#story-map-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-stub-#{ctx.plan.id}")

      view |> element("#story-map-exit-focus") |> render_click()

      refute has_element?(view, "#story-map-exit-focus")
      assert has_element?(view, "#story-map-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}")
    end

    test "◎ on the focused band toggles focus off", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-focus-#{ctx.onboard.id}") |> render_click()
      view |> element("#story-map-focus-#{ctx.onboard.id}") |> render_click()

      refute has_element?(view, "#story-map-exit-focus")
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}")
    end

    test "▾ on the focused band exits focus in the same write, never blanking the map",
         %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-focus-#{ctx.onboard.id}") |> render_click()
      view |> element("#story-map-collapse-#{ctx.onboard.id}") |> render_click()

      refute has_element?(view, "#story-map-exit-focus")
      assert has_element?(view, "#story-map-stub-#{ctx.onboard.id}")
      # The other band came back rather than every band being a stub.
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}")
    end

    test "＋ Add task on a collapsed, focused-away activity expands it", %{conn: conn} = ctx do
      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-collapse-#{ctx.onboard.id}") |> render_click()
      view |> element("#story-map-focus-#{ctx.plan.id}") |> render_click()

      # The band header is not reachable while stubbed, so drive the event the ＋ pushes.
      render_click(view, "story_map_add_task", %{"activity-id" => to_string(ctx.onboard.id)})

      # Otherwise the draft would open on an activity the user cannot see.
      refute has_element?(view, "#story-map-stub-#{ctx.onboard.id}")
      refute has_element?(view, "#story-map-exit-focus")
      assert has_element?(view, "#story-map-draft-input")

      view_state = StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))
      assert view_state["collapsed"] == []
      assert view_state["focus"] == nil
      assert view_state["hide_tasks"] == false
    end

    test "the narrowed view is SHARED — a collapse in one session lands in the other",
         %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      assert has_element?(view_b, "#story-map-activity-#{ctx.plan.id}")

      view_a |> element("#story-map-collapse-#{ctx.plan.id}") |> render_click()

      assert has_element?(view_b, "#story-map-stub-#{ctx.plan.id}")
      assert has_element?(view_a, "#story-map-stub-#{ctx.plan.id}")

      assert StoryMap.view(Repo.get!(Schemas.Board, ctx.board.id))["collapsed"] ==
               [ctx.plan.id]

      {:ok, view_c, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      assert has_element?(view_c, "#story-map-stub-#{ctx.plan.id}")
    end

    test "an owner filter is shared too", %{conn: conn} = ctx do
      {_other, other_conn} = second_member(ctx.board)
      {:ok, view_a, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")
      {:ok, view_b, _html} = live(other_conn, ~p"/board/#{ctx.board.slug}/story-map")

      view_a |> element("##{StoryMapFilter.chip_dom_id("agent")}") |> render_click()

      assert has_element?(view_b, "#story-map-count", "1 of 5")
    end

    test "a focus on an activity another tab deleted is no focus", %{conn: conn} = ctx do
      {:ok, _view} = StoryMap.merge_view(ctx.board, %{"focus" => 999_999})

      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      # An unresolved focus that still collapsed everything else would blank the map.
      assert has_element?(view, "#story-map-activity-#{ctx.onboard.id}")
      assert has_element?(view, "#story-map-activity-#{ctx.plan.id}")
      refute has_element?(view, "#story-map-exit-focus")
    end

    test "the bar stays live on an archived board — view state is not board data",
         %{conn: conn} = ctx do
      {:ok, _board} = Boards.archive_board(ctx.board)

      {:ok, view, _html} = live(conn, ~p"/board/#{ctx.board.slug}/story-map")

      view |> element("#story-map-collapse-#{ctx.onboard.id}") |> render_click()
      assert has_element?(view, "#story-map-stub-#{ctx.onboard.id}")

      view |> element("#story-map-needs-input-filter") |> render_click()
      assert has_element?(view, "#story-map-needs-input-filter[aria-pressed='true']")
    end
  end
end
