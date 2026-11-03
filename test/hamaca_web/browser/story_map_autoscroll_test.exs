defmodule HamacaWeb.Browser.StoryMapAutoscrollTest do
  @moduledoc """
  Real-browser (Playwright) coverage for RE272's edge autoscroll: while a story-map drag is held
  within 48px of an edge of `#story-map-surface` (the scroller, not the hook element), the map
  scrolls toward that edge, so a card can be dropped into a cell that started off-screen.

  Like `StoryMapDropLineTest`, the drag is driven with synthetic `DragEvent`s from
  `Frame.evaluate/2` (one shared `DataTransfer` per drag, kept on `window`), each dispatched on
  the element under the point (`document.elementFromPoint/2`) with the matching
  `clientX/clientY`. A synthetic `dragover` fires ONCE — it never repeats like a held real one —
  so these tests prove the hook's own animation loop keeps scrolling. Waits happen in the page
  (`await new Promise(r => setTimeout(r, 300))` inside the evaluated expression), never with
  `Process.sleep`.

  The fixture is the drop-line test's two activities and three cards plus enough releases (12 in
  all) that the grid is taller than the surface — each test asserts that precondition first.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.StoryMap
  alias PlaywrightEx.Frame

  @moduletag :playwright

  @releases 12

  setup %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    {:ok, board} = Boards.create_board(user, %{name: "Story map autoscroll"})
    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_step(onboard, %{name: "Sign in", position: 1})
    {:ok, organize} = StoryMap.create_step(plan, %{name: "Organize cards", position: 1})

    defaults = StoryMap.list_releases(board)

    for position <- (length(defaults) + 1)..@releases do
      {:ok, _} = StoryMap.create_release(board, %{name: "Release #{position}", position: position})
    end

    [mvp | _rest] = StoryMap.list_releases(board)

    [backlog | _rest] = Boards.get_board!(user, board.slug).stages
    {:ok, a} = Cards.create_card(backlog, %{title: "Card A"})
    {:ok, b} = Cards.create_card(backlog, %{title: "Card B"})
    {:ok, c} = Cards.create_card(backlog, %{title: "Card C"})
    {:ok, _} = StoryMap.assign_card(a, %{story_step_id: sign_in.id, release_id: mvp.id})
    {:ok, _} = StoryMap.assign_card(b, %{story_step_id: sign_in.id, release_id: mvp.id})
    {:ok, _} = StoryMap.assign_card(c, %{story_step_id: organize.id, release_id: mvp.id})

    session =
      conn
      |> visit("/dev/login")
      |> assert_has("body .phx-connected")
      |> visit("/board/#{board.slug}/story-map")
      |> assert_has("body .phx-connected")
      |> assert_has("#story-map-grid")

    assert js(session, "(() => { const s = #{surface()}; return s.scrollHeight > s.clientHeight })()"),
           "precondition: the story map must overflow #story-map-surface vertically"

    assert scroll_top(session) == 0

    %{session: session, board: board, sign_in: sign_in, c: Cards.ref(board, c)}
  end

  test "a card drag held in the bottom band scrolls the map down", ctx do
    dispatch(ctx.session, "dragstart", card(ctx.c))

    assert drag_at(ctx.session, "dragover", y: "s.bottom - 10", wait: 300) > 0
  end

  test "dragend stops the scrolling", ctx do
    dispatch(ctx.session, "dragstart", card(ctx.c))
    assert drag_at(ctx.session, "dragover", y: "s.bottom - 10", wait: 300) > 0

    dispatch(ctx.session, "dragend", card(ctx.c))

    assert [first, second] = readings_apart(ctx.session, 300)
    assert first == second
  end

  test "a dragover in the bottom band with no drag in progress never scrolls", ctx do
    assert drag_at(ctx.session, "dragover", y: "s.bottom - 10", wait: 300) == 0
  end

  test "a card drops into a cell that started below the viewport", ctx do
    %{"selector" => cell, "release_id" => release_id} = first_cell_below_viewport(ctx.session, ctx.sign_in.id)

    dispatch(ctx.session, "dragstart", card(ctx.c))
    assert drag_at(ctx.session, "dragover", y: "s.bottom - 10", wait: 300) > 0

    # Keep holding in the band until the cell's centre clears it, then hover and drop there.
    wait_until_clear_of_band(ctx.session, cell)
    drag_on(ctx.session, "dragover", cell)
    drag_on(ctx.session, "drop", cell)
    dispatch(ctx.session, "dragend", card(ctx.c))

    assert_has(ctx.session, "#story-map-cell-s-#{ctx.sign_in.id}-r-#{release_id} #{card(ctx.c)}")
  end

  test "moving the pointer out of the band stops the scrolling", ctx do
    dispatch(ctx.session, "dragstart", card(ctx.c))
    assert drag_at(ctx.session, "dragover", y: "s.bottom - 10", wait: 150) > 0

    drag_at(ctx.session, "dragover", y: "s.top + s.height / 2", wait: 0)

    assert [first, second] = readings_apart(ctx.session, 300)
    assert first == second
  end

  # --- helpers ------------------------------------------------------------------------------

  defp card(ref), do: ~s(.story-map-card[data-ref="#{ref}"])

  defp surface, do: ~s{document.getElementById("story-map-surface")}

  defp scroll_top(session), do: js(session, "(() => #{surface()}.scrollTop)()")

  # Reads scrollTop, waits `ms` in the page, reads it again.
  defp readings_apart(session, ms) do
    js(session, """
    (async () => {
      const first = #{surface()}.scrollTop
      await new Promise(r => setTimeout(r, #{ms}))
      return [first, #{surface()}.scrollTop]
    })()
    """)
  end

  # Dispatches one synthetic DragEvent on the element under a point of the surface's rect `s`
  # (`x` / `y` are JS expressions over `s`, defaulting to its centre), waits `wait` ms in the
  # page, and returns the surface's scrollTop.
  defp drag_at(session, type, opts) do
    x = Keyword.get(opts, :x, "s.left + s.width / 2")
    y = Keyword.get(opts, :y, "s.top + s.height / 2")
    wait = Keyword.get(opts, :wait, 0)

    js(session, """
    (async () => {
      const s = #{surface()}.getBoundingClientRect()
      const x = #{x}, y = #{y}
      #{fire(type)}
      await new Promise(r => setTimeout(r, #{wait}))
      return #{surface()}.scrollTop
    })()
    """)
  end

  # Dispatches one synthetic DragEvent at the centre of `selector`'s element, on whatever is
  # under that point.
  defp drag_on(session, type, selector) do
    js(session, """
    (() => {
      const r = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect()
      const x = r.left + r.width / 2, y = r.top + r.height / 2
      #{fire(type)}
      return true
    })()
    """)
  end

  # A dragstart/dragend on a known element (the dragged card), at its centre.
  defp dispatch(session, type, selector) do
    js(session, """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      const r = el.getBoundingClientRect()
      if (#{Jason.encode!(type)} === "dragstart") window.__smDataTransfer = new DataTransfer()
      el.dispatchEvent(new DragEvent(#{Jason.encode!(type)}, {
        bubbles: true, cancelable: true,
        clientX: r.left + r.width / 2, clientY: r.top + r.height / 2,
        dataTransfer: window.__smDataTransfer,
      }))
      return true
    })()
    """)
  end

  defp fire(type) do
    """
    const target = document.elementFromPoint(x, y)
    if (!target) throw new Error("nothing under " + x + "," + y)
    target.dispatchEvent(new DragEvent(#{Jason.encode!(type)}, {
      bubbles: true, cancelable: true, clientX: x, clientY: y,
      dataTransfer: window.__smDataTransfer || new DataTransfer(),
    }))
    """
  end

  # The sign-in step's first cell whose top starts below the surface's bottom edge, with the
  # release it belongs to (from the cell's own data-lane).
  defp first_cell_below_viewport(session, step_id) do
    js(session, """
    (() => {
      const bottom = #{surface()}.getBoundingClientRect().bottom
      const cell = Array.from(document.querySelectorAll('[id^="story-map-cell-s-#{step_id}-r-"]'))
        .find(el => el.getBoundingClientRect().top > bottom)
      if (!cell) throw new Error("no sign-in cell starts below the viewport")
      return {selector: "#" + cell.id, release_id: cell.id.split("-r-")[1]}
    })()
    """)
  end

  # Polls in the page (the autoscroll loop keeps running meanwhile) until the cell's centre sits
  # above the 48px band at the surface's bottom edge.
  defp wait_until_clear_of_band(session, cell) do
    assert js(
             session,
             """
             (async () => {
               for (let i = 0; i < 100; i++) {
                 const s = #{surface()}.getBoundingClientRect()
                 const r = document.querySelector(#{Jason.encode!(cell)}).getBoundingClientRect()
                 if (r.top + r.height / 2 < s.bottom - 60) return true
                 await new Promise(res => setTimeout(res, 50))
               }
               return false
             })()
             """,
             8_000
           ),
           "the map never scrolled #{cell} clear of the bottom band"
  end

  defp js(session, expression, timeout \\ 2_000) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: timeout)
      send(self(), {:evaluated, value})
    end)

    receive do
      {:evaluated, value} -> value
    end
  end
end
