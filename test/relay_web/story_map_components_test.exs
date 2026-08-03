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

  defp grid(draft \\ nil) do
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
      ],
      draft
    )
  end

  # One activity whose only column is the `— No task yet` placeholder, holding a task-less card:
  # NOT `bare?` (that is `empty_activity_grid/1`), and the case the artboard gives a strong
  # (not dashed) header border.
  defp no_task_cards_grid do
    activity = %StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1}
    releases = [%Release{id: 100, board_id: 1, name: "MVP", position: 1}]

    StoryMapGrid.build([activity], [], releases, [card(1, story_activity_id: 1, release_id: 100)])
  end

  # One activity with nothing under it at all — no tasks, no task-less cards. This is the
  # artboard's `bare = !ntCount` (line ~450): the placeholder invites the first task.
  defp empty_activity_grid(draft \\ nil) do
    activity = %StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1}
    releases = [%Release{id: 100, board_id: 1, name: "MVP", position: 1}]

    StoryMapGrid.build([activity], [], releases, [], draft)
  end

  defp grid_html(grid \\ nil, draft \\ nil, draft_name \\ "") do
    render_component(&StoryMapComponents.story_map/1,
      grid: grid || grid(),
      board: board(),
      stages: stages(),
      stalled_ids: MapSet.new(),
      draft: draft,
      draft_name: draft_name
    )
  end

  # The `style` of one element, so a border assertion is anchored to the element it is about.
  defp style_of(html, selector) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute("style")
    |> List.first()
    |> Kernel.||("")
  end

  # Whether `selector` matches anything — the tag-sensitive companion to `style_of/2`, used to
  # prove the bare placeholder header is a real <button> rather than a labelled <div>.
  defp matches?(html, selector) do
    html |> LazyHTML.from_fragment() |> LazyHTML.query(selector) |> LazyHTML.attribute("id") != []
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

    test "a checklist with nothing ticked is 0% and the badge stays bare" do
      unstarted = card(1, sub_tasks: [%SubTask{id: 1, title: "a", done: false, position: 0}])

      face = StoryMapComponents.card_face(unstarted, board(), stages(), MapSet.new())

      # `Cards.sub_task_pct/1` is right to answer 0 (the drawer bar needs it); the artboard
      # treats 0 as absent — `stageText: c.pct ? … : c.stage`, line ~385.
      assert face.pct == 0
      assert face.badge == "CODE"
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

    test "a 0% card renders no bar — the artboard's `hasBar: full && !!c.pct`, line ~386" do
      html =
        render_component(&StoryMapComponents.story_map_card/1,
          id: "story-map-card-RLY4",
          ref: "RLY4",
          title: "Checklist created, nothing ticked",
          badge: "CODE",
          hue: :violet,
          pct: 0
        )

      refute html =~ "story-map-card-bar"
      refute html =~ "width:0%"
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

      # Anchored to the elements themselves: the bare `=~` forms passed even with the
      # `last_of_activity?` branches deleted, because the corner, lane rail and band all emit
      # the strong border unconditionally.
      no_task = style_of(html, "#story-map-no-task-1")
      assert no_task =~ "border-right:1px dashed oklch(0.86 0.01 255)"
      assert no_task =~ "background:oklch(0.978 0.004 255)"

      assert style_of(html, "#story-map-task-10") =~ "border-right:2px solid oklch(0.83 0.02 255)"
    end

    test "an activity with no tasks: its one column is the activity boundary, so strong" do
      # Artboard line ~456: `border-right:'+(tasks.length ? '1px dashed …' : GL_STRONG)`, with
      # `lastOfAct:!tasks.length` on line ~453. A zero-task activity is the normal shape for a
      # board just starting on the map.
      html = grid_html(no_task_cards_grid())

      assert style_of(html, "#story-map-no-task-1") =~
               "border-right:2px solid oklch(0.83 0.02 255)"

      # The body cell stays dashed — the artboard's cell branch (line ~524) has no such
      # condition.
      assert style_of(html, "#story-map-cell-nt-1-r-100") =~
               "border-right:1px dashed oklch(0.86 0.01 255)"
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

  describe "RE263 — the add-activity affordance" do
    test "a 58px trailing column pinned past the last band, holding the artboard's dashed ＋" do
      html = grid_html()

      # colTemplate ends ' 58px' (artboard line ~492); rowsTemplate ends ' 44px' (line ~493).
      assert html =~ "grid-template-columns:128px 156px 156px 58px"
      assert html =~ "grid-template-rows:56px 40px auto 44px"

      button = style_of(html, "#story-map-add-activity")
      assert button =~ "width:34px;height:34px"
      assert button =~ "border-radius:9px"
      assert button =~ "border:1px dashed oklch(0.82 0.01 255)"
      assert button =~ "font-size:15px"
      assert html =~ ~s(title="Add activity")
      assert html =~ ~s(phx-click="story_map_add_activity")
    end

    test "the trailing cell spans both header rows, past the last column (artboard addActStyle)" do
      html = grid_html()

      # Two columns of grid content, so the add-activity cell is grid-column 4 (1 = the rail).
      assert html =~ "grid-column:4;grid-row:1 / span 2;position:sticky;top:0;z-index:22;"
      assert html =~ "background:oklch(0.965 0.006 255);border-bottom:1px solid oklch(0.92 0.006 255)"
    end

    test "with the :activity draft open the column widens to 156px and the ＋ becomes the input" do
      html = grid_html(nil, :activity, "Ship")

      assert html =~ "grid-template-columns:128px 156px 156px 156px"
      refute html =~ ~s(id="story-map-add-activity")
      assert html =~ ~s(id="story-map-draft-input")
      assert html =~ ~s(placeholder="Activity name… ↵")
      assert html =~ ~s(value="Ship")
    end
  end

  describe "RE263 — the add-release affordance" do
    test "a dashed ＋ Release button in a row directly below the last swimlane label" do
      html = grid_html()

      # One lane, so the add-release row is grid-row 4 (artboard addRelStyle, line ~512).
      assert html =~ "grid-column:1;grid-row:4;position:sticky;left:0;z-index:16;"
      assert html =~ "border-top:1px solid oklch(0.92 0.006 255)"

      button = style_of(html, "#story-map-add-release")
      assert button =~ "border:1px dashed oklch(0.85 0.008 255)"
      assert button =~ "border-radius:8px"
      assert button =~ "font-size:11.5px;font-weight:600"
      assert button =~ "padding:4px 9px;width:100%"
      assert html =~ "＋ Release"
      assert html =~ ~s(phx-click="story_map_add_release")
    end

    test "with the :release draft open the button becomes the input" do
      html = grid_html(nil, :release, "Someday")

      refute html =~ ~s(id="story-map-add-release")
      assert html =~ ~s(id="story-map-draft-input")
      assert html =~ ~s(placeholder="Release name… ↵")
      assert html =~ ~s(value="Someday")
    end
  end

  describe "RE263 — the add-task affordances" do
    test "the activity header's second line carries a spacer and a 12px ＋ (artboard iconStyle)" do
      html = grid_html()

      assert style_of(html, "#story-map-add-task-1") == "font-size:12px;color:oklch(0.55 0.02 255);"
      assert html =~ ~s(title="Add task")
      assert html =~ ~s(phx-click="story_map_add_task")
      assert html =~ ~s(phx-value-activity-id="1")
      assert html =~ ~s(<span style="flex:1;">)
    end

    test "a bare placeholder header reads ＋ Add task, is a button and is clickable" do
      html = grid_html(empty_activity_grid())

      # A real <button>, not the <div> a labelled column renders — the WHOLE header is the
      # affordance (artboard line ~451, `onRename: bare ? (()=>this.addTask(actId)) : …`).
      assert matches?(html, "button#story-map-no-task-1")
      assert html =~ "＋ Add task"
      refute html =~ "— No task yet"
      assert style_of(html, "#story-map-no-task-1") =~ "cursor:pointer;"
      assert html =~ ~s(phx-value-activity-id="1")
    end

    test "a placeholder holding task-less cards still reads — No task yet and is not a button" do
      html = grid_html()

      assert html =~ "— No task yet"
      refute html =~ "＋ Add task"
      refute matches?(html, "button#story-map-no-task-1")
      refute style_of(html, "#story-map-no-task-1") =~ "cursor:pointer;"
    end

    test "the draft column's header holds the input and its body cells are empty and dashed" do
      html = grid_html(grid({:task, 1}), {:task, 1}, "Watch it live")

      assert html =~ ~s(id="story-map-draft-1")
      assert html =~ ~s(id="story-map-draft-input")
      assert html =~ ~s(placeholder="Task name… ↵")
      assert html =~ ~s(value="Watch it live")

      cell = style_of(html, "#story-map-cell-draft-1-r-100")
      assert cell =~ "border-right:1px dashed oklch(0.86 0.01 255)"
      assert cell =~ "background:oklch(0.978 0.004 255)"
    end

    test "on an activity with nothing under it the draft replaces the ＋ Add task placeholder" do
      html = grid_html(empty_activity_grid({:task, 1}), {:task, 1}, "")

      assert html =~ ~s(id="story-map-draft-1")
      refute html =~ ~s(id="story-map-no-task-1")
      refute html =~ "＋ Add task"
    end
  end

  describe "inline_name_input/1 — the shared editor RE261 reuses for rename" do
    test "one autofocused input in a form, with the artboard's inputStyle and all three events" do
      html =
        render_component(&StoryMapComponents.inline_name_input/1,
          id: "story-map-draft-input",
          value: "Onboard",
          placeholder: "Activity name… ↵",
          submit: "story_map_draft_submit",
          change: "story_map_draft_change",
          cancel: "story_map_draft_cancel"
        )

      assert html =~ ~s(id="story-map-draft-input-form")
      assert html =~ ~s(phx-submit="story_map_draft_submit")
      assert html =~ ~s(phx-change="story_map_draft_change")
      assert html =~ ~s(phx-blur="story_map_draft_cancel")
      assert html =~ ~s(phx-keydown="story_map_draft_cancel")
      assert html =~ ~s(phx-key="Escape")
      assert html =~ ~s(phx-hook="InlineNameInput")
      assert html =~ ~s(name="name")
      assert html =~ ~s(value="Onboard")
      assert html =~ ~s(placeholder="Activity name… ↵")

      # Artboard inputStyle, line ~404.
      style = style_of(html, "#story-map-draft-input")
      assert style =~ "border:1.5px solid oklch(0.6 0.14 250)"
      assert style =~ "border-radius:5px"
      assert style =~ "padding:2px 5px"
      assert style =~ "font-size:12px;font-weight:600"
      assert style =~ "flex:1;min-width:0"
    end

    test "hook: nil renders without the hook, for storybook" do
      html =
        render_component(&StoryMapComponents.inline_name_input/1,
          id: "demo",
          hook: nil,
          submit: "s",
          change: "c",
          cancel: "x"
        )

      refute html =~ "phx-hook"
      assert html =~ ~s(id="demo")
    end
  end

  describe "RE263 — the empty panel invites the first activity" do
    test "renders a primary button instead of the coming-soon copy" do
      html = render_component(&StoryMapComponents.story_map_empty/1, [])

      assert html =~ ~s(id="story-map-empty-add-activity")
      assert html =~ "Add your first activity"
      assert html =~ ~s(phx-click="story_map_add_activity")
      refute html =~ "coming soon"
    end

    test "with the :activity draft open the panel holds the input instead" do
      html = render_component(&StoryMapComponents.story_map_empty/1, draft: :activity, draft_name: "Onboard")

      refute html =~ ~s(id="story-map-empty-add-activity")
      assert html =~ ~s(id="story-map-draft-input")
      assert html =~ ~s(value="Onboard")
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
