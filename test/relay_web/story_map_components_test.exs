defmodule RelayWeb.StoryMapComponentsTest do
  @moduledoc """
  RE264 — the story map's rendering, pinned to `docs/designs/Relay Story Map.dc.html`. The
  assertions name the artboard's concrete values on purpose: "matches the mockup" is only a
  deliverable if it is checked.
  """
  use ExUnit.Case, async: true

  import Phoenix.LiveViewTest

  alias RelayWeb.CoreComponents
  alias RelayWeb.StoryMapComponents
  alias RelayWeb.StoryMapGrid
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Release
  alias Schemas.Stage
  alias Schemas.StoryActivity
  alias Schemas.StoryTask
  alias Schemas.SubTask

  # Every helper lives at module level — a `defp` inside a `describe` block compiles, but
  # splitting clauses of one name across blocks produces out-of-order-definition warnings, and
  # warnings are errors in this suite.
  defp board, do: %Board{id: 1, key: "RLY", slug: "my-board", name: "My board"}

  defp stages do
    [
      %Stage{id: 1, board_id: 1, name: "Spec", position: 1, category: :planning, type: :planning},
      %Stage{id: 2, board_id: 1, name: "Code", position: 2, category: :in_progress, type: :work},
      %Stage{id: 3, board_id: 1, name: "Done", position: 3, category: :complete, type: :done}
    ]
  end

  defp card(id, attrs) do
    struct(
      %Card{
        id: id,
        board_id: 1,
        ref_number: id,
        title: "Card #{id}",
        stage_id: 2,
        status: :ready,
        owners: [],
        sub_tasks: []
      },
      attrs
    )
  end

  defp grid do
    activity = %StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1}
    task = %StoryTask{id: 10, board_id: 1, story_activity_id: 1, name: "Sign in", position: 1}
    releases = [%Release{id: 100, board_id: 1, name: "MVP", position: 1}]

    StoryMapGrid.build(
      [activity],
      [task],
      releases,
      [
        card(1, story_activity_id: 1, story_task_id: 10, release_id: 100),
        card(2, story_activity_id: 1, release_id: 100)
      ]
    )
  end

  defp grid_html do
    render_component(&StoryMapComponents.story_map/1,
      grid: grid(),
      board: board(),
      stages: stages(),
      stalled_ids: MapSet.new()
    )
  end

  defp tray(open) do
    render_component(&StoryMapComponents.unmapped_tray/1,
      cards: [card(7, []), card(8, [])],
      board: board(),
      stages: stages(),
      stalled_ids: MapSet.new(),
      open: open
    )
  end

  describe "card_face/4 — the two derivations, written once" do
    test "labels the badge with the card's stage name, upcased" do
      face = StoryMapComponents.card_face(card(1, []), board(), stages(), MapSet.new())

      assert face.badge == "CODE"
      assert face.hue == :violet
      assert face.avatar == :owners
      assert face.ref == "RLY1"
      assert face.id == "story-map-card-RLY1"
    end

    test "a needs_input card is NEEDS YOU, amber, with the ! disc" do
      face =
        StoryMapComponents.card_face(card(1, status: :needs_input), board(), stages(), MapSet.new())

      assert face.badge == "NEEDS YOU"
      assert face.hue == :amber
      assert face.avatar == :bang
    end

    test "a stalled card is STALLED and amber" do
      face = StoryMapComponents.card_face(card(1, []), board(), stages(), MapSet.new([1]))

      assert face.badge == "STALLED"
      assert face.hue == :amber
    end

    test "a card at the terminal stage is green, with the ✓ disc" do
      face =
        StoryMapComponents.card_face(card(1, stage_id: 3), board(), stages(), MapSet.new())

      assert face.done
      assert face.hue == :green
      assert face.avatar == :check
      assert face.badge == "DONE"
    end

    test "a planning stage is blue and an unstarted/complete one is neutral" do
      assert StoryMapComponents.card_face(card(1, stage_id: 1), board(), stages(), MapSet.new()).hue ==
               :blue

      unstarted = %Stage{id: 9, board_id: 1, name: "Backlog", position: 0, category: :unstarted, type: :queue}

      assert StoryMapComponents.card_face(
               card(1, stage_id: 9),
               board(),
               [unstarted | stages()],
               MapSet.new()
             ).hue == :neutral
    end

    test "the percentage is the card's sub-task progress, appended to the badge" do
      with_tasks =
        card(1,
          sub_tasks: [
            %SubTask{id: 1, title: "a", done: true, position: 0},
            %SubTask{id: 2, title: "b", done: false, position: 1}
          ]
        )

      face = StoryMapComponents.card_face(with_tasks, board(), stages(), MapSet.new())

      assert face.pct == 50
      assert face.badge == "CODE · 50%"
    end
  end

  describe "story_map_card/1 — the artboard's full-zoom face" do
    test "renders the ref, title, mono badge and the 3px bottom bar with the artboard's tokens" do
      html =
        render_component(&StoryMapComponents.story_map_card/1,
          id: "story-map-card-RLY1",
          ref: "RLY1",
          title: "Migrate 40 blog posts",
          badge: "CODE · 62%",
          hue: :violet,
          pct: 62
        )

      assert html =~ ~s(id="story-map-card-RLY1")
      assert html =~ "Migrate 40 blog posts"
      assert html =~ "CODE · 62%"
      # card shell — artboard cardVM() full branch, lines ~332-334
      assert html =~ "background:oklch(0.965 0.028 292)"
      assert html =~ "border:1px solid oklch(0.9 0.04 292)"
      assert html =~ "border-radius:9px"
      assert html =~ "padding:9px 10px"
      # stage badge — artboard stageColor(), lines ~299-304
      assert html =~ "background:oklch(0.95 0.035 292)"
      assert html =~ "color:oklch(0.48 0.14 292)"
      assert html =~ "font-size:8.5px"
      # progress bar — artboard barStyle, line ~346
      assert html =~ "height:3px;width:62%;background:oklch(0.56 0.16 292)"
      # the click contract BoardLive already handles
      assert html =~ ~s(phx-click="select_card")
      assert html =~ ~s(phx-value-ref="RLY1")
    end

    test "a done card gets the green left border and reduced opacity, and no bar" do
      html =
        render_component(&StoryMapComponents.story_map_card/1,
          id: "story-map-card-RLY2",
          ref: "RLY2",
          title: "Dark mode polish",
          badge: "DONE",
          hue: :green,
          done: true,
          avatar: :check
        )

      assert html =~ "background:oklch(0.97 0.015 150)"
      assert html =~ "opacity:0.8"
      assert html =~ "border-left:3px solid oklch(0.6 0.13 155)"
      assert html =~ "✓"
      refute html =~ "oklch(0.56 0.16 292)"
    end

    test "a needs-input card gets the amber ! disc" do
      html =
        render_component(&StoryMapComponents.story_map_card/1,
          id: "story-map-card-RLY3",
          ref: "RLY3",
          title: "Rewrite the onboarding tooltips",
          badge: "NEEDS YOU",
          hue: :amber,
          avatar: :bang
        )

      assert html =~ "background:oklch(0.72 0.13 65)"
      assert html =~ "!"
    end
  end

  describe "story_map/1 — the grid chrome" do
    test "renders the sticky corner, the bands, the headers and the lane rail" do
      html = grid_html()

      assert html =~ ~s(id="story-map-grid")
      assert html =~ "RELEASE ↓"
      # corner + grid geometry — artboard lines ~424, ~426
      assert html =~ "grid-template-columns:128px 156px 156px"
      assert html =~ "grid-template-rows:56px 40px auto"
      assert html =~ "grid-row:1 / span 2"
      assert html =~ ~s(id="story-map-activity-1")
      assert html =~ "Onboard &amp; access"
      assert html =~ ~s(id="story-map-no-task-1")
      assert html =~ "— No task yet"
      assert html =~ ~s(id="story-map-task-10")
      assert html =~ "Sign in"
      assert html =~ ~s(id="story-map-release-100")
      assert html =~ "MVP"
      assert html =~ "2 cards"
    end

    test "the No task yet column is dashed and tinted, and the activity's last column is strong" do
      html = grid_html()

      assert html =~ "border-right:1px dashed oklch(0.86 0.01 255)"
      assert html =~ "background:oklch(0.978 0.004 255)"
      assert html =~ "border-right:2px solid oklch(0.83 0.02 255)"
    end

    test "each card renders in the cell its assignment implies" do
      html = grid_html()

      assert html =~ ~s(id="story-map-cell-t-10-r-100")
      assert html =~ ~s(id="story-map-cell-nt-1-r-100")
      assert html =~ ~s(id="story-map-card-RLY1")
      assert html =~ ~s(id="story-map-card-RLY2")
    end
  end

  describe "unmapped_tray/1" do
    test "open: 214px, the label, the count pill, the one-line helper and the card list" do
      html = tray(true)

      assert html =~ ~s(id="story-map-tray")
      assert html =~ "width:214px"
      assert html =~ "UNMAPPED"
      assert html =~ ~s(id="story-map-tray-count")
      assert html =~ ">2<"
      assert html =~ "No activity yet."
      refute html =~ "Drag onto the map"
      assert html =~ ~s(id="story-map-tray-card-RLY7")
      assert html =~ ~s(id="story-map-tray-card-RLY8")
      # tray card — artboard line ~472
      assert html =~ "border-left:3px solid oklch(0.62 0.12"
      assert html =~ ~s(id="story-map-tray-toggle")
      assert html =~ ~s(phx-click="toggle_story_map_tray")
    end

    test "collapsed: a 42px vertical rail keeping the chevron, the count and the label" do
      html = tray(false)

      assert html =~ "width:42px"
      assert html =~ "writing-mode:vertical-rl"
      assert html =~ ~s(id="story-map-tray-count")
      refute html =~ "No activity yet."
      refute html =~ ~s(id="story-map-tray-card-RLY7")
    end
  end

  describe "story_map_empty/1" do
    test "explains the backbone and the swimlanes" do
      html = render_component(&StoryMapComponents.story_map_empty/1, [])

      assert html =~ ~s(id="story-map-empty")
      assert html =~ "Activities"
      assert html =~ "Tasks"
      assert html =~ "Releases"
    end
  end

  describe "board_view_tabs/1" do
    test "renders both segments with the artboard's segmented-control treatment" do
      html =
        render_component(&CoreComponents.board_view_tabs/1,
          board_slug: "my-board",
          active: :story_map
        )

      assert html =~ ~s(id="board-view-tabs")
      assert html =~ ~s(id="board-view-tab-board")
      assert html =~ ~s(id="board-view-tab-story-map")
      assert html =~ ~s(href="/board/my-board")
      assert html =~ ~s(href="/board/my-board/story-map")
      # container + active segment — artboard lines ~37-39
      assert html =~ "background:oklch(0.955 0.006 255);border-radius:8px;padding:2px"
      assert html =~ "box-shadow:0 1px 2px oklch(0 0 0/0.08)"
      assert html =~ "color:oklch(0.32 0.02 255)"
      assert html =~ ~s(aria-current="page")
    end

    test "marks the board segment active on the board view" do
      html =
        render_component(&CoreComponents.board_view_tabs/1, board_slug: "my-board", active: :board)

      assert html =~ ~r/id="board-view-tab-board"[^>]*aria-current="page"/
    end
  end
end
