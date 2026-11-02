defmodule HamacaWeb.Browser.StoryMapCreateTest do
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
  ＋, the bare `＋ Add step` header, an activity header's ＋, and ＋ Release — and checks the
  input comes back empty and still focused, which is what lets a backbone be typed hands-free.

  RE501 adds the cell composer (a cell's dashed ＋). Its input used to carry a bare `autofocus`.
  LiveView patches the composer in and does nothing with `autofocus`, and the browser honors it
  only for the first autofocus element in a document. So the first cell you opened was
  focused, and every later one (another cell, a reopen) needed a click before you could type.
  `mix test` cannot see focus at all. The fix is `phx-mounted={JS.focus()}`. The second test
  opens a cell, types and presses Enter twice, then opens a different cell and types again.
  It types only into the `:focus`-qualified input, so the keystrokes never focus it
  themselves.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.StoryMap
  alias PlaywrightEx.Frame

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
    # The bare `＋ Add step` header: "Onboard & access" has no steps yet.
    |> click("#story-map-no-step-#{onboard.id}")
    |> assert_has(@input)
    |> commit("Watch it live")
    |> assert_has("#story-map-grid", text: "Watch it live")
    |> press(@input, "Escape")
    # The activity header's ＋, now that the activity has a real step column.
    |> click("#story-map-add-step-#{onboard.id}")
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

    assert Enum.map(StoryMap.list_steps(board), & &1.name) == ["Watch it live", "Run big changes"]
    assert List.last(StoryMap.list_releases(board)).name == "Someday"
  end

  test "the cell composer opens focused and stays focused across Enter", %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    {:ok, board} = Boards.create_board(user, %{name: "Story map composer focus"})
    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_step(onboard, %{name: "Sign in", position: 1})
    {:ok, organize} = StoryMap.create_step(plan, %{name: "Organize cards", position: 1})
    mvp = hd(StoryMap.list_releases(board))

    sign_in_cell = "s-#{sign_in.id}-r-#{mvp.id}"
    organize_cell = "s-#{organize.id}-r-#{mvp.id}"
    sign_in_input = "#story-map-compose-#{sign_in_cell}-input"
    organize_input = "#story-map-compose-#{organize_cell}-input"

    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}/story-map")
    |> assert_has("body .phx-connected")
    |> assert_has("#story-map-grid")
    # The bug: the composer is patched in by LiveView, so its bare `autofocus` never fired and
    # the user had to click the input before typing. Opening it must land focus in it.
    |> click("#story-map-add-#{sign_in_cell}")
    |> assert_focused_and_empty(sign_in_input)
    |> commit_focused(sign_in_input, "Focus check")
    |> assert_has("#story-map-cell-#{sign_in_cell}", text: "Focus check")
    # Enter keeps the same composer (same DOM node, so phx-mounted does not re-fire); LiveView's
    # post-submit focus restore is what keeps it focused. Wait on `:focus`, never sample it.
    |> assert_focused_and_empty(sign_in_input)
    |> commit_focused(sign_in_input, "Second card")
    |> assert_has("#story-map-cell-#{sign_in_cell}", text: "Focus check")
    |> assert_has("#story-map-cell-#{sign_in_cell}", text: "Second card")
    |> assert_focused_and_empty(sign_in_input)
    # Another cell's ＋ with a composer open: click-away closes the first, and the second
    # cell's input is a fresh mount that must take focus.
    |> click("#story-map-add-#{organize_cell}")
    |> assert_focused_and_empty(organize_input)
    |> refute_has("#story-map-compose-#{sign_in_cell}")
    |> commit_focused(organize_input, "Other cell")
    |> assert_has("#story-map-cell-#{organize_cell}", text: "Other cell")
    # Escape closes the composer and brings the cell's ＋ back.
    |> press(organize_input, "Escape")
    |> refute_has("#story-map-compose-#{organize_cell}")
    |> assert_has("#story-map-add-#{organize_cell}")

    cards = Cards.list_cards(board)

    for title <- ["Focus check", "Second card"] do
      card = Enum.find(cards, &(&1.title == title))
      assert card.story_step_id == sign_in.id
      assert card.release_id == mvp.id
    end

    assert Enum.find(cards, &(&1.title == "Other cell")).story_step_id == organize.id
  end

  # Type the name and press Enter, exactly as a user does: real keystrokes for phx-change to
  # see, then the real Enter that goes through LiveView's submit path — blur and all.
  defp commit(session, name) do
    session
    |> type(@input, name)
    |> press(@input, "Enter")
  end

  # Wait for real browser focus to land on `input`, then check it is empty. Waiting (not
  # sampling) matters: focus arrives with the patch, after the click or Enter returns.
  defp assert_focused_and_empty(session, input) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.wait_for_selector(frame_id, selector: "#{input}:focus", timeout: 2_000)
      {:ok, value} = Frame.input_value(frame_id, selector: input, timeout: 2_000)
      assert value == "", ~s(expected #{input} to be empty, got "#{value}")
    end)
  end

  # Type into the input only while it already holds focus — the `:focus`-qualified selector
  # never matches an unfocused input, so the keystrokes cannot be what focused it.
  defp commit_focused(session, input, name) do
    session
    |> type("#{input}:focus", name)
    |> press("#{input}:focus", "Enter")
  end
end
