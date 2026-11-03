defmodule HamacaWeb.Browser.StoryMapDropLineTest do
  @moduledoc """
  Real-browser (Playwright) coverage for RE272: while anything on the story map is dragged, ONE
  3px line in `#story-map-drop-layer` shows exactly where it will land, and the pointer's half of
  a hovered header decides the side the drop pushes. The cell tint and the header ring are gone.

  `Phoenix.LiveViewTest` never runs `StoryMapDnD`, and Playwright's `drag/3` only exposes the
  FINISHED drop — so to hold a drag mid-hover these tests dispatch synthetic `DragEvent`s from
  `Frame.evaluate/2` (one shared `DataTransfer` per drag, kept on `window`) and read the line's
  geometry with `getBoundingClientRect` / `getComputedStyle`. The two "real drop" scenarios use
  `drag/3` with a Playwright `targetPosition` so the drop point is the one the hover measured.
  """
  use PhoenixTest.Playwright.Case, async: false

  alias Hamaca.Accounts
  alias Hamaca.Boards
  alias Hamaca.Cards
  alias Hamaca.Repo
  alias Hamaca.StoryMap
  alias PlaywrightEx.Frame

  @moduletag :playwright

  @line "#story-map-drop-layer .story-map-drop-line"

  setup %{conn: conn} do
    user = Accounts.ensure_dev_user!()
    {:ok, board} = Boards.create_board(user, %{name: "Story map drop line"})
    {:ok, onboard} = StoryMap.create_activity(board, %{name: "Onboard & access", position: 1})
    {:ok, plan} = StoryMap.create_activity(board, %{name: "Plan the backlog", position: 2})
    {:ok, sign_in} = StoryMap.create_step(onboard, %{name: "Sign in", position: 1})
    {:ok, organize} = StoryMap.create_step(plan, %{name: "Organize cards", position: 1})
    [mvp, fast_follow, later] = StoryMap.list_releases(board)

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

    %{
      session: session,
      board: board,
      onboard: onboard,
      plan: plan,
      sign_in: sign_in,
      organize: organize,
      mvp: mvp,
      fast_follow: fast_follow,
      later: later,
      a: Cards.ref(board, a),
      b: Cards.ref(board, b),
      c: Cards.ref(board, c)
    }
  end

  describe "a card drag" do
    test "shows a 3px primary horizontal line between the two cards, no tint", ctx do
      cell = "#story-map-cell-s-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"

      dispatch(ctx.session, "dragstart", card(ctx.c))
      dispatch(ctx.session, "dragover", card(ctx.a), y: "r.top + 0.75 * r.height")

      assert visible_lines(ctx.session, ".story-map-drop-line--h") == 1
      line = line_rect(ctx.session)
      a = rect(ctx.session, card(ctx.a))
      b = rect(ctx.session, card(ctx.b))
      centre = line["top"] + line["height"] / 2
      assert centre > a["bottom"] and centre < b["top"]
      assert_in_delta centre, (a["bottom"] + b["top"]) / 2, 2

      assert computed(ctx.session, @line, "height") == "3px"
      assert computed(ctx.session, @line, "backgroundColor") == primary_color(ctx.session)
      assert computed(ctx.session, cell, "boxShadow") == "none"
      refute has_class?(ctx.session, cell, "drag-over")
    end

    test "dropping where the line shows lands the card between them", ctx do
      cell = "#story-map-cell-s-#{ctx.sign_in.id}-r-#{ctx.mvp.id}"

      dispatch(ctx.session, "dragstart", card(ctx.c))
      dispatch(ctx.session, "dragover", card(ctx.a), y: "r.top + 0.75 * r.height")
      dispatch(ctx.session, "drop", card(ctx.a), y: "r.top + 0.75 * r.height")
      dispatch(ctx.session, "dragend", card(ctx.c))

      assert_has(ctx.session, ~s{#{cell} .story-map-card:nth-child(2)[data-ref="#{ctx.c}"]})
      assert card_order(ctx.session, cell) == [ctx.a, ctx.c, ctx.b]
    end

    test "over the tray shows no line and tints the tray until dragend", ctx do
      dispatch(ctx.session, "dragstart", card(ctx.c))
      dispatch(ctx.session, "dragover", "#story-map-tray")

      assert visible_lines(ctx.session) == 0
      assert has_class?(ctx.session, "#story-map-tray", "drag-over")

      dispatch(ctx.session, "dragend", card(ctx.c))

      refute has_class?(ctx.session, "#story-map-tray", "drag-over")
      assert visible_lines(ctx.session) == 0
    end
  end

  describe "a step drag" do
    test "the right half of the last step draws a full-height line on its right edge", ctx do
      organize = "#story-map-step-#{ctx.organize.id}"

      dispatch(ctx.session, "dragstart", "#story-map-step-#{ctx.sign_in.id}")
      dispatch(ctx.session, "dragover", organize, x: "r.right - 5")

      assert visible_lines(ctx.session, ".story-map-drop-line--v") == 1
      line = line_rect(ctx.session)
      grid = rect(ctx.session, "#story-map-grid")
      assert_in_delta line["left"] + line["width"] / 2, rect(ctx.session, organize)["right"], 2
      assert_in_delta line["top"], grid["top"], 2
      assert_in_delta line["bottom"], lane_bottom(ctx.session, "r:#{ctx.later.id}"), 2
      assert computed(ctx.session, organize, "boxShadow") == "none"
    end

    test "a real drop on that right half makes it the activity's last step", ctx do
      organize = "#story-map-step-#{ctx.organize.id}"
      %{"width" => width} = rect(ctx.session, organize)
      before = attribute(ctx.session, "#story-map-step-#{ctx.sign_in.id}", "style")

      ctx.session
      |> drag("#story-map-step-#{ctx.sign_in.id}",
        to: organize,
        playwright: [target_position: %{x: width - 5, y: 5}]
      )
      |> refute_has(~s(#story-map-step-#{ctx.sign_in.id}[style="#{before}"]))

      moved = Repo.get!(Schemas.StoryStep, ctx.sign_in.id)
      assert moved.story_activity_id == ctx.plan.id
      assert moved.position == 2
    end

    test "hovering its own header shows no line and refuses the drop", ctx do
      own = "#story-map-step-#{ctx.sign_in.id}"

      dispatch(ctx.session, "dragstart", own)
      refute dispatch(ctx.session, "dragover", own)
      assert visible_lines(ctx.session) == 0
      dispatch(ctx.session, "dragend", own)

      step = Repo.get!(Schemas.StoryStep, ctx.sign_in.id)
      assert {step.story_activity_id, step.position} == {ctx.onboard.id, 1}
    end
  end

  describe "an activity drag" do
    test "the pointer's half of the hovered activity picks its left or right edge", ctx do
      onboard = "#story-map-activity-#{ctx.onboard.id}"
      %{"left" => left, "right" => right} = rect(ctx.session, onboard)

      dispatch(ctx.session, "dragstart", "#story-map-activity-#{ctx.plan.id}")

      dispatch(ctx.session, "dragover", onboard, x: "r.left + 0.25 * r.width")
      assert_in_delta line_centre_x(ctx.session), left, 2

      dispatch(ctx.session, "dragover", onboard, x: "r.left + 0.75 * r.width")
      assert_in_delta line_centre_x(ctx.session), right, 2
    end

    test "over a step header it measures the step's whole activity", ctx do
      dispatch(ctx.session, "dragstart", "#story-map-activity-#{ctx.onboard.id}")
      dispatch(ctx.session, "dragover", "#story-map-step-#{ctx.organize.id}", x: "r.left + 0.25 * r.width")

      assert_in_delta line_centre_x(ctx.session), rect(ctx.session, "#story-map-activity-#{ctx.plan.id}")["left"], 2
    end
  end

  describe "a release drag" do
    test "the bottom half of the last release draws a full-width line along its bottom", ctx do
      later = "#story-map-release-#{ctx.later.id}"

      dispatch(ctx.session, "dragstart", "#story-map-release-#{ctx.mvp.id}")
      dispatch(ctx.session, "dragover", later, y: "r.top + 0.75 * r.height")

      assert visible_lines(ctx.session, ".story-map-drop-line--h") == 1
      line = line_rect(ctx.session)
      assert_in_delta line["left"], rect(ctx.session, "#story-map-grid")["left"], 2
      assert_in_delta line["right"], rightmost_activity_right(ctx.session), 2
      assert_in_delta line["top"] + line["height"] / 2, lane_bottom(ctx.session, "r:#{ctx.later.id}"), 2

      dispatch(ctx.session, "drop", later, y: "r.top + 0.75 * r.height")
      dispatch(ctx.session, "dragend", "#story-map-release-#{ctx.mvp.id}")

      # `lane_label_style/1` puts lane i at grid-row i + 3, so the last of three is row 5.
      assert_has(ctx.session, ~s(#story-map-release-#{ctx.mvp.id}[style*="grid-row:5;"]))
      assert Enum.map(StoryMap.list_releases(ctx.board), & &1.name) == ["Fast follow", "Later", "MVP"]
    end

    test "over an activity header shows no line and refuses the drop", ctx do
      dispatch(ctx.session, "dragstart", "#story-map-release-#{ctx.mvp.id}")
      refute dispatch(ctx.session, "dragover", "#story-map-activity-#{ctx.onboard.id}")
      assert visible_lines(ctx.session) == 0
    end
  end

  # The grid is `align-items:start`, so a release label is only as tall as its text while its lane
  # is as tall as its tallest cell. Piling cards into one cell makes the lane far taller than its
  # label: every line must still sit on the LANE's boundary, never the label's.
  describe "a lane taller than its label" do
    setup ctx do
      pile!(ctx, ctx.organize, ctx.fast_follow, 4)
      pile!(ctx, ctx.sign_in, ctx.later, 4)

      session =
        ctx.session
        |> visit("/board/#{ctx.board.slug}/story-map")
        |> assert_has("body .phx-connected")
        |> assert_has("#story-map-cell-s-#{ctx.sign_in.id}-r-#{ctx.later.id} .story-map-card:nth-child(4)")

      %{session: session}
    end

    test "a release 'after' line sits on the lane boundary, not the label's bottom", ctx do
      fast_follow = "#story-map-release-#{ctx.fast_follow.id}"
      later = "#story-map-release-#{ctx.later.id}"
      lane_bottom = lane_bottom(ctx.session, "r:#{ctx.fast_follow.id}")
      assert lane_bottom > rect(ctx.session, fast_follow)["bottom"] + 40

      dispatch(ctx.session, "dragstart", "#story-map-release-#{ctx.mvp.id}")
      dispatch(ctx.session, "dragover", fast_follow, y: "r.top + 0.9 * r.height")

      line = line_rect(ctx.session)
      centre = line["top"] + line["height"] / 2
      assert_in_delta centre, lane_bottom, 2
      assert_in_delta centre, rect(ctx.session, later)["top"], 2
    end

    test "the last release's 'after' line runs along the map's bottom edge", ctx do
      later = "#story-map-release-#{ctx.later.id}"
      lane_bottom = lane_bottom(ctx.session, "r:#{ctx.later.id}")
      assert lane_bottom > rect(ctx.session, later)["bottom"] + 40

      dispatch(ctx.session, "dragstart", "#story-map-release-#{ctx.mvp.id}")
      dispatch(ctx.session, "dragover", later, y: "r.top + 0.9 * r.height")

      line = line_rect(ctx.session)
      assert_in_delta line["top"] + line["height"] / 2, lane_bottom, 2
    end

    test "a vertical step line reaches the last lane's bottom", ctx do
      organize = "#story-map-step-#{ctx.organize.id}"

      dispatch(ctx.session, "dragstart", "#story-map-step-#{ctx.sign_in.id}")
      dispatch(ctx.session, "dragover", organize, x: "r.right - 5")

      assert_in_delta line_rect(ctx.session)["bottom"], lane_bottom(ctx.session, "r:#{ctx.later.id}"), 2
    end
  end

  # --- helpers ------------------------------------------------------------------------------

  defp card(ref), do: ~s(.story-map-card[data-ref="#{ref}"])

  defp pile!(ctx, step, release, n) do
    [backlog | _rest] = Boards.get_board!(Accounts.ensure_dev_user!(), ctx.board.slug).stages

    for i <- 1..n do
      {:ok, card} = Cards.create_card(backlog, %{title: "Pile #{step.name} #{i}"})
      {:ok, _} = StoryMap.assign_card(card, %{story_step_id: step.id, release_id: release.id})
    end
  end

  # A lane's real bottom: the lowest of its label and body cells (all carry `data-lane`) — the
  # row is as tall as its tallest item.
  defp lane_bottom(session, lane_key) do
    js(session, """
    (() => Math.max(...Array.from(document.querySelectorAll(
      '#story-map-grid [data-lane=#{Jason.encode!(lane_key)}]'
    )).map(el => el.getBoundingClientRect().bottom)))()
    """)
  end

  # Dispatches one synthetic DragEvent on `selector`'s element at a point inside its rect `r`
  # (`x` / `y` are JS expressions over `r`, defaulting to its centre). A `dragstart` begins a
  # fresh DataTransfer the rest of the drag shares.
  #
  # Returns `defaultPrevented` as `document` sees it on the way up: LiveView's own WINDOW-level
  # listener (`live_socket.js`, `this.on("dragover", e => e.preventDefault())`) runs after it and
  # prevents every dragover on the page, so reading it after dispatch would say nothing about
  # whether StoryMapDnD did.
  defp dispatch(session, type, selector, opts \\ []) do
    x = Keyword.get(opts, :x, "r.left + r.width / 2")
    y = Keyword.get(opts, :y, "r.top + r.height / 2")

    js(session, """
    (() => {
      const el = document.querySelector(#{Jason.encode!(selector)})
      if (!el) throw new Error("no element for " + #{Jason.encode!(selector)})
      const r = el.getBoundingClientRect()
      if (#{Jason.encode!(type)} === "dragstart") window.__smDataTransfer = new DataTransfer()
      const e = new DragEvent(#{Jason.encode!(type)}, {
        bubbles: true, cancelable: true, clientX: #{x}, clientY: #{y},
        dataTransfer: window.__smDataTransfer,
      })
      let prevented = null
      const record = ev => { if (ev === e) prevented = ev.defaultPrevented }
      document.addEventListener(e.type, record)
      el.dispatchEvent(e)
      document.removeEventListener(e.type, record)
      return prevented
    })()
    """)
  end

  defp visible_lines(session, modifier \\ "") do
    js(session, """
    (() => Array.from(document.querySelectorAll(#{Jason.encode!(@line <> modifier)}))
      .filter(el => !el.hidden && getComputedStyle(el).display !== "none").length)()
    """)
  end

  defp line_rect(session), do: rect(session, @line)

  defp line_centre_x(session) do
    line = line_rect(session)
    line["left"] + line["width"] / 2
  end

  defp rect(session, selector) do
    js(session, """
    (() => {
      const r = document.querySelector(#{Jason.encode!(selector)}).getBoundingClientRect()
      return {left: r.left, right: r.right, top: r.top, bottom: r.bottom, width: r.width, height: r.height}
    })()
    """)
  end

  defp rightmost_activity_right(session) do
    js(session, """
    (() => Math.max(...Array.from(document.querySelectorAll(
      '#story-map-grid [id^="story-map-activity-"], #story-map-grid [id^="story-map-stub-"]'
    )).map(el => el.getBoundingClientRect().right)))()
    """)
  end

  defp computed(session, selector, property) do
    js(
      session,
      "(() => getComputedStyle(document.querySelector(#{Jason.encode!(selector)}))[#{Jason.encode!(property)}])()"
    )
  end

  # The theme's primary as the browser resolves it, so the comparison survives a palette change.
  defp primary_color(session) do
    js(session, """
    (() => {
      const probe = document.createElement("div")
      probe.style.backgroundColor = "var(--color-primary)"
      document.body.appendChild(probe)
      const color = getComputedStyle(probe).backgroundColor
      probe.remove()
      return color
    })()
    """)
  end

  defp has_class?(session, selector, class) do
    js(
      session,
      "(() => document.querySelector(#{Jason.encode!(selector)}).classList.contains(#{Jason.encode!(class)}))()"
    )
  end

  defp attribute(session, selector, name) do
    js(
      session,
      "(() => document.querySelector(#{Jason.encode!(selector)}).getAttribute(#{Jason.encode!(name)}))()"
    )
  end

  defp card_order(session, cell) do
    js(
      session,
      "(() => Array.from(document.querySelectorAll(#{Jason.encode!(cell <> " .story-map-card")})).map(el => el.dataset.ref))()"
    )
  end

  defp js(session, expression) do
    unwrap(session, fn %{frame_id: frame_id} ->
      {:ok, value} = Frame.evaluate(frame_id, expression: expression, timeout: 2_000)
      send(self(), {:evaluated, value})
    end)

    receive do
      {:evaluated, value} -> value
    end
  end
end
