defmodule RelayWeb.Browser.StoryMapEditTest do
  @moduledoc """
  Real-browser (Playwright) coverage for RE261, for the two things `mix test` cannot see.

  **The rename keypress.** A real Enter goes through LiveView's `View.submitForm`, which calls
  `liveSocket.blurActiveElement()` BEFORE pushing the submit. `render_submit/2` never blurs, so
  the fast suite cannot tell `phx-click-away` from `phx-blur` — and with `phx-blur` bound to
  cancel, Enter would rename NOTHING while the suite stayed green (the bug RE263 already hit).

  **The header drag.** `render_hook/3` proves the server's drop matrix; only a real drag proves
  the hook actually pushes `story_map_reorder` from a header, and that the card drag it sits
  beside still works.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.StoryMap

  @moduletag :playwright

  test "renaming with a real Enter, and reordering with a real drag", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    {:ok, board} = Boards.create_board(user, %{name: "Story map edit"})
    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_task(onboard, %{name: "Sign in", position: 1})
    {:ok, _organize} = StoryMap.create_task(plan, %{name: "Organize cards", position: 1})
    [mvp, _fast_follow, later] = StoryMap.list_releases(board)

    [backlog | _rest] = Boards.get_board!(user, board.slug).stages
    {:ok, sso} = Cards.create_card(backlog, %{title: "Add SSO"})
    {:ok, _placed} = StoryMap.assign_card(sso, %{story_task_id: sign_in.id, release_id: mvp.id})

    session =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{board.slug}/story-map")
      |> assert_has("#story-map-grid")
      # Escape cancels and writes nothing. The input opens pre-filled with the current name, so
      # select-all before typing — a real user replaces it too, they don't append to it.
      |> click("#story-map-name-activity-#{onboard.id}")
      |> assert_has("#story-map-rename-activity-#{onboard.id}")
      |> press("#story-map-rename-activity-#{onboard.id}", "ControlOrMeta+a")
      |> type("#story-map-rename-activity-#{onboard.id}", "Discarded")
      |> press("#story-map-rename-activity-#{onboard.id}", "Escape")
      |> refute_has("#story-map-rename-activity-#{onboard.id}")
      # Enter commits — the whole reason this test exists.
      |> click("#story-map-name-activity-#{onboard.id}")
      |> press("#story-map-rename-activity-#{onboard.id}", "ControlOrMeta+a")
      |> type("#story-map-rename-activity-#{onboard.id}", "Onboarding v2")
      |> press("#story-map-rename-activity-#{onboard.id}", "Enter")
      |> assert_has("#story-map-activity-#{onboard.id}", text: "Onboarding v2")

    assert Enum.map(StoryMap.list_activities(board), & &1.name) == [
             "Onboarding v2",
             "Plan the backlog"
           ]

    # A real header drag: the LAST activity dropped on the FIRST becomes the leftmost.
    # `drag/3` is PhoenixTest.Playwright's own wrapper around Frame.drag_and_drop/2, which
    # returns once the browser has dispatched the drop — NOT once the server has processed it.
    # `assert_has("#story-map-grid")` matches before AND after the drag (the grid never
    # disappears), so it resolves immediately and waits for nothing; reading the DB right after
    # would race the async `story_map_reorder` push/patch. The real barrier has to be DOM that
    # only holds true after the reorder lands — here, the band's own inline `grid-column`
    # (`band_style/1`), which moves to column 2 only once `plan` is leftmost.
    session
    |> drag("#story-map-activity-#{plan.id}", to: "#story-map-activity-#{onboard.id}")
    |> assert_has(~s(#story-map-activity-#{plan.id}[style^="grid-column:2 "]))

    assert Enum.map(StoryMap.list_activities(board), & &1.name) == [
             "Plan the backlog",
             "Onboarding v2"
           ]

    # And a release drag, the swimlane rail's own reorder. Same reasoning: wait on the swimlane
    # label's inline `grid-row` (`lane_label_style/1`), which only reads 3 once `later` is the
    # topmost lane.
    session
    |> drag("#story-map-release-#{later.id}", to: "#story-map-release-#{mvp.id}")
    |> assert_has(~s(#story-map-release-#{later.id}[style*="grid-row:3;"]))

    assert Enum.map(StoryMap.list_releases(board), & &1.name) == ["Later", "MVP", "Fast follow"]

    # The CARD drag still works beside the new one — the regression this card most risks.
    session
    |> drag(
      "#story-map-card-#{Cards.ref(board, sso)}",
      to: "#story-map-cell-t-#{sign_in.id}-r-#{later.id}"
    )
    |> assert_has("#story-map-cell-t-#{sign_in.id}-r-#{later.id} #story-map-card-#{Cards.ref(board, sso)}")
  end
end
