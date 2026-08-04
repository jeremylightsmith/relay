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
  alias RelayWeb.StoryMapFilter
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

  defp presence_person(id, name, email, avatar_url \\ nil) do
    %{user_id: id, name: name, email: email, avatar_url: avatar_url}
  end

  defp presence_dana, do: presence_person(1, "Dana Kim", "dana@acme.co")
  defp presence_mara, do: presence_person(2, "Mara Lopez", "mara@acme.co")

  defp presence_html(people, current_user_id \\ 1) do
    render_component(&StoryMapComponents.presence_stack/1,
      people: people,
      current_user_id: current_user_id
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
    test "the card face is draggable and carries its ref — the StoryMapDnD contract" do
      html =
        render_component(&StoryMapComponents.story_map_card/1,
          id: "story-map-card-RLY1",
          ref: "RLY1",
          title: "Add SSO",
          badge: "BACKLOG"
        )

      assert html =~ ~s(draggable="true")
      assert html =~ ~s(class="story-map-card")
      assert html =~ ~s(data-ref="RLY1")
    end

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
      assert html =~ "background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100))"
      assert html =~ "border:1px solid color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100))"
      assert html =~ "border-radius:9px"
      assert html =~ "padding:9px 10px"
      # stage badge — artboard stageColor(), lines ~299-304
      assert html =~ "background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100))"
      assert html =~ "color:color-mix(in oklab, var(--color-secondary) 75%, var(--color-base-content))"
      assert html =~ "font-size:8.5px"
      # progress bar — artboard barStyle, line ~346
      assert html =~ "height:3px;width:62%;background:var(--color-secondary)"
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

      assert html =~ "background:color-mix(in oklab, var(--color-success) 10%, var(--color-base-100))"
      assert html =~ "opacity:0.8"
      assert html =~ "border-left:3px solid var(--color-success)"
      assert html =~ "✓"
      refute html =~ "story-map-card-bar"
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

      assert html =~ "background:var(--color-warning)"
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

      assert no_task =~
               "border-right:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"

      assert no_task =~ "background:var(--color-base-200)"

      assert style_of(html, "#story-map-task-10") =~
               "border-right:2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100))"
    end

    test "an activity with no tasks: its one column is the activity boundary, so strong" do
      # Artboard line ~456: `border-right:'+(tasks.length ? '1px dashed …' : GL_STRONG)`, with
      # `lastOfAct:!tasks.length` on line ~453. A zero-task activity is the normal shape for a
      # board just starting on the map.
      html = grid_html(no_task_cards_grid())

      assert style_of(html, "#story-map-no-task-1") =~
               "border-right:2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100))"

      # The body cell stays dashed — the artboard's cell branch (line ~524) has no such
      # condition.
      assert style_of(html, "#story-map-cell-nt-1-r-100") =~
               "border-right:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"
    end

    test "each card renders in the cell its assignment implies" do
      html = grid_html()

      assert html =~ ~s(id="story-map-cell-t-10-r-100")
      assert html =~ ~s(id="story-map-cell-nt-1-r-100")
      assert html =~ ~s(id="story-map-card-RLY1")
      assert html =~ ~s(id="story-map-card-RLY2")
    end

    test "every body cell is a drop zone keyed by its column and lane" do
      html = grid_html()

      cell =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#story-map-cell-t-10-r-100")

      assert LazyHTML.attribute(cell, "class") == ["story-map-drop"]
      assert LazyHTML.attribute(cell, "data-column") == ["t:10"]
      assert LazyHTML.attribute(cell, "data-lane") == ["r:100"]

      no_task =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#story-map-cell-nt-1-r-100")

      assert LazyHTML.attribute(no_task, "data-column") == ["nt:1"]
    end
  end

  describe "unmapped_tray/1" do
    test "open: 214px, the label, the count pill, the one-line helper and the card list" do
      html = tray(true)

      assert html =~ ~s(id="story-map-tray")
      assert html =~ "width:214px"
      assert html =~ "UNMAPPED"
      assert html =~ ~s(id="story-map-tray-count")
      assert html =~ ~r/>\s*2\s*</
      # RE262 restores the artboard's full sentence (line ~91): dragging is real now.
      assert html =~ "No activity yet. Drag onto the map to place — or drop a card here to unmap it."
      assert html =~ ~s(id="story-map-tray-card-RLY7")
      assert html =~ ~s(id="story-map-tray-card-RLY8")
      # tray card — artboard line ~472
      assert html =~ "border-left:3px solid var(--color-secondary)"
      assert html =~ ~s(id="story-map-tray-toggle")
      assert html =~ ~s(phx-click="toggle_story_map_tray")
    end

    test "the tray is a drop zone and its cards are draggable" do
      html = tray(true)

      tray_el = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-tray")
      assert LazyHTML.attribute(tray_el, "class") == ["story-map-drop-tray"]

      card = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-tray-card-RLY7")
      assert LazyHTML.attribute(card, "draggable") == ["true"]
      assert LazyHTML.attribute(card, "data-ref") == ["RLY7"]
      # The same class the cell cards carry, so ONE hook selector covers both.
      assert LazyHTML.attribute(card, "class") == ["story-map-tray-card story-map-card"]
    end

    test "with nothing unmapped it still renders the drop rail, count 0 and the helper" do
      html =
        render_component(&StoryMapComponents.unmapped_tray/1,
          cards: [],
          board: board(),
          stages: stages(),
          stalled_ids: MapSet.new(),
          open: true
        )

      assert html =~ ~s(id="story-map-tray")
      assert html =~ ~s(class="story-map-drop-tray")
      assert html =~ ~s(id="story-map-tray-count")
      assert html =~ ~r/>\s*0\s*</
      assert html =~ "No activity yet. Drag onto the map to place — or drop a card here to unmap it."
    end

    test "collapsed: a 42px vertical rail keeping the chevron, the count and the label" do
      html = tray(false)

      assert html =~ "width:42px"
      assert html =~ "writing-mode:vertical-rl"
      assert html =~ ~s(id="story-map-tray-count")
      refute html =~ "No activity yet."
      refute html =~ ~s(id="story-map-tray-card-RLY7")
      # The rail is still a drop target — the artboard's onTrayDrop expands it.
      assert html =~ ~s(class="story-map-drop-tray")
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
      assert button =~ "border:1px dashed color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100))"
      assert button =~ "font-size:15px"
      assert html =~ ~s(title="Add activity")
      assert html =~ ~s(phx-click="story_map_add_activity")
    end

    test "the trailing cell spans both header rows, past the last column (artboard addActStyle)" do
      html = grid_html()

      # Two columns of grid content, so the add-activity cell is grid-column 4 (1 = the rail).
      assert html =~ "grid-column:4;grid-row:1 / span 2;position:sticky;top:0;z-index:22;"
      assert html =~ "background:var(--color-field-hover);border-bottom:1px solid var(--color-base-300)"
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
      assert html =~ "border-top:1px solid var(--color-base-300)"

      button = style_of(html, "#story-map-add-release")
      assert button =~ "border:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"
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

      assert style_of(html, "#story-map-add-task-1") ==
               "font-size:12px;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);"

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

      assert cell =~
               "border-right:1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"

      assert cell =~ "background:var(--color-base-200)"
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
      assert html =~ ~s(phx-click-away="story_map_draft_cancel")
      assert html =~ ~s(phx-keydown="story_map_draft_cancel")
      assert html =~ ~s(phx-key="Escape")
      assert html =~ ~s(phx-hook="InlineNameInput")
      assert html =~ ~s(name="name")
      assert html =~ ~s(value="Onboard")
      assert html =~ ~s(placeholder="Activity name… ↵")

      # Artboard inputStyle, line ~404.
      style = style_of(html, "#story-map-draft-input")
      assert style =~ "border:1.5px solid var(--color-primary)"
      assert style =~ "border-radius:5px"
      assert style =~ "padding:2px 5px"
      assert style =~ "font-size:12px;font-weight:600"
      assert style =~ "flex:1;min-width:0"
    end

    # The bug this pins cost a whole smoke run: in a real browser LiveView blurs this input
    # itself, BEFORE it pushes the submit. Bound to `cancel`, that blur closes the draft the
    # submit is about to commit, so Enter creates NOTHING — and render_submit/2, which never
    # blurs, never notices. Swap this back to phx-blur and every create affordance breaks
    # again, silently; RelayWeb.Browser.StoryMapCreateTest is what actually catches it.
    test "cancel is bound to click-away, never to blur — blur is LiveView's, not the user's" do
      html =
        render_component(&StoryMapComponents.inline_name_input/1,
          id: "story-map-draft-input",
          submit: "story_map_draft_submit",
          change: "story_map_draft_change",
          cancel: "story_map_draft_cancel"
        )

      refute html =~ "phx-blur"
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

  defp cell_column,
    do: %{key: "t:10", activity: nil, task: nil, no_task?: false, bare?: false, draft?: false, last_of_activity?: true}

  defp cell_lane, do: %{key: "r:100", release: nil, count: 0}

  defp cell_html(overrides) do
    defaults = %{
      column: cell_column(),
      lane: cell_lane(),
      cards: [],
      board: board(),
      stages: stages(),
      stalled_ids: MapSet.new(),
      column_index: 0,
      lane_index: 0
    }

    render_component(&StoryMapComponents.story_map_cell/1, Map.merge(defaults, overrides))
  end

  describe "story_map_cell/1 — the drop zone, the ＋ and the composer" do
    test "an empty cell renders the dashed ＋ with the artboard's 7px padding" do
      html = cell_html(%{})

      add = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-add-t-10-r-100")
      style = add |> LazyHTML.attribute("style") |> List.first()

      # artboard addBtnStyle, line ~527
      assert style =~ "border:1px dashed color-mix(in oklab, var(--color-base-content) 15%, var(--color-base-100))"
      assert style =~ "border-radius:8px"
      assert style =~ "padding:7px"
      assert style =~ "color:color-mix(in oklab, var(--color-base-content) 40%, transparent)"
      assert LazyHTML.attribute(add, "phx-click") == ["compose_cell"]
      assert LazyHTML.attribute(add, "phx-value-column") == ["t:10"]
      assert LazyHTML.attribute(add, "phx-value-lane") == ["r:100"]
      assert html =~ "＋"
    end

    test "a cell with cards tightens the ＋ padding to the artboard's 3px" do
      html = cell_html(%{cards: [card(1, story_task_id: 10)]})

      style =
        html
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#story-map-add-t-10-r-100")
        |> LazyHTML.attribute("style")
        |> List.first()

      assert style =~ "padding:3px"
      assert html =~ ~s(id="story-map-card-RLY1")
    end

    test "read_only hides both the ＋ and the composer, keeping the cell a drop zone" do
      html =
        cell_html(%{
          read_only: true,
          composing: true,
          compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
        })

      refute html =~ ~s(id="story-map-add-t-10-r-100")
      refute html =~ ~s(id="story-map-compose-t-10-r-100")
      assert html =~ ~s(class="story-map-drop")
    end

    test "the open composer replaces the ＋ with the artboard's bordered input" do
      html =
        cell_html(%{
          composing: true,
          compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
        })

      refute html =~ ~s(id="story-map-add-t-10-r-100")

      form = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-compose-t-10-r-100")
      style = form |> LazyHTML.attribute("style") |> List.first()

      # artboard composer, lines ~248-252
      assert style =~ "border:1.5px solid var(--color-primary)"
      assert style =~ "border-radius:9px"
      assert style =~ "padding:7px 9px"
      assert LazyHTML.attribute(form, "phx-submit") == ["create_card_in_cell"]
      assert LazyHTML.attribute(form, "phx-change") == ["validate_card"]
      assert LazyHTML.attribute(form, "phx-click-away") == ["cancel_compose_cell"]

      input = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-compose-t-10-r-100-input")
      assert LazyHTML.attribute(input, "placeholder") == ["Add card… ↵"]
      assert LazyHTML.attribute(input, "name") == ["card[title]"]
      assert LazyHTML.attribute(input, "phx-key") == ["escape"]

      assert html
             |> LazyHTML.from_fragment()
             |> LazyHTML.query("#story-map-compose-t-10-r-100-cancel")
             |> LazyHTML.attribute("phx-click") == ["cancel_compose_cell"]

      # the cell's placement travels with the submit
      assert html =~ ~s(name="column")
      assert html =~ ~s(name="lane")
      # the blue + glyph, artboard line ~250
      assert html =~ "color:var(--color-primary);font-size:14px;line-height:1"
    end

    test "the cell is still the drop zone Task 2 defined" do
      html = cell_html(%{})

      cell = html |> LazyHTML.from_fragment() |> LazyHTML.query("#story-map-cell-t-10-r-100")

      assert LazyHTML.attribute(cell, "class") == ["story-map-drop"]
      assert LazyHTML.attribute(cell, "data-column") == ["t:10"]
      assert LazyHTML.attribute(cell, "data-lane") == ["r:100"]
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
      assert html =~ "background:var(--color-field-hover);border-radius:8px;padding:2px"
      assert html =~ "box-shadow:0 1px 2px color-mix(in oklab, var(--color-neutral) 8%, transparent)"
      assert html =~ "color:color-mix(in oklab, var(--color-base-content) 90%, transparent)"
      assert html =~ ~s(aria-current="page")
    end

    test "marks the board segment active on the board view" do
      html =
        render_component(&CoreComponents.board_view_tabs/1, board_slug: "my-board", active: :board)

      assert html =~ ~r/id="board-view-tab-board"[^>]*aria-current="page"/
    end
  end

  describe "RE260 — zoom_levels/0 and parse_zoom/1" do
    test "the closed set is Map, Compact, Full, in the artboard's order" do
      assert StoryMapComponents.zoom_levels() == [:map, :compact, :full]
    end

    test "every level round-trips through parse_zoom/1, so the buttons and the parser cannot drift" do
      for level <- StoryMapComponents.zoom_levels() do
        assert StoryMapComponents.parse_zoom(to_string(level)) == {:ok, level}
      end
    end

    test "anything else is :error — the parser is total and never builds an atom" do
      assert StoryMapComponents.parse_zoom("gigantic") == :error
      assert StoryMapComponents.parse_zoom("") == :error
      assert StoryMapComponents.parse_zoom(nil) == :error
      # Even the right atom arriving as an atom is :error — the wire carries strings only.
      assert StoryMapComponents.parse_zoom(:map) == :error
    end

    test "every `attr :zoom` value list derives from zoom_levels/0 rather than re-typing it" do
      levels = StoryMapComponents.zoom_levels()

      zoom_attrs =
        for {_name, meta} <- StoryMapComponents.__components__(),
            attr <- meta.attrs,
            attr.name == :zoom,
            do: attr.opts[:values]

      # Every component that takes a zoom must accept exactly the closed set — a fourth level
      # added to @zoom_levels reaches the toolbar AND the renderers in one edit.
      assert zoom_attrs != []
      assert Enum.all?(zoom_attrs, &(&1 == levels))
    end
  end

  describe "RE260 — story_map_toolbar/1" do
    test "the active segment is the artboard's white pill and the others are transparent" do
      html = toolbar(:compact, false)

      assert style_of(html, "#story-map-zoom") ==
               "display:flex;background:var(--color-field-hover);border-radius:8px;padding:3px;"

      assert style_of(html, "#story-map-zoom-compact") =~ "background:var(--color-base-100);"

      assert style_of(html, "#story-map-zoom-compact") =~
               "color:color-mix(in oklab, var(--color-base-content) 95%, transparent);"

      assert style_of(html, "#story-map-zoom-compact") =~
               "font-size:12px;font-weight:600;padding:4px 12px;border-radius:6px;"

      assert style_of(html, "#story-map-zoom-map") =~ "background:transparent;"

      assert style_of(html, "#story-map-zoom-map") =~
               "color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
    end

    test "aria-pressed marks exactly the active segment, for each zoom" do
      for level <- StoryMapComponents.zoom_levels() do
        html = toolbar(level, false)

        for other <- StoryMapComponents.zoom_levels() do
          assert attr_of(html, "#story-map-zoom-#{other}", "aria-pressed") ==
                   to_string(other == level)
        end
      end

      assert attr_of(toolbar(:compact, false), "#story-map-zoom", "role") == "group"
      assert attr_of(toolbar(:compact, false), "#story-map-zoom", "aria-label") == "Zoom"
    end

    test "Hide tasks is white when off and violet when on, and its label flips" do
      off = toolbar(:compact, false)
      on = toolbar(:compact, true)

      assert style_of(off, "#story-map-hide-tasks") ==
               "font-size:12px;font-weight:600;padding:5px 11px;border-radius:8px;" <>
                 "color:color-mix(in oklab, var(--color-base-content) 75%, transparent);background:var(--color-base-100);" <>
                 "border:1px solid var(--color-field-border);"

      assert style_of(on, "#story-map-hide-tasks") ==
               "font-size:12px;font-weight:600;padding:5px 11px;border-radius:8px;" <>
                 "color:color-mix(in oklab, var(--color-secondary) 70%, var(--color-base-content));" <>
                 "background:color-mix(in oklab, var(--color-secondary) 10%, var(--color-base-100));" <>
                 "border:1px solid color-mix(in oklab, var(--color-secondary) 35%, var(--color-base-100));"

      assert off =~ "Hide tasks"
      assert attr_of(off, "#story-map-hide-tasks", "aria-pressed") == "false"
      assert on =~ "Show tasks"
      assert attr_of(on, "#story-map-hide-tasks", "aria-pressed") == "true"
    end
  end

  describe "RE260 — the three card faces" do
    test "Map is a bare title line with the artboard's 2px hued border and 5px pad" do
      html = card_html(:map, [])

      assert style_of(html, "#story-map-card-RLY1") ==
               "font-size:9.5px;line-height:1.35;color:color-mix(in oklab, var(--color-secondary) 45%, var(--color-base-content));" <>
                 "border-left:2px solid color-mix(in oklab, var(--color-secondary) 70%, var(--color-base-100));padding-left:5px;cursor:grab;"

      # No ref row, no badge, no bar — the artboard renders only `{{ card.title }}` (line ~216).
      refute html =~ "justify-content:space-between"
      refute html =~ "CODE"
      refute html =~ "story-map-card-bar"
    end

    test "a done card at Map zoom is struck through and muted" do
      html = card_html(:map, hue: :green, done: true, badge: "DONE", avatar: :check)

      style = style_of(html, "#story-map-card-RLY1")
      assert style =~ "color:color-mix(in oklab, var(--color-base-content) 60%, transparent);"
      assert style =~ "border-left:2px solid color-mix(in oklab, var(--color-success) 65%, var(--color-base-100));"

      assert style =~
               "text-decoration:line-through;text-decoration-color:color-mix(in oklab, var(--color-success) 65%, var(--color-base-100));"
    end

    test "Compact is a white box with a 3px hued left border, 6px radius and no meta" do
      html = card_html(:compact, [])

      assert style_of(html, "#story-map-card-RLY1") ==
               "background:var(--color-base-100);border:1px solid var(--color-base-300);" <>
                 "border-left:3px solid var(--color-secondary);border-radius:6px;padding:6px 8px;" <>
                 "display:flex;flex-direction:column;cursor:grab;"

      assert html =~ "font-size:11.5px;line-height:1.3;font-weight:500;"
      refute html =~ "justify-content:space-between"
      refute html =~ "CODE"
      refute html =~ "story-map-card-bar"
    end

    test "a done card at Compact zoom keeps the green left border at 0.82 opacity" do
      html = card_html(:compact, hue: :green, done: true, badge: "DONE", avatar: :check)

      style = style_of(html, "#story-map-card-RLY1")
      assert style =~ "border-left:3px solid var(--color-success);"
      assert style =~ "opacity:0.82;"
    end

    test "Full is today's face, unchanged: ref, avatar, badge, bar and a 9px tinted box" do
      html = card_html(:full, pct: 62, badge: "CODE · 62%")

      assert style_of(html, "#story-map-card-RLY1") =~ "border-radius:9px;padding:9px 10px;"
      assert html =~ "CODE · 62%"
      assert html =~ "font-size:12.5px;line-height:1.3;font-weight:500;"
      assert html =~ "story-map-card-bar"
      assert style_of(html, ".story-map-card-bar") =~ "width:62%;"
    end

    test "the progress bar never renders below Full, even with a percentage" do
      refute card_html(:map, pct: 62) =~ "story-map-card-bar"
      refute card_html(:compact, pct: 62) =~ "story-map-card-bar"
    end

    test "EVERY zoom keeps the drag-and-drop and click contract" do
      # assets/js/hooks/story_map_dnd.js keys off exactly `.story-map-card[data-ref]`; a Map face
      # that dropped them would silently kill drag and drop.
      for level <- StoryMapComponents.zoom_levels() do
        html = card_html(level, [])

        assert matches?(html, ".story-map-card[data-ref='RLY1'][draggable='true']")
        assert attr_of(html, "#story-map-card-RLY1", "phx-click") == "select_card"
        assert attr_of(html, "#story-map-card-RLY1", "phx-value-ref") == "RLY1"
        assert attr_of(html, "#story-map-card-RLY1", "role") == "button"
      end
    end
  end

  describe "RE260 — zoom's two effects outside the card face" do
    test "the body cell's gap is 3px at Map and 7px elsewhere" do
      assert style_of(grid_html_at(:map), "#story-map-cell-t-10-r-100") =~ "gap:3px;"
      assert style_of(grid_html_at(:compact), "#story-map-cell-t-10-r-100") =~ "gap:7px;"
      assert style_of(grid_html_at(:full), "#story-map-cell-t-10-r-100") =~ "gap:7px;"
    end

    test "the inline ＋ add-card is hidden at Map only" do
      refute matches?(grid_html_at(:map), "#story-map-add-t-10-r-100")
      assert matches?(grid_html_at(:compact), "#story-map-add-t-10-r-100")
      assert matches?(grid_html_at(:full), "#story-map-add-t-10-r-100")
    end
  end

  describe "RE260 — the merged column" do
    test "its header reads <n> tasks · merged, muted and smaller than a task header" do
      html = grid_html(merged_grid())

      assert matches?(html, "#story-map-merged-1")
      assert html =~ "1 tasks · merged"

      assert style_of(html, "#story-map-merged-1") ==
               "grid-column:2;grid-row:2;position:sticky;top:56px;z-index:20;" <>
                 "background:var(--color-base-200);border-right:2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100));" <>
                 "border-bottom:2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100));padding:7px 9px;font-size:10.5px;" <>
                 "color:color-mix(in oklab, var(--color-base-content) 50%, transparent);display:flex;align-items:center;gap:6px;"
    end

    test "it is not a rename affordance, not a drag grip and not an add-task button" do
      html = grid_html(merged_grid())

      refute matches?(html, "button#story-map-merged-1")
      refute matches?(html, "#story-map-draft-input")
      refute html =~ "＋ Add task"
    end

    test "it is 176px wide where a task column is 156px" do
      assert style_of(grid_html(merged_grid()), "#story-map-grid") =~
               "grid-template-columns:128px 176px 58px;"

      assert style_of(grid_html(), "#story-map-grid") =~ "grid-template-columns:128px 156px 156px 58px;"
    end

    test "both of the activity's cards render in its one cell" do
      html = grid_html(merged_grid())

      assert matches?(html, "#story-map-cell-m-1-r-100 #story-map-card-RLY1")
      assert matches?(html, "#story-map-cell-m-1-r-100 #story-map-card-RLY2")
    end
  end

  # RE260 — the same one-activity board as `grid/1`, merged.
  defp merged_grid do
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
      nil,
      true
    )
  end

  defp grid_html_at(zoom) do
    render_component(&StoryMapComponents.story_map/1,
      grid: grid(),
      board: board(),
      stages: stages(),
      stalled_ids: MapSet.new(),
      draft: nil,
      draft_name: "",
      zoom: zoom
    )
  end

  defp card_html(zoom, overrides) do
    attrs =
      Map.merge(
        %{
          id: "story-map-card-RLY1",
          ref: "RLY1",
          title: "Add SSO for enterprise accounts",
          badge: "CODE",
          hue: :violet,
          zoom: zoom
        },
        Map.new(overrides)
      )

    render_component(&StoryMapComponents.story_map_card/1, attrs)
  end

  defp toolbar(zoom, hide_tasks) do
    render_component(&StoryMapComponents.story_map_toolbar/1, zoom: zoom, hide_tasks: hide_tasks)
  end

  # `style_of/2`'s companion for any other attribute.
  defp attr_of(html, selector, attribute) do
    html
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> LazyHTML.attribute(attribute)
    |> List.first()
  end

  describe "presence_stack/1 (RE257)" do
    test "renders nothing when you are alone on the map" do
      refute presence_html([presence_dana()]) =~ "story-map-presence"
    end

    test "renders nothing for an empty roster" do
      refute presence_html([]) =~ "story-map-presence"
    end

    test "two people render two 26px identity circles, artboard lines 49-56" do
      html = presence_html([presence_dana(), presence_mara()])

      assert html =~ ~s(id="story-map-presence")
      # 26px circles (artboard line ~51)
      assert html =~ "width:26px;height:26px"
      # identity-hued fill, the same formula the cursor arrow uses
      assert html =~ "background:#{CoreComponents.identity_color("dana@acme.co")}"
      assert html =~ "background:#{CoreComponents.identity_color("mara@acme.co")}"
      # white initials at weight 600
      assert html =~ "color:var(--color-neutral-content)"
      assert html =~ "font-weight:600"
      assert html =~ ">DK<"
      assert html =~ ">ML<"
      # 2px white border on every circle; -8px tuck on every circle AFTER the first
      assert html =~ "border-2 border-base-100"
      assert html =~ "-ml-2"
    end

    test "you come first and your title says so" do
      html = presence_html([presence_mara(), presence_dana()], 1)

      assert html =~ ~s(title="Dana Kim \(you\)")
      assert html =~ ~s(title="Mara Lopez")
      # Dana's circle is rendered before Mara's.
      assert :binary.match(html, "Dana Kim (you)") < :binary.match(html, "Mara Lopez")
    end

    test "caps at five faces and shows a neutral +N chip beyond" do
      people = for i <- 1..8, do: presence_person(i, "Person #{i}", "p#{i}@acme.co")

      html = presence_html(people)

      assert html =~ ~s(id="story-map-presence-overflow")
      assert html =~ "+3"
      # the board's existing overflow-chip colours, at the stack's 26px
      assert html =~ "width:26px;height:26px;border-radius:50%;background:var(--color-base-300)"
      assert html =~ "border:2px solid var(--color-base-100);margin-left:-8px;"
    end

    test "exactly five people show five faces and no chip" do
      people = for i <- 1..5, do: presence_person(i, "Person #{i}", "p#{i}@acme.co")

      refute presence_html(people) =~ "story-map-presence-overflow"
    end
  end

  describe "RE259 — story_map_filter_bar/1" do
    defp dana_chip(selected?) do
      %{
        key: "u:3",
        actor: :human,
        name: "Dana Kim",
        email: "dana@acme.co",
        avatar_url: nil,
        selected?: selected?
      }
    end

    defp ai_chip(selected?) do
      %{key: "agent", actor: :ai, name: "Relay AI", email: nil, avatar_url: nil, selected?: selected?}
    end

    defp filter_bar(overrides) do
      attrs =
        Keyword.merge(
          [
            chips: [dana_chip(false), ai_chip(false)],
            needs_input: false,
            hide_complete: true,
            focus_name: nil,
            filter_active: false,
            visible: 5,
            total: 5
          ],
          overrides
        )

      render_component(&StoryMapComponents.story_map_filter_bar/1, attrs)
    end

    test "the bar is the artboard's 48px row" do
      assert style_of(filter_bar([]), "#story-map-filter-bar") ==
               "min-height:48px;flex:0 0 auto;display:flex;align-items:center;gap:8px;" <>
                 "flex-wrap:wrap;padding:9px 18px;border-bottom:1px solid var(--color-base-300);" <>
                 "background:var(--color-field-hover);z-index:55;"
    end

    test "an unselected owner chip is white-on-neutral with the artboard's dimmed avatar" do
      html = filter_bar([])
      chip = "##{StoryMapFilter.chip_dom_id("u:3")}"

      assert style_of(html, chip) ==
               "display:flex;align-items:center;border-radius:8px;padding:3px;" <>
                 "background:var(--color-base-100);border:1px solid var(--color-field-border);"

      assert attr_of(html, chip, "aria-pressed") == "false"
      # `avatar/1` omits the attribute entirely when it has no class, so `|| ""` keeps a
      # missing class from raising instead of failing.
      assert (attr_of(html, "#{chip} span", "class") || "") =~ "opacity-[0.85]"
    end

    test "a selected owner chip takes that person's identity hue" do
      hue = CoreComponents.identity_hue("dana@acme.co")
      html = filter_bar(chips: [dana_chip(true)])
      chip = "##{StoryMapFilter.chip_dom_id("u:3")}"

      assert style_of(html, chip) =~ "background:oklch(0.95 0.03 #{hue});"
      assert style_of(html, chip) =~ "border:1px solid oklch(0.75 0.08 #{hue});"
      assert attr_of(html, chip, "aria-pressed") == "true"
      refute (attr_of(html, "#{chip} span", "class") || "") =~ "opacity-[0.85]"
    end

    test "the AI chip is the app's violet mark at the artboard's violet tint" do
      html = filter_bar(chips: [ai_chip(true)])
      chip = "##{StoryMapFilter.chip_dom_id("agent")}"

      # 292 is this module's `hue_deg(:violet)` — the AI's one hue.
      assert style_of(html, chip) =~ "background:oklch(0.95 0.03 292);"
      assert attr_of(html, chip, "phx-value-owner") == "agent"
    end

    test "the Needs input button carries the artboard's amber dot and both states" do
      off = filter_bar([])
      on = filter_bar(needs_input: true)

      assert style_of(off, "#story-map-needs-input-filter") =~
               "background:var(--color-base-100);" <>
                 "color:color-mix(in oklab, var(--color-base-content) 70%, transparent);" <>
                 "border:1px solid var(--color-field-border);"

      assert style_of(on, "#story-map-needs-input-filter") =~
               "background:color-mix(in oklab, var(--color-warning) 15%, var(--color-base-100));" <>
                 "color:color-mix(in oklab, var(--color-warning) 55%, var(--color-base-content));" <>
                 "border:1px solid color-mix(in oklab, var(--color-warning) 60%, var(--color-base-100));"

      assert attr_of(off, "#story-map-needs-input-filter", "aria-pressed") == "false"
      assert attr_of(on, "#story-map-needs-input-filter", "aria-pressed") == "true"

      assert style_of(on, "#story-map-needs-input-filter span") ==
               "width:6px;height:6px;border-radius:50%;background:var(--color-warning);"
    end

    test "the Focusing chip renders only while focusing, in the artboard's violet" do
      refute filter_bar([]) =~ "story-map-exit-focus"

      html = filter_bar(focus_name: "Checkout")

      assert html =~ "◎ Focusing: Checkout ✕"

      assert style_of(html, "#story-map-exit-focus") =~
               "background:color-mix(in oklab, var(--color-secondary) 5%, var(--color-base-100));" <>
                 "color:color-mix(in oklab, var(--color-secondary) 65%, var(--color-base-content));" <>
                 "border:1px solid color-mix(in oklab, var(--color-secondary) 25%, var(--color-base-100));"
    end

    test "Clear follows filter_active, and the count follows the NUMBERS not the filter" do
      resting = filter_bar([])
      filtering = filter_bar(filter_active: true, visible: 2, total: 5)

      refute resting =~ "story-map-clear-filters"
      assert resting =~ "5 cards"

      assert filtering =~ "story-map-clear-filters"
      assert filtering =~ "2 of 5"

      # RE276 — hide-complete is ON by default, so a fresh board already hides cards with no
      # filter "active". The label must be truthful whichever filter caused the gap, so it
      # reads the two numbers and never `filter_active`.
      default_hiding = filter_bar(filter_active: false, visible: 4, total: 5)
      assert default_hiding =~ "4 of 5"
      refute default_hiding =~ "story-map-clear-filters"

      assert style_of(filtering, "#story-map-clear-filters") ==
               "font-size:11px;font-weight:600;" <>
                 "color:color-mix(in oklab, var(--color-primary) 85%, var(--color-base-content));"

      assert style_of(filtering, "#story-map-count") ==
               "font-family:var(--font-mono);font-size:11px;" <>
                 "color:color-mix(in oklab, var(--color-base-content) 70%, transparent);"
    end

    test "the Hide complete toggle is the Needs input button's chrome, pressed by default" do
      # No artboard covers this control; it is a SIBLING of the Needs input toggle built to
      # `docs/designs/Relay Story Map.dc.html` lines 59-77, and must be indistinguishable from
      # it in size, radius, type and pressed treatment (`needsStyle`, line ~572).
      on = filter_bar([])
      off = filter_bar(hide_complete: false)

      assert style_of(on, "#story-map-hide-complete-filter") ==
               "display:flex;align-items:center;gap:6px;border-radius:8px;padding:5px 10px;" <>
                 "font-size:11.5px;font-weight:600;background:oklch(0.96 0.05 65);" <>
                 "color:oklch(0.5 0.13 65);border:1px solid oklch(0.82 0.09 65);"

      assert style_of(off, "#story-map-hide-complete-filter") ==
               style_of(filter_bar([]), "#story-map-needs-input-filter")

      assert attr_of(on, "#story-map-hide-complete-filter", "aria-pressed") == "true"
      assert attr_of(off, "#story-map-hide-complete-filter", "aria-pressed") == "false"

      assert attr_of(on, "#story-map-hide-complete-filter", "phx-click") ==
               "toggle_story_map_hide_complete"

      # Phrased to match `Hide tasks` next door, and NOT carrying Needs input's amber dot —
      # that 6px marker belongs to that filter, not to the shared chrome.
      assert text_of(on, "#story-map-hide-complete-filter") == "Hide complete"
      assert style_of(on, "#story-map-hide-complete-filter span") == ""
    end

    test "the artboard's + filter button is deliberately absent" do
      refute filter_bar([]) =~ "+ filter"
    end
  end

  describe "RE259 — story_map_collapsed_stub/1" do
    defp text_of(html, selector) do
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query(selector)
      |> LazyHTML.text()
      |> String.trim()
    end

    defp stub(overrides) do
      attrs =
        Keyword.merge(
          [
            activity: %StoryActivity{id: 7, board_id: 1, name: "Checkout", position: 1},
            index: 0,
            count: 3,
            focusing: false
          ],
          overrides
        )

      render_component(&StoryMapComponents.story_map_collapsed_stub/1, attrs)
    end

    test "the stub spans every row, sticky, at the artboard's values" do
      assert style_of(stub([]), "#story-map-stub-7") ==
               "grid-column:2;grid-row:1 / -1;align-self:stretch;position:sticky;top:0;z-index:22;" <>
                 "background:var(--color-field-hover);" <>
                 "border-right:2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100));" <>
                 "border-bottom:1px solid var(--color-base-300);display:flex;flex-direction:column;" <>
                 "align-items:center;justify-content:space-between;padding:10px 0;cursor:pointer;"
    end

    test "the name is vertical and the count badge is INVERTED" do
      html = stub([])

      assert html =~ "▸"
      assert html =~ "Checkout"

      assert style_of(html, "#story-map-stub-7 [data-role='stub-name']") ==
               "writing-mode:vertical-rl;transform:rotate(180deg);font-size:12px;" <>
                 "font-weight:600;color:color-mix(in oklab, var(--color-base-content) 80%, transparent);"

      # The artboard's `badgeStyle` collapsed branch (line ~414): white on the dark pill,
      # the exact reverse of an expanded band's badge.
      assert style_of(html, "#story-map-stub-7 [data-role='stub-count']") ==
               "font-family:var(--font-mono);font-size:9px;font-weight:600;color:var(--color-neutral-content);" <>
                 "background:var(--color-neutral);border-radius:20px;padding:2px 6px;"

      assert text_of(html, "#story-map-stub-7 [data-role='stub-count']") == "3"
    end

    test "clicking expands normally and MOVES FOCUS while focusing" do
      # The artboard's `onClick: st.focus ? setFocus : toggleCollapse` (line ~422).
      assert attr_of(stub([]), "#story-map-stub-7", "phx-click") == "toggle_story_map_collapse"

      assert attr_of(stub(focusing: true), "#story-map-stub-7", "phx-click") ==
               "set_story_map_focus"

      assert attr_of(stub([]), "#story-map-stub-7", "phx-value-activity-id") == "7"
    end

    test "the aria-label names what the click ACTUALLY does in each mode" do
      # Focus mode is precisely when every non-focused band is a stub, so a label that
      # always said "Expand" would mis-describe the common case to a screen reader.
      assert attr_of(stub([]), "#story-map-stub-7", "aria-label") == "Expand Checkout"

      assert attr_of(stub(focusing: true), "#story-map-stub-7", "aria-label") == "Focus Checkout"
    end

    test "the stub stays a RE261 reorder source and target while collapsed" do
      html = stub([])

      # `StoryMapDnD` selects both by exactly these (story_map_dnd.js lines ~22-23), so a
      # collapsed activity that dropped them could neither be dragged nor dropped onto.
      assert attr_of(html, "#story-map-stub-7", "draggable") == "true"
      assert attr_of(html, "#story-map-stub-7", "data-kind") == "activity"
      assert attr_of(html, "#story-map-stub-7", "data-id") == "7"
      assert attr_of(html, "#story-map-stub-7", "class") == "story-map-header story-map-header-drop"

      # And NOT a card drop target — `decode_placement/2` has no `"c:"` clause.
      refute attr_of(html, "#story-map-stub-7", "class") =~ "story-map-drop"
    end

    test "an archived board's stub is neither a reorder source nor a target" do
      html = stub(read_only: true)

      assert attr_of(html, "#story-map-stub-7", "draggable") == "false"
      assert attr_of(html, "#story-map-stub-7", "class") in [nil, ""]
    end
  end

  describe "RE259 — the grid under collapse" do
    defp collapsed_map_html do
      activities = [
        %StoryActivity{id: 1, board_id: 1, name: "Onboard & access", position: 1},
        %StoryActivity{id: 2, board_id: 1, name: "Plan the backlog", position: 2}
      ]

      tasks = [%StoryTask{id: 10, board_id: 1, story_activity_id: 1, name: "Sign in", position: 1}]
      releases = [%Release{id: 100, board_id: 1, name: "MVP", position: 1}]
      cards = [card(1, story_activity_id: 1, story_task_id: 10, release_id: 100)]

      grid =
        StoryMapGrid.build(
          activities,
          tasks,
          releases,
          cards,
          nil,
          false,
          StoryMapGrid.collapsed_set(activities, [1], nil)
        )

      render_component(&StoryMapComponents.story_map/1,
        grid: grid,
        board: board(),
        stages: stages(),
        stalled_ids: MapSet.new(),
        focus: nil
      )
    end

    test "a collapsed activity renders its stub instead of a band, a header and cells" do
      html = collapsed_map_html()

      assert html =~ "story-map-stub-1"
      refute html =~ "story-map-activity-1"
      refute html =~ "story-map-task-10"
      refute html =~ StoryMapGrid.cell_dom_id("c:1", "r:100")
      refute html =~ StoryMapGrid.cell_dom_id("t:10", "r:100")

      # The expanded neighbour is untouched.
      assert html =~ "story-map-activity-2"
    end

    test "the stub column is the artboard's 50px track" do
      assert style_of(collapsed_map_html(), "#story-map-grid") =~
               "grid-template-columns:128px 50px 156px 58px;"
    end

    test "the band header carries the two new icon buttons on every board" do
      html = collapsed_map_html()

      assert attr_of(html, "#story-map-collapse-2", "phx-click") == "toggle_story_map_collapse"
      assert attr_of(html, "#story-map-collapse-2", "phx-value-activity-id") == "2"
      assert attr_of(html, "#story-map-focus-2", "phx-click") == "set_story_map_focus"

      assert style_of(html, "#story-map-focus-2") ==
               "font-size:12px;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);"

      assert style_of(html, "#story-map-collapse-2") ==
               "font-size:12px;color:color-mix(in oklab, var(--color-base-content) 60%, transparent);"
    end
  end

  describe "RE237 theme tokens" do
    test "grid lines and the empty-task cell come from base tokens, not literals" do
      src = File.read!("lib/relay_web/components/story_map_components.ex")

      # docs/designs/Relay Story Map.dc.html — the 1px grid Line and the 2px committed-row
      # rule keep their weights and dash pattern; only the color moves to a token.
      assert src =~ ~s[@gl_light "1px solid var(--color-base-300)"]
      assert src =~ ~s[@gl_strong "2px solid color-mix(in oklab, var(--color-base-content) 25%, var(--color-base-100))"]
      assert src =~ ~s[@gl_dashed "1px dashed color-mix(in oklab, var(--color-base-content) 20%, var(--color-base-100))"]
      assert src =~ ~s[@no_task_bg "var(--color-base-200)"]

      # RE259's owner chip reintroduced ONE oklch: `owner_chip_style/1`'s per-person/AI hue
      # tint, the same kind of exception as `CoreComponents.identity_color/1` — marked with
      # a `theme-tokens:allow` comment (on the line itself or the line directly above, same
      # as theme_tokens_test.exs honours) and covered by the whole-tree guardrail. Any OTHER
      # oklch( here would be a regression.
      lines = String.split(src, "\n")

      unmarked =
        lines
        |> Enum.with_index()
        |> Enum.filter(fn {line, _i} -> line =~ "oklch(" end)
        |> Enum.reject(fn {line, i} ->
          line =~ "theme-tokens:allow" or (i > 0 and Enum.at(lines, i - 1) =~ "theme-tokens:allow")
        end)

      assert unmarked == [], "unmarked oklch literal(s): #{inspect(unmarked)}"
    end

    test "the live-cursor avatar ring follows the surface instead of staying white" do
      src = File.read!("lib/relay_web/components/story_map_components.ex")

      assert src =~ "border-base-100"
      refute src =~ "border-white"
    end
  end
end
