defmodule RelayWeb.Browser.StoryMapCreateTest do
  @moduledoc """
  Real-browser (Playwright) regression test for RE263's create affordances.

  This exists because `mix test` cannot see the bug it guards. `render_submit/2` pushes the
  submit event and nothing else, but a real browser's Enter goes through LiveView's
  `View.submitForm`, which calls `liveSocket.blurActiveElement()` BEFORE pushing the submit
  (and churns focus twice more around the patch that follows). With a declarative
  `phx-blur="story_map_draft_cancel"` on the input, that blur landed first, closed the draft,
  and the submit behind it found `@story_map_draft` already nil — so Enter created NOTHING, in
  all five affordances, while the LiveView suite stayed green.

  The fix is `phx-click-away` in place of `phx-blur`: only a real click elsewhere cancels, and
  LiveView's own focus juggling is ignored. Only a real keypress in a real browser proves it,
  so this walks all five entry points with a real Enter: the empty panel's button, the trailing
  ＋, the bare `＋ Add task` header, an activity header's ＋, and ＋ Release — and checks the
  input comes back empty and still focused, which is what lets a backbone be typed hands-free.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.StoryMap

  @moduletag :playwright

  @input "#story-map-draft-input"

  test "Enter commits a name in every create affordance", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    # A fresh board has no activities, so it opens on the empty panel — the first affordance.
    {:ok, board} = Boards.create_board(user, %{name: "Story map browser"})

    session =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{board.slug}/story-map")
      |> assert_has("#story-map-empty-add-activity")
      |> click("#story-map-empty-add-activity")
      |> assert_has(@input)
      |> commit("Onboard & access")
      # The grid replaces the empty panel only if the activity actually exists.
      |> assert_has("#story-map-grid", text: "Onboard & access")

    [onboard] = StoryMap.list_activities(board)

    session
    # The card's whole point: the input comes back empty and still focused, so the next
    # sibling is typed without touching the mouse. `:focus` makes Playwright wait for focus to
    # land — the panel-to-grid patch recreates the input, so it is the hook's mounted() that
    # re-focuses — rather than sampling too early.
    |> unwrap(fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.wait_for_selector(frame_id, selector: "#{@input}:focus", timeout: 2_000)
      {:ok, value} = Frame.input_value(frame_id, selector: @input, timeout: 2_000)
      assert value == "", ~s(expected the draft input to come back empty, got "#{value}")
    end)
    # Still the same open draft — now the grid's trailing add-activity cell — so a second
    # Enter appends the next activity.
    |> commit("Ship work with AI")
    |> assert_has("#story-map-grid", text: "Ship work with AI")
    |> press(@input, "Escape")
    |> refute_has(@input)
    # The bare `＋ Add task` header: "Onboard & access" has no tasks yet.
    |> click("#story-map-no-task-#{onboard.id}")
    |> assert_has(@input)
    |> commit("Watch it live")
    |> assert_has("#story-map-grid", text: "Watch it live")
    |> press(@input, "Escape")
    # The activity header's ＋, now that the activity has a real task column.
    |> click("#story-map-add-task-#{onboard.id}")
    |> assert_has(@input)
    |> commit("Run big changes")
    |> assert_has("#story-map-grid", text: "Run big changes")
    |> press(@input, "Escape")
    # ＋ Release, in the sticky left rail.
    |> click("#story-map-add-release")
    |> assert_has(@input)
    |> commit("Someday")
    |> assert_has("#story-map-grid", text: "Someday")
    # Clicking a DIFFERENT ＋ with a draft open: LiveView dispatches click-away before that
    # click's own phx-click, so the release draft cancels and the activity draft opens. If the
    # order inverted, the cancel would close the just-opened draft and this Enter would create
    # nothing at all. Both drafts render the same input id, so wait on the placeholder — it is
    # the only thing that says the draft has actually moved from the rail to the activity cell.
    |> click("#story-map-add-activity")
    |> assert_has(~s(#{@input}[placeholder="Activity name… ↵"]))
    |> commit("Report & share")
    |> assert_has("#story-map-grid", text: "Report & share")

    assert Enum.map(StoryMap.list_activities(board), & &1.name) == [
             "Onboard & access",
             "Ship work with AI",
             "Report & share"
           ]

    assert Enum.map(StoryMap.list_tasks(board), & &1.name) == ["Watch it live", "Run big changes"]
    assert List.last(StoryMap.list_releases(board)).name == "Someday"
  end

  # Type the name and press Enter, exactly as a user does: real keystrokes for phx-change to
  # see, then the real Enter that goes through LiveView's submit path — blur and all.
  defp commit(session, name) do
    session
    |> type(@input, name)
    |> press(@input, "Enter")
  end
end
