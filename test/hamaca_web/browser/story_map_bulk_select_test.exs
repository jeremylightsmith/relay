defmodule HamacaWeb.Browser.StoryMapBulkSelectTest do
  @moduledoc """
  Real-browser (Playwright) test for RE502's story-map multi-select.

  This exists because `mix test` cannot exercise the gesture. ⇧-click is intercepted in the
  `StoryMapDnD` JS hook: it stops the click before LiveView's `phx-click="select_card"` sees
  it and pushes `toggle_card_selection` instead. The LiveView suite can only push that event
  by hand, so it cannot tell whether a real ⇧-click toggles the selection — or whether it also
  opens the drawer, which is the bug the interception prevents. Only a real click with the
  Shift modifier in a real browser proves it, and that a plain click still opens the card.

  The second test checks the bulk bar's Stage menu at a 390px phone width: the panel is
  anchored to the bar's left edge, so only real layout shows it stays on-screen and is capped
  at 60% of the viewport height (it scrolls instead of running off the top).

  The third test checks the batched live-run confirm: with three buttons in its footer, only
  real layout shows "Keep all here" stays inside the `max-w-md` modal box (an unwrapped row
  overflowed it to the left, under the backdrop) and that a real click reaches it.
  """
  use PhoenixTest.Playwright.Case, async: false

  import Hamaca.Factory

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.StoryMap
  alias PlaywrightEx.Frame

  @moduletag :playwright

  setup do
    user = Accounts.ensure_dev_user!()
    {:ok, board} = Boards.create_board(user, %{name: "Story map bulk select"})
    [backlog | _rest] = board.stages
    {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, step} = StoryMap.create_step(activity, %{name: "Sign in", position: 1})
    release = hd(StoryMap.list_releases(board))

    cards =
      for title <- ["First card", "Second card", "Third card"] do
        {:ok, card} = Cards.create_card(backlog, %{title: title})
        {:ok, card} = StoryMap.assign_card(card, %{story_step_id: step.id, release_id: release.id})
        card
      end

    %{board: board, refs: Enum.map(cards, &Cards.ref(board, &1))}
  end

  test "⇧-click builds a selection without opening the drawer; a plain click opens it",
       %{conn: conn, board: board, refs: [first, second, third]} do
    conn
    |> open_map(board)
    |> shift_click(first)
    |> assert_has("#story-map-bulk-bar", text: "1 selected")
    |> shift_click(second)
    |> assert_has("#story-map-bulk-bar", text: "2 selected")
    |> assert_has(~s(#story-map-card-#{first}-select[aria-pressed="true"]))
    |> assert_has(~s(#story-map-card-#{second}-select[aria-pressed="true"]))
    |> assert_path("/board/#{board.slug}/story-map")
    # `#card-drawer` is a zero-size wrapper, so the check is on its visible ref chip.
    |> refute_has("#card-drawer .drawer-card-ref")
    # A plain click is untouched by the hook: it opens the drawer, and the selection stays.
    |> click("#story-map-card-#{third}")
    |> assert_has("#card-drawer .drawer-card-ref", text: third, exact: true)
    |> assert_has("#story-map-bulk-bar", text: "2 selected")
  end

  @tag browser_context_opts: [viewport: %{width: 390, height: 844}]
  test "at 390px the Stage menu stays on-screen and is capped at 60% of the viewport height",
       %{conn: conn, board: board, refs: [first, second, _third]} do
    # At phone width the open UNMAPPED tray leaves the cells behind the sticky release rail;
    # collapsed to its rail, the cards are clickable — how the map is used on a phone.
    {:ok, _view} = StoryMap.put_view(board, "tray_open", false)

    session =
      conn
      |> open_map(board)
      |> shift_click(first)
      |> shift_click(second)
      |> assert_has("#story-map-bulk-bar", text: "2 selected")
      |> click("#story-map-bulk-stage")
      |> assert_has("#bulk-stage-menu")

    %{"left" => left, "right" => right} = measure(session, rect_js("#bulk-stage-menu"))
    assert left >= 0 and right <= 390, "expected the menu within 0..390, got #{left}..#{right}"

    %{"maxHeight" => max_height, "viewportHeight" => viewport_height} =
      measure(session, """
      (() => ({
        maxHeight: parseFloat(getComputedStyle(document.querySelector("#bulk-stage-menu")).maxHeight),
        viewportHeight: window.innerHeight
      }))()
      """)

    assert max_height <= 0.6 * viewport_height + 0.5,
           "expected max-height <= 60% of #{viewport_height}px, got #{max_height}px"

    %{"width" => bar_width} = measure(session, rect_js("#story-map-bulk-bar"))
    assert bar_width <= 390, "expected the bulk bar to fit 390px, got #{bar_width}px"
  end

  for {label, viewport} <- [{"1440px", %{width: 1440, height: 900}}, {"390px", %{width: 390, height: 844}}] do
    @tag browser_context_opts: [viewport: viewport]
    test "at #{label} the live-run confirm keeps all three buttons inside the modal box", %{conn: conn} do
      user = Accounts.ensure_dev_user!()
      board = insert(:board, owner: user)
      insert(:membership, board: board, user: user)
      backlog = insert(:stage, board: board, name: "Backlog", type: :queue, position: 1)
      plan = insert(:stage, board: board, name: "Plan", type: :queue, position: 2)
      code = insert(:stage, board: board, name: "Code", type: :work, category: :in_progress, position: 3)
      flow = insert(:flow, board: board, key: "code", stage_id: code.id)
      {:ok, activity} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
      {:ok, step} = StoryMap.create_step(activity, %{name: "Sign in", position: 1})
      release = insert(:release, board: board, name: "MVP", position: 1)
      {:ok, _view} = StoryMap.put_view(board, "tray_open", false)

      [a, b, c] =
        for {stage, title} <- [{plan, "Idle one"}, {plan, "Idle two"}, {code, "Running"}] do
          {:ok, card} = Cards.create_card(stage, %{title: title})
          {:ok, card} = StoryMap.assign_card(card, %{story_step_id: step.id, release_id: release.id})
          card
        end

      insert(:run, card: c, flow_id: flow.id, flow_key: flow.key, status: :parked, current_node: "implement")
      refs = Enum.map([a, b, c], &Cards.ref(board, &1))

      session =
        refs
        |> Enum.reduce(open_map(conn, board), &shift_click(&2, &1))
        |> assert_has("#story-map-bulk-bar", text: "3 selected")
        |> click("#story-map-bulk-stage")
        |> click("#bulk-stage-menu-#{backlog.id}")
        |> assert_has("#bulk-move-others")

      box = measure(session, rect_js("#bulk-move-modal .modal-box"))

      for button <- ~w(#bulk-move-keep #bulk-move-others #bulk-move-cancel-runs) do
        %{"left" => left, "right" => right} = measure(session, rect_js(button))

        assert left >= box["left"] and right <= box["right"],
               "expected #{button} within the modal box #{box["left"]}..#{box["right"]}, got #{left}..#{right}"
      end

      # A real click (actionability-checked): the backdrop must not intercept it.
      session
      |> click("#bulk-move-keep")
      |> refute_has("#bulk-move-modal")

      assert Enum.map([a, b, c], &Hamaca.Repo.get!(Schemas.Card, &1.id).stage_id) == [plan.id, plan.id, code.id]
    end
  end

  defp open_map(conn, board) do
    conn
    |> visit("/dev/login")
    |> assert_has("body .phx-connected")
    |> visit("/board/#{board.slug}/story-map")
    |> assert_has("body .phx-connected")
    |> assert_has("#story-map-grid")
  end

  # A real mouse click with Shift held — PhoenixTest's click/2 has no modifier option, so this
  # drives the frame directly, as the other browser tests do.
  defp shift_click(session, ref) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, _} = Frame.click(frame_id, selector: "#story-map-card-#{ref}", modifiers: ["Shift"], timeout: 2_000)
    end)
  end

  defp rect_js(selector) do
    """
    (() => {
      const r = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect();
      return {left: r.left, right: r.right, width: r.width};
    })()
    """
  end

  # Evaluates a JS expression in the page and returns its value.
  defp measure(session, expression) do
    parent = self()

    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(parent, {:measured, value})
    end)

    assert_received {:measured, value}
    value
  end
end
