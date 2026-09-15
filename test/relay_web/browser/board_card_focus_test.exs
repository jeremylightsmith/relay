defmodule RelayWeb.Browser.BoardCardFocusTest do
  @moduledoc """
  Real-browser (Playwright) tests for RE326. Switching the drawer's card with ←/→ or the ‹ ›
  chevrons moves keyboard focus to that card on the board and scrolls it into view. Closing the
  drawer leaves focus on the last card viewed.

  `RelayWeb.BoardLiveTest` pins the server half (`BoardLive.handle_params/3` pushing
  `focus_card`). `Phoenix.LiveViewTest` never runs the `BoardDnD` / `StoryMapDnD` hooks that act on
  that push, so only a real browser can see where `document.activeElement` ends up. Same
  reasoning as `RelayWeb.Browser.TypingKeyGuardTest`.

  Every key is pressed with focus INSIDE the drawer, never on a board card, because
  `Frame.press/2` focuses its selector first. A board card can only end up focused if the pushed
  `focus_card` moved it there, so the focus assertions can't pass by accident.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias PlaywrightEx.Frame
  alias Relay.Accounts
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.StoryMap

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    board = Boards.get_or_create_default_board(user)
    code = Enum.find(board.stages, &(&1.name == "Code"))

    %{user: user, board: board, code: code}
  end

  test "arrowing moves focus to the drawer's card, and arrowing back moves it back", ctx do
    [first, second, third] = column(ctx.board, ctx.code, 3)

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> click(board_card(first))
    |> assert_drawer_shows(first)
    |> press_in_drawer("ArrowRight")
    |> assert_drawer_shows(second)
    |> assert_focused(second)
    |> press_in_drawer("ArrowRight")
    |> assert_drawer_shows(third)
    |> assert_focused(third)
    |> press_in_drawer("ArrowLeft")
    |> assert_drawer_shows(second)
    |> assert_focused(second)
  end

  test "Escape closes the drawer and leaves focus on the last card viewed", ctx do
    [first, second, third] = column(ctx.board, ctx.code, 3)

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> click(board_card(first))
    |> assert_drawer_shows(first)
    |> press_in_drawer("ArrowRight")
    |> assert_drawer_shows(second)
    |> press_in_drawer("ArrowRight")
    |> assert_drawer_shows(third)
    |> assert_focused(third)
    # Escape is pressed on the drawer's Detail tab, so focus is inside the drawer as it goes away.
    # The third card only has focus afterwards if the close pushed it there.
    |> press_in_drawer("Escape")
    |> refute_has("#card-drawer-panel")
    |> assert_focused(third)
  end

  test "clicking the › chevron moves focus to the next card too", ctx do
    [first, second] = column(ctx.board, ctx.code, 2)

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}")
    |> click(board_card(first))
    |> assert_drawer_shows(first)
    |> click("#card-drawer-next")
    |> assert_drawer_shows(second)
    |> assert_focused(second)
  end

  test "a deep link steals no focus and scrolls nothing; a switch scrolls the board to follow", ctx do
    refs = column(ctx.board, ctx.code, 20)
    [opened, target] = Enum.take(refs, -2)

    ctx.conn
    |> visit_board("/board/#{ctx.board.slug}?card=#{opened}")
    |> assert_drawer_shows(opened)
    |> unwrap(fn %{frame_id: frame_id} ->
      # Precondition: the column must overflow the viewport, or "scrolls to follow" proves nothing.
      # If this fails, the column needs more cards, not a looser assertion.
      refute card_in_viewport?(frame_id, target),
             "precondition: #{target} must start below the fold — add cards to the column"

      # A deep link neither focused the opened card nor scrolled the board to it.
      refute card_in_viewport?(frame_id, opened), "the deep link scrolled the board to #{opened}"
      refute focused_ref(frame_id) == opened, "the deep link moved focus to #{opened}"
    end)
    |> click("#card-drawer-next")
    |> assert_drawer_shows(target)
    |> assert_focused(target)
    |> assert_in_viewport(target)
  end

  test "the story map drawer hands focus back to its card on close, with card nav still off", ctx do
    {:ok, board} = Boards.create_board(ctx.user, %{name: "Focus map"})
    {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, task} = StoryMap.create_task(activity, %{name: "Sign in", position: 1})
    [mvp | _later] = StoryMap.list_releases(board)

    board = Boards.get_board!(ctx.user, board.slug)
    [backlog | _rest] = board.stages
    {:ok, card} = Cards.create_card(backlog, %{title: "Add SSO"})
    {:ok, _placed} = StoryMap.assign_card(card, %{story_task_id: task.id, release_id: mvp.id})
    ref = Cards.ref(board, card)

    ctx.conn
    |> visit_board("/board/#{board.slug}/story-map")
    |> assert_has("#story-map-grid")
    |> click("#story-map-card-#{ref}")
    |> assert_drawer_shows(ref)
    # RE264 — card nav stays off on the story map. This card doesn't turn it on.
    |> refute_has("#card-drawer-nav")
    # Pressed on the drawer's Detail tab, so focus is inside the drawer as it goes away. The map
    # card only has focus afterwards if StoryMapDnD acted on the close's focus_card push.
    |> press_in_drawer("Escape")
    |> refute_has("#card-drawer-panel")
    |> assert_focused(ref)
  end

  # Creates `count` cards in `stage` and returns their refs in the order the board renders the
  # column. `Cards.stage_column/2` is the same read `stage_neighbors/2` (and so ←/→) walks.
  defp column(board, stage, count) do
    Enum.each(1..count, fn n -> {:ok, _card} = Cards.create_card(stage, %{title: "Focus #{n}"}) end)

    board |> Cards.stage_column(stage.id) |> Enum.map(&Cards.ref(board, &1))
  end

  defp visit_board(conn, path) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit(path)
    # Keys pressed before LiveView binds its window listeners are lost (see TypingKeyGuardTest),
    # and so is a push to a hook that hasn't mounted yet, so wait for THIS page's socket.
    |> assert_has("body .phx-connected")
  end

  defp board_card(ref), do: ~s(.board-card[data-ref="#{ref}"])

  defp assert_drawer_shows(session, ref) do
    assert_has(session, "#card-drawer .drawer-card-ref", text: ref, exact: true)
  end

  defp press_in_drawer(session, key) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.press(frame_id, selector: "#card-drawer-tab-detail", key: key, timeout: 2_000)
    end)
  end

  # `focus_card` is applied after the patch's DOM update, so wait for it to land. Then read
  # activeElement back as the load-bearing assertion. On a timeout, wait_for_function returns an
  # error we ignore, and the assert below reports what actually has focus.
  defp assert_focused(session, ref) do
    unwrap(session, fn %{frame_id: frame_id} ->
      _ =
        Frame.wait_for_function(frame_id,
          expression: "document.activeElement && document.activeElement.dataset.ref === #{Jason.encode!(ref)}",
          timeout: 5_000
        )

      focused = focused_ref(frame_id)

      assert focused == ref,
             "expected board focus on #{ref}, but document.activeElement's data-ref was #{inspect(focused)}"
    end)
  end

  defp assert_in_viewport(session, ref) do
    unwrap(session, fn %{frame_id: frame_id} ->
      _ =
        Frame.wait_for_function(frame_id, expression: in_viewport_expression(ref), timeout: 5_000)

      assert card_in_viewport?(frame_id, ref), "#{ref} was focused but never scrolled into view"
    end)
  end

  defp focused_ref(frame_id) do
    {:ok, ref} =
      Frame.evaluate(frame_id,
        expression: "(() => document.activeElement && document.activeElement.dataset.ref)()",
        timeout: 2_000
      )

    ref
  end

  defp card_in_viewport?(frame_id, ref) do
    {:ok, visible?} = Frame.evaluate(frame_id, expression: "(() => #{in_viewport_expression(ref)})()", timeout: 2_000)
    visible? == true
  end

  defp in_viewport_expression(ref) do
    selector = Jason.encode!(board_card(ref))

    "(r => r.top >= 0 && r.bottom <= window.innerHeight)" <>
      "(document.querySelector(#{selector}).getBoundingClientRect())"
  end
end
