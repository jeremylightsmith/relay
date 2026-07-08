# MMF 12c — Auto-collapse empty stages & lanes

**Spec:** `docs/superpowers/specs/2026-07-08-collapse-empty-columns-design.md`
**Branch discipline:** trunk-based on `main`.
**Mockup (ground truth):** `docs/designs/Relay Board.dc.html` — collapsed stage strip at lines ~75–81, sub-lane strip styles at lines ~1028–1037, collapse conditions at ~1007 (`collapsed = all.length === 0 && !forceOpen`) and ~1020 (`laneCollapsed = isSub && laneCards.length === 0 && !forceOpen`).

## Goal

A stage with **zero cards across its main lane and all its sub-lanes** auto-collapses into the
mockup's 44px dashed vertical strip; an **empty Review/Done sub-lane** collapses into a 34px
vertical strip inside its expanded parent. Collapsed strips stay drop targets (the MMF 05
`move_card` contract), expand on click for the session (`:force_open` MapSet, not persisted),
and track live counts (MMF 18 realtime) — the last card leaving collapses, the first card
arriving expands, in every open session.

## Architecture

- **No schema/migration.** Collapse is *derived* at render time from `@stage_counts` (which is
  already recomputed on create/move/realtime events) plus a per-session `:force_open`
  `MapSet` of stage ids in the `RelayWeb.BoardLive` socket. Sub-lanes are `Schemas.Stage` rows
  with globally unique ids, so one MapSet covers both stages and lanes — no namespacing.
- **`RelayWeb.CoreComponents.stage_column/1`** gains a `collapsed` boolean attr (whole-stage
  strip) and honors an optional `collapsed` key on each `sublanes` entry (lane strip). The
  strip elements carry `class="... stage-cards"` and `data-stage-id` so the existing
  `assets/js/hooks/board_dnd.js` hook (zone selector `.stage-cards`, reads
  `zone.dataset.stageId`) accepts drops on them unchanged, plus
  `phx-click="expand_stage" phx-value-stage-id` for click-to-expand.
- **Realtime is free:** `apply_move/3`, `handle_info({:card_upserted, ...})`, and
  `reload_board/1` already recompute `@stage_counts`, so collapse/expand re-derives on every
  local or broadcast change. `:force_open` lives only in the socket and survives
  `reload_board/1` (which never touches it).
- **Test collateral:** a fresh board provisions 7 *empty* stages, so many existing LiveView
  tests interact with stages that will now render as strips. Each affected test is updated in
  Task 1 (enumerated with exact code); the collapsed strip deliberately keeps the
  `stage-column` class, an `<h3>` name, `.stage-owner-swatch[data-owner]`, and a
  `.stage-count` span so order/swatch/count/smoke tests keep passing with minimal edits (the
  Playwright smoke test `test/relay_web/browser/board_smoke_test.exs` asserts `h3` text
  "Backlog" — the strip's rotated `<h3>` satisfies it; do not change that file).

## Tech

Phoenix 1.8 LiveView, HEEx function components, LiveView streams (unchanged), daisyUI/Tailwind
with inline `oklch(...)` values copied verbatim from the mockup, `Phoenix.LiveViewTest` +
`LazyHTML` for tests, PhoenixStorybook for the component story.

## Global Constraints

- `mix precommit` MUST pass at the end of every task: compile (warnings as errors),
  `mix format` (Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`, full test
  suite (warnings as errors). Run `mix format` before committing.
- Boundary rules: `RelayWeb` may only call exported `Relay` contexts. This MMF adds no new
  context calls — everything stays inside `RelayWeb`.
- HEEx: `{...}` in attrs and text, `<%= ... %>` for block constructs; class lists use `[...]`
  syntax; `<%= for ... do %>` (never `Enum.each`); no inline `<script>`; `<.icon>` for icons;
  colocated hook names would start with `.` (none are needed here).
- Predicate functions end in `?`, never start with `is_`.
- Mono labels use the existing inline `font-family:var(--font-mono)` pattern (matches the
  shipped `stage_column/1`); the strip's exact colours are inline `oklch(...)` values from the
  mockup.
- Do NOT break: the MMF 05 move contract (`.stage-cards[data-stage-id]` drop zones +
  `move_card` event with `ref`/`stage_id`/optional `index`), MMF 18 realtime application,
  MMF 06 baton/mismatch rendering on expanded cards, stage counts, or category band counts.
- Every reusable-component change refreshes its story under `storybook/` — the final summary
  must point the user at `/storybook/core_components/stage_column`.
- Group `handle_event/3` clauses together in `board_live.ex` (clauses of the same function
  must be adjacent or compilation warns → fails precommit).

---

### Task 1: Collapsed stage strip (auto-collapse empty stages, force-open, drop target)

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`stage_column/1`)
- Modify: `lib/relay_web/live/board_live.ex` (mount, render, new `expand_stage` event, `stage_collapsed?/4`)
- Modify: `storybook/core_components/stage_column.story.exs` (new `:collapsed_empty` variation)
- Tests (new): additions to `test/relay_web/components/core_components_test.exs`, new describe in `test/relay_web/live/board_live_test.exs`, new two-session test in `test/relay_web/live/board_live_realtime_test.exs`
- Tests (update existing to the collapse-aware board): `test/relay_web/live/board_live_test.exs`, `test/relay_web/live/board_live_realtime_test.exs`, `test/relay_web/live/board_settings_stages_test.exs`

**Interfaces**

*Consumes (already shipped):*
- `RelayWeb.CoreComponents.stage_column/1` — attrs `id`, `name`, `owner`, `count`, `category`, `stage_id`, `board_key`, `cards`, `composing`, `compose_form`, `sublanes` (list of `%{id, name, lane, owner, count, cards}`); expanded section renders `id={@id}` with `#{@id}-cards` as a `.stage-cards[data-stage-id]` zone; private helpers `owner_hex/1`, `lane_color/1`, `lane_tint/1`, `lane_divider/1`.
- `RelayWeb.BoardLive` — assigns `@stage_counts` (map of stage id → count, includes sub-lane ids), `@sublanes_by_parent` (map parent id → child `Schemas.Stage` list), `@stage_groups`; `handle_event("move_card", %{"ref" => _, "stage_id" => _} = params, socket)`; `apply_move/3` and `reload_board/1` recompute `@stage_counts`; private `parse_int/1` (returns integer or `nil`).
- `assets/js/hooks/board_dnd.js` — drop zones are `.stage-cards` elements; drop pushes `move_card` with `zone.dataset.stageId` and a computed index (0 for an empty zone). No JS changes needed.
- Test helpers: `register_and_log_in_user`, `insert/2` factory, `Relay.Boards.get_or_create_default_board/1`, `Relay.Cards.create_card/2`, `Relay.Boards.enable_lane/2`.

*Produces (Task 2 and tests rely on these exact names):*
- `stage_column/1` new attr: `attr :collapsed, :boolean, default: false`. When true, renders ONLY `<section id={"stage-strip-#{@stage_id}"} class="stage-column stage-strip stage-cards" data-stage-id={@stage_id} phx-click="expand_stage" phx-value-stage-id={@stage_id}>` containing a 9px `.stage-owner-swatch[data-owner]`, a rotated `<h3 class="stage-strip-name">`, and `<span class="stage-count">` showing `@total_count`.
- `stage_column/1` new internal assign `:total_count` = `(count || 0) + sum of sublane counts`.
- `RelayWeb.BoardLive`: assign `:force_open` (`MapSet.new()` at mount); `handle_event("expand_stage", %{"stage-id" => stage_id}, socket)` putting the parsed id into `:force_open`; private `stage_collapsed?(stage, stage_counts, sublanes_by_parent, force_open)` (arity 4, first arg the `%Schemas.Stage{}`).
- `RelayWeb.BoardLiveTest` private helper `expand_stage(view, stage)`.

**Steps**

- [x] **Write the failing component tests.** Append inside the existing `describe "stage_column/1"` block of `test/relay_web/components/core_components_test.exs` (after the "shows the composer form..." test):

  ```elixir
  test "collapsed renders the mockup's 44px dashed strip instead of the column" do
    html =
      render_component(&CoreComponents.stage_column/1,
        id: "stage-col-6",
        name: "Deploy",
        owner: :ai,
        stage_id: 6,
        count: 0,
        collapsed: true
      )

    # strip identity + mockup values (Relay Board.dc.html lines ~75–81)
    assert html =~ ~s(id="stage-strip-6")
    assert html =~ "width:44px"
    assert html =~ "border:1px dashed oklch(0.90 0.006 255)"
    assert html =~ "background:oklch(0.965 0.004 255)"
    assert html =~ "border-radius:11px"
    assert html =~ "cursor:pointer"
    # 9px owner swatch in the AI colour
    assert html =~ "stage-owner-swatch"
    assert html =~ ~s(data-owner="ai")
    assert html =~ "width:9px;height:9px;border-radius:3px"
    # rotated name + mono count
    assert html =~ "writing-mode:vertical-rl"
    assert html =~ "rotate(180deg)"
    assert html =~ "stage-strip-name"
    assert html =~ "Deploy"
    assert html =~ ~s(class="stage-count")
    # click-to-expand + drop-target contract
    assert html =~ ~s(phx-click="expand_stage")
    assert html =~ ~s(phx-value-stage-id="6")
    assert html =~ ~s(data-stage-id="6")
    assert html =~ "stage-cards"
    # none of the expanded chrome renders
    refute html =~ ~s(id="stage-col-6-new-card")
    refute html =~ "No cards yet"
  end

  test "collapsed shows the total card count across main and sub-lanes" do
    html =
      render_component(&CoreComponents.stage_column/1,
        id: "stage-col-4",
        name: "Code",
        owner: :ai,
        stage_id: 4,
        count: 0,
        collapsed: true,
        sublanes: [
          %{id: 401, name: "Review", lane: :review, owner: :human, count: 0, cards: []},
          %{id: 402, name: "Done", lane: :done, owner: :ai, count: 0, cards: []}
        ]
      )

    assert html =~ ~s(id="stage-strip-4")

    count_text =
      html
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#stage-strip-4 .stage-count")
      |> LazyHTML.text()
      |> String.trim()

    assert count_text == "0"
  end

  test "collapsed: false renders the full column exactly as before" do
    html =
      render_component(&CoreComponents.stage_column/1,
        id: "stage-col-1",
        name: "Backlog",
        owner: :human,
        stage_id: 7,
        collapsed: false
      )

    assert html =~ ~s(id="stage-col-1")
    refute html =~ "stage-strip"
    assert html =~ "No cards yet"
  end
  ```

- [x] Run `mix test test/relay_web/components/core_components_test.exs` — expect the three new tests to FAIL (undefined attr `collapsed`).

- [x] **Implement the collapsed branch in `stage_column/1`** (`lib/relay_web/components/core_components.ex`). Add the attr after the `sublanes` attr declaration:

  ```elixir
  attr :collapsed, :boolean,
    default: false,
    doc: "render the whole stage as the mockup's 44px dashed strip (still a drop target)"
  ```

  Update the body of `def stage_column(assigns)`: the assigns pipeline gains `:total_count` —

  ```elixir
  def stage_column(assigns) do
    assigns =
      assigns
      |> assign(:labeled, assigns.sublanes != [])
      |> assign(:stage_width, 240 + 178 * length(assigns.sublanes))
      |> assign(:total_count, (assigns.count || 0) + Enum.sum(Enum.map(assigns.sublanes, & &1.count)))
  ```

  — and the template wraps the existing section in an `if`. The strip branch is new; the `else` branch is today's `<section id={@id} ...> ... </section>` **kept verbatim, only re-indented**:

  ```heex
  ~H"""
  <%= if @collapsed do %>
    <section
      id={"stage-strip-#{@stage_id}"}
      class="stage-column stage-strip stage-cards"
      data-stage-id={@stage_id}
      phx-click="expand_stage"
      phx-value-stage-id={@stage_id}
      aria-label={"Expand stage #{@name}"}
      style="flex:0 0 auto;width:44px;display:flex;flex-direction:column;align-items:center;gap:10px;padding:12px 0;border-radius:11px;background:oklch(0.965 0.004 255);border:1px dashed oklch(0.90 0.006 255);cursor:pointer;box-sizing:border-box;"
    >
      <span
        class="stage-owner-swatch"
        data-owner={@owner}
        style={"width:9px;height:9px;border-radius:3px;flex:0 0 auto;background:#{owner_hex(@owner)};"}
      >
      </span>
      <h3
        class="stage-strip-name"
        style="writing-mode:vertical-rl;transform:rotate(180deg);font-size:12px;font-weight:600;letter-spacing:0.01em;color:oklch(0.52 0.02 255);white-space:nowrap;"
      >
        {@name}
      </h3>
      <span
        class="stage-count"
        style="font-size:10px;font-family:var(--font-mono);color:oklch(0.65 0.02 255);"
      >
        {@total_count}
      </span>
    </section>
  <% else %>
    <section
      id={@id}
      class="stage-column"
      ... ENTIRE EXISTING EXPANDED SECTION UNCHANGED, THROUGH ITS CLOSING </section> ...
  <% end %>
  """
  ```

  Also extend the component's `@doc` with one paragraph:

  ```
  When `collapsed` (MMF 12c), the stage renders instead as the mockup's 44px dashed
  vertical strip — owner swatch, rotated name, total count — which remains a
  `.stage-cards[data-stage-id]` drop zone and emits `"expand_stage"`
  (`phx-value-stage-id`) on click.
  ```

- [x] Run `mix test test/relay_web/components/core_components_test.exs` — expect PASS.

- [x] **Write the failing BoardLive tests.** In `test/relay_web/live/board_live_test.exs`, add a new describe after the `describe "sub-lanes"` block:

  ```elixir
  describe "collapsed empty stages (MMF 12c)" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "an empty stage renders the collapsed strip; a stage with a card renders the full column",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Keep me open"})

      {:ok, view, _html} = live(conn, ~p"/board")

      # non-empty Backlog: full column, no strip
      assert has_element?(view, "#stage-col-1-cards .board-card", "Keep me open")
      refute has_element?(view, "#stage-strip-#{backlog.id}")

      # empty Spec: strip with rotated name + count 0, no expanded column
      assert has_element?(view, "#stage-strip-#{spec.id}.stage-strip", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-strip-name", "Spec")
      assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-2-cards")

      strip_html = view |> element("#stage-strip-#{spec.id}") |> render()
      assert strip_html =~ "width:44px"
      assert strip_html =~ "writing-mode:vertical-rl"
      assert strip_html =~ "border:1px dashed oklch(0.90 0.006 255)"
    end

    test "the strip is a DnD drop zone carrying its stage id", %{conn: conn, spec: spec} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-strip-#{spec.id}.stage-cards[data-stage-id='#{spec.id}']")
    end

    test "clicking a strip force-opens the empty stage for the session",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      expand_stage(view, backlog)

      refute has_element?(view, "#stage-strip-#{backlog.id}")
      assert has_element?(view, "#stage-col-1-cards .stage-empty", "No cards yet")

      # it stays expanded on subsequent renders, even while still empty
      assert render(view) =~ "stage-col-1-cards"
    end

    test "moving the last card out collapses the stage",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Last one"})

      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-strip-#{backlog.id}")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")
      refute has_element?(view, "#stage-col-1-cards")
    end

    test "moving a card onto a collapsed strip expands it and the card renders there",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Incoming"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-strip-#{spec.id}")

      # exactly what board_dnd.js pushes on a drop over the strip (index 0 — empty zone)
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "#{spec.id}", "index" => 0})

      refute has_element?(view, "#stage-strip-#{spec.id}")
      assert has_element?(view, "#stage-col-2-cards .board-card", "Incoming")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "a stage whose only card sits in a sub-lane does not collapse",
         %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)
      insert(:card, stage: review, title: "In review", position: 1, ref_number: 9)

      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-strip-#{code.id}")
      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "In review")
    end
  end
  ```

  And at the bottom of the module, next to `stage_titles/2`:

  ```elixir
  defp expand_stage(view, stage) do
    view |> element("#stage-strip-#{stage.id}") |> render_click()
  end
  ```

- [x] **Write the failing two-session realtime test** (spec: "emptying a stage in one session collapses it in another"). In `test/relay_web/live/board_live_realtime_test.exs`, add inside `describe "two sessions on the same board"`:

  ```elixir
  test "emptying a stage in session A collapses it to a strip in session B",
       %{conn: conn, backlog: backlog, spec: spec} do
    {:ok, _card} = Cards.create_card(backlog, %{title: "Last one"})

    {:ok, view_a, _html} = live(conn, ~p"/board")
    {:ok, view_b, _html} = live(conn, ~p"/board")

    refute has_element?(view_b, "#stage-strip-#{backlog.id}")

    render_hook(view_a, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

    assert has_element?(view_b, "#stage-strip-#{backlog.id} .stage-count", "0")
    assert has_element?(view_b, "#stage-col-2-cards .board-card", "Last one")
  end
  ```

- [x] Run `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs` — expect the new tests to FAIL (BoardLive never sets `collapsed`).

- [x] **Implement in `lib/relay_web/live/board_live.ex`.**

  1. In `mount/3`, extend the assign pipeline (directly after `|> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))`):

     ```elixir
     |> assign(:force_open, MapSet.new())
     ```

  2. In `render/1`, add to the `<.stage_column` call (after `stage_id={stage.id}`):

     ```heex
     collapsed={stage_collapsed?(stage, @stage_counts, @sublanes_by_parent, @force_open)}
     ```

  3. Add the event handler immediately after the `"move_card"` clause (keeping `handle_event/3` clauses adjacent):

     ```elixir
     # MMF 12c — clicking a collapsed stage/lane strip force-opens it for this
     # session only (a MapSet in the socket; not persisted, not broadcast).
     def handle_event("expand_stage", %{"stage-id" => stage_id}, socket) do
       case parse_int(stage_id) do
         nil -> {:noreply, socket}
         id -> {:noreply, update(socket, :force_open, &MapSet.put(&1, id))}
       end
     end
     ```

  4. Add the predicate after `stage_counts/2`:

     ```elixir
     # MMF 12c — a stage auto-collapses to the mockup's strip only when it is
     # empty across its main lane AND all its sub-lanes, and the user hasn't
     # force-opened it this session (mockup: collapsed = all.length === 0).
     defp stage_collapsed?(%Stage{} = stage, stage_counts, sublanes_by_parent, force_open) do
       total =
         sublanes_by_parent
         |> Map.get(stage.id, [])
         |> Enum.reduce(Map.fetch!(stage_counts, stage.id), fn sub, acc ->
           acc + Map.fetch!(stage_counts, sub.id)
         end)

       total == 0 and not MapSet.member?(force_open, stage.id)
     end
     ```

- [x] Run `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs` — the NEW tests pass; several PRE-EXISTING tests now fail because empty stages collapse. These are deliberate contract updates, not regressions — fix each exactly as in the next step.

- [x] **Update the pre-existing tests** to the collapse-aware board:

  In `test/relay_web/live/board_live_test.exs`:

  1. Replace the whole test `"groups the stages under their category bands in order"` with:

     ```elixir
     test "groups the stages under their category bands in order", %{conn: conn, user: user} do
       board = Boards.get_or_create_default_board(user)
       [backlog, spec, plan, code, review, deploy, done] = board.stages

       {:ok, view, _html} = live(conn, ~p"/board")

       assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
       assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
       assert has_element?(view, "#category-complete h2.category-band", "Complete")

       # a fresh board is empty, so every stage renders as its collapsed strip
       assert has_element?(view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
       assert has_element?(view, "#category-unstarted #stage-strip-#{spec.id}", "Spec")
       assert has_element?(view, "#category-in_progress #stage-strip-#{plan.id}", "Plan")
       assert has_element?(view, "#category-in_progress #stage-strip-#{code.id}", "Code")
       assert has_element?(view, "#category-in_progress #stage-strip-#{review.id}", "Review")
       assert has_element?(view, "#category-in_progress #stage-strip-#{deploy.id}", "Deploy")
       assert has_element?(view, "#category-complete #stage-strip-#{done.id}", "Done")

       bands =
         view
         |> render()
         |> LazyHTML.from_fragment()
         |> LazyHTML.query("#board .category-band")
         |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

       assert bands == ["Unstarted", "In progress", "Complete"]
     end
     ```

     (The `"renders the stage columns in position order"` test above it needs NO change — the strip keeps class `stage-column` and renders the name in an `<h3>`, so `#board .stage-column h3` still yields the 7 names in position order. Same reason the Playwright smoke test keeps passing.)

  2. Replace the whole test `"shows the right Human/AI owner swatch on each stage"` with:

     ```elixir
     test "shows the right Human/AI owner swatch on each stage", %{conn: conn, user: user} do
       board = Boards.get_or_create_default_board(user)

       {:ok, view, _html} = live(conn, ~p"/board")

       for stage <- board.stages do
         assert has_element?(
                  view,
                  ~s(#stage-strip-#{stage.id} .stage-owner-swatch[data-owner="#{stage.owner}"])
                )
       end
     end
     ```

  3. Replace the whole test `"every stage shows the empty-state placeholder"` with:

     ```elixir
     test "a fresh board collapses every empty stage to a strip", %{conn: conn} do
       {:ok, view, _html} = live(conn, ~p"/board")

       document = view |> render() |> LazyHTML.from_fragment()

       assert document |> LazyHTML.query("#board .stage-strip") |> Enum.count() == 7
       assert document |> LazyHTML.query("#board .stage-empty") |> Enum.count() == 0
     end
     ```

  4. In `describe "cards"`, five tests click `#stage-col-1-new-card` on an empty Backlog, which is now a strip. In each, take `backlog` from the setup context and expand first:
     - `"a stage's compose CTA reveals the composer for that stage only"`: signature → `%{conn: conn, backlog: backlog}`; insert `expand_stage(view, backlog)` between the `live/2` call and the first `refute`.
     - `"submitting the composer creates a card in that stage and clears the input"` (already has `backlog`): insert `expand_stage(view, backlog)` after the `live/2` call.
     - `"creating cards assigns per-board incrementing refs shown on the cards"`: signature → `%{conn: conn, backlog: backlog}`; insert `expand_stage(view, backlog)` after `live/2`.
     - `"cancel closes the composer without creating a card"`: signature → `%{conn: conn, backlog: backlog}`; insert `expand_stage(view, backlog)` after `live/2`. (Force-open keeps the stage expanded after cancel, so the existing assertions hold.)
     - `"submitting a blank title keeps the composer open and creates nothing"`: signature → `%{conn: conn, backlog: backlog}`; insert `expand_stage(view, backlog)` after `live/2`.

  5. In `"cards render in their own stage; other stages keep the empty state"` (same describe): signature → `%{conn: conn, backlog: backlog, board: board}`; add `[_backlog, spec | _rest] = board.stages` as the first line; replace `assert has_element?(view, "#stage-col-2-cards .stage-empty")` with:

     ```elixir
     assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
     ```

  6. In `describe "lane counts"`, replace `"every stage renders its card count"` with:

     ```elixir
     test "every stage renders its card count", %{conn: conn, board: board, backlog: backlog} do
       insert(:card, stage: backlog, title: "One", position: 1, ref_number: 1)
       insert(:card, stage: backlog, title: "Two", position: 2, ref_number: 2)

       {:ok, view, _html} = live(conn, ~p"/board")

       assert has_element?(view, "#stage-col-1 .stage-count", "2")

       for stage <- tl(board.stages) do
         assert has_element?(view, "#stage-strip-#{stage.id} .stage-count", "0")
       end
     end
     ```

     and replace `"creating a card bumps its stage's count"` with:

     ```elixir
     test "creating a card bumps its stage's count", %{conn: conn, board: board, backlog: backlog} do
       [_backlog, spec | _rest] = board.stages

       {:ok, view, _html} = live(conn, ~p"/board")

       expand_stage(view, backlog)
       view |> element("#stage-col-1-new-card") |> render_click()
       view |> form("#stage-col-1-compose-form", card: %{title: "Count me"}) |> render_submit()

       assert has_element?(view, "#stage-col-1 .stage-count", "1")
       assert has_element?(view, "#stage-strip-#{spec.id} .stage-count", "0")
     end
     ```

  7. In `describe "moving cards"`, test `"moving updates both lane counts"`: replace `assert has_element?(view, "#stage-col-1 .stage-count", "0")` with `assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")`.

  8. In `describe "drawer move menu"`, test `"moving from the drawer persists like a drag and appends to the bottom"`: signature → `%{conn: conn, backlog: backlog, spec: spec, card: card}`; replace `assert has_element?(view, "#stage-col-1 .stage-count", "0")` with `assert has_element?(view, "#stage-strip-#{backlog.id} .stage-count", "0")`.

  9. In `describe "sub-lanes"`, test `"renders a stage's review sub-lane stacked with its own count"`: add as the first line of the test body (Code is otherwise empty and would collapse the whole stage):

     ```elixir
     insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)
     ```

  (No changes needed elsewhere in this file: `"a move_card event moves..."` / `"a ref that is not on this board..."` only `refute` on `.board-card` inside containers that may be gone — vacuously true; `describe "drag-and-drop wiring"` seeds a Backlog card and its zone-count test still finds exactly 7 `.stage-cards[data-stage-id]`, because the 6 empty-stage strips ARE zones; all baton/drawer/timeline describes seed cards into the stages they assert on.)

  In `test/relay_web/live/board_live_realtime_test.exs`:

  10. `"a card created in session A appears in session B with the count bumped"`: signature → `%{conn: conn, backlog: backlog}`; insert before the `#stage-col-1-new-card` click:

      ```elixir
      view_a |> element("#stage-strip-#{backlog.id}") |> render_click()
      ```

  11. `"a move in session A restreams source and target in session B"`: replace `assert has_element?(view_b, "#stage-col-1 .stage-count", "0")` with `assert has_element?(view_b, "#stage-strip-#{backlog.id} .stage-count", "0")`.

  12. `"a mutation on board A does not touch a session on board B"` (board scoping): change `_board_b = Boards.get_or_create_default_board(other_user)` to:

      ```elixir
      board_b = Boards.get_or_create_default_board(other_user)
      [backlog_b | _rest] = board_b.stages
      ```

      and replace `assert has_element?(view_b, "#stage-col-1 .stage-count", "0")` with `assert has_element?(view_b, "#stage-strip-#{backlog_b.id} .stage-count", "0")`.

  13. `"enabling and disabling a lane restructures another open session"`: insert before `{:ok, view_b, _html} = live(conn, ~p"/board")` (Code must hold a card or the whole stage collapses):

      ```elixir
      {:ok, _card} = Cards.create_card(code, %{title: "Keep Code expanded"})
      ```

  14. In `describe "stage configuration changes reflect on open boards (MMF 12)"`:
      - `"a rename in one session's settings renders on another session's board"`: replace `assert has_element?(board_view, "#stage-col-#{code.position} h3", "Build")` with `assert has_element?(board_view, "#stage-strip-#{code.id} h3", "Build")` (the empty Code stage now renders — and live-renames — as a strip).
      - `"reordering swaps the columns and keeps card streams attached"`: replace the two h3 assertions with:

        ```elixir
        assert has_element?(board_view, "#stage-strip-#{spec.id} h3", "Spec")
        assert has_element?(board_view, "#stage-col-2 h3", "Backlog")
        ```

        (Backlog holds "Ride along" so it renders expanded at its new position 2; empty Spec is a strip. Keep the final `#stage-col-2-cards .board-card` assertion.)
      - `"adding and deleting stages restructures the open board"`: NO change — the new empty stage's strip still renders "New stage" in an `h3` inside `#category-unstarted`, and the deleted Deploy strip disappears.

  In `test/relay_web/live/board_settings_stages_test.exs`:

  15. `"renaming persists and shows on a freshly mounted board"`: replace `assert has_element?(board_view, "#stage-col-#{code.position} h3", "Build")` with `assert has_element?(board_view, "#stage-strip-#{code.id} h3", "Build")`.

- [x] Run all touched suites — expect PASS:
  `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs test/relay_web/live/board_settings_stages_test.exs test/relay_web/components/core_components_test.exs`

- [x] **Refresh the storybook story.** In `storybook/core_components/stage_column.story.exs`, add a variation after `:empty_human`:

  ```elixir
  %Variation{
    id: :collapsed_empty,
    description: "An empty stage auto-collapses to the 44px dashed strip (MMF 12c)",
    attributes: %{
      id: "story-stage-collapsed",
      name: "Deploy",
      owner: :ai,
      stage_id: 6,
      count: 0,
      collapsed: true
    }
  },
  ```

- [x] Run `mix precommit` — must be fully green. Fix any format/credo fallout before committing.

**Deliverable:** an empty stage on `/board` renders the mockup-exact 44px dashed strip (owner swatch, rotated name, mono count 0), click force-opens it for the session, it works as a DnD drop target that expands on receiving a card, it collapses live in every session when its last card leaves, and non-empty stages render the full column unchanged. Full suite + precommit green.

**Commit message:** `feat(board): auto-collapse empty stages into mockup strips (MMF 12c)`

---

### Task 2: Collapsed sub-lane strip (empty Review/Done lanes inside an expanded stage)

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`stage_column/1` sub-lane rendering + width)
- Modify: `lib/relay_web/live/board_live.ex` (pass `collapsed:` per sub-lane; `sublane_collapsed?/3`)
- Modify: `storybook/core_components/stage_column.story.exs` (empty-sub-lane variation)
- Tests: additions to `test/relay_web/components/core_components_test.exs` and `test/relay_web/live/board_live_test.exs`; one assertion update in `test/relay_web/live/board_live_realtime_test.exs`

**Interfaces**

*Consumes (from Task 1):*
- `stage_column/1` with `attr :collapsed, :boolean, default: false` and the `:total_count` assign; the strip conventions (`stage-cards` class + `data-stage-id` + `phx-click="expand_stage"` + `phx-value-stage-id`).
- `RelayWeb.BoardLive`: `:force_open` MapSet assign; `handle_event("expand_stage", %{"stage-id" => stage_id}, socket)` (works unchanged for lane strips — sub-lanes are Stage rows with unique ids); `stage_collapsed?/4` (unchanged — it already counts sub-lanes, so a card in a sub-lane keeps the parent expanded).
- Existing component helpers: `lane_color/1`, `lane_tint/1`, `lane_divider/1` (`:review` → `oklch(0.52 0.12 65)` / `oklch(0.966 0.032 75)` / `oklch(0.90 0.04 75)`; `:done` → `oklch(0.47 0.11 155)` / `oklch(0.964 0.03 155)` / `oklch(0.90 0.035 155)`).

*Produces:*
- `stage_column/1`: each `sublanes` entry accepts an optional `collapsed: boolean` key, defaulted to `false` via `Map.put_new/3` so existing callers/stories keep working. A collapsed sub-lane renders `<div id={"sublane-#{sub.id}-strip"} class="sublane-strip stage-cards" data-stage-id={sub.id} phx-click="expand_stage" phx-value-stage-id={sub.id}>` — a 34px strip with a 6px dot, rotated mono label, and mono count. Stage width becomes `240 + Σ (34 if collapsed | 178 if expanded)`.
- `RelayWeb.CoreComponents` private `sublane_width/1` (`%{collapsed: true}` → 34, else 178).
- `RelayWeb.BoardLive` private `sublane_collapsed?(sub, stage_counts, force_open)` (arity 3, first arg the child `%Schemas.Stage{}`).

**Steps**

- [ ] **Write the failing component test.** Append inside `describe "stage_column/1"` in `test/relay_web/components/core_components_test.exs`:

  ```elixir
  test "an empty collapsed sub-lane renders the 34px strip; a non-collapsed one renders expanded" do
    html =
      render_component(&CoreComponents.stage_column/1,
        id: "stage-col-4",
        name: "Code",
        owner: :ai,
        stage_id: 4,
        count: 1,
        board_key: "RLY",
        cards: [
          {"cards-1", %{title: "Main work", tag: nil, ref_number: 1, status: :queued, progress: nil, owners: []}}
        ],
        sublanes: [
          %{id: 401, name: "Review", lane: :review, owner: :human, count: 0, cards: [], collapsed: true},
          %{id: 402, name: "Done", lane: :done, owner: :ai, count: 0, cards: []}
        ]
      )

    # collapsed Review lane: 34px strip (mockup lines ~1028–1037)
    assert html =~ ~s(id="sublane-401-strip")
    assert html =~ "flex:0 0 34px"
    assert html =~ "width:6px;height:6px;border-radius:50%"
    assert html =~ "opacity:0.6"
    assert html =~ "writing-mode:vertical-rl"
    # lane colour + the same left divider as an expanded lane
    assert html =~ "oklch(0.52 0.12 65)"
    assert html =~ "border-left:1px solid oklch(0.90 0.04 75)"
    # drop target + click-to-expand contract
    assert html =~ ~s(data-stage-id="401")
    assert html =~ ~s(phx-value-stage-id="401")
    refute html =~ ~s(id="sublane-401-cards")

    # Done lane was not marked collapsed: renders expanded as before
    assert html =~ ~s(id="sublane-402-cards")
    refute html =~ ~s(id="sublane-402-strip")

    # stage width: 240 (main) + 34 (strip) + 178 (expanded) = 452
    assert html =~ "width:452px"
  end
  ```

- [ ] Run `mix test test/relay_web/components/core_components_test.exs` — expect the new test to FAIL.

- [ ] **Implement in `stage_column/1`** (`lib/relay_web/components/core_components.ex`).

  1. Update the `sublanes` attr doc:

     ```elixir
     attr :sublanes, :list,
       default: [],
       doc:
         "the stage's Review/Done child lanes, each a %{id, name, lane, owner, count, cards} " <>
           "with an optional collapsed: true to render the lane as its 34px strip (MMF 12c)"
     ```

  2. Replace the assigns pipeline at the top of `def stage_column(assigns)` (normalize `collapsed`; width now sums per-lane):

     ```elixir
     def stage_column(assigns) do
       sublanes = Enum.map(assigns.sublanes, &Map.put_new(&1, :collapsed, false))

       assigns =
         assigns
         |> assign(:sublanes, sublanes)
         |> assign(:labeled, sublanes != [])
         |> assign(:stage_width, 240 + Enum.sum(Enum.map(sublanes, &sublane_width/1)))
         |> assign(:total_count, (assigns.count || 0) + Enum.sum(Enum.map(sublanes, & &1.count)))
     ```

  3. Replace the sub-lane block — from the `<%!-- Review / Done sub-lanes, side by side --%>` comment through the closing `</div>` of the `:for={sub <- @sublanes}` div — with (the `:if={!sub.collapsed}` branch is today's expanded markup verbatim):

     ```heex
     <%!-- Review / Done sub-lanes, side by side; empty ones collapse to 34px strips --%>
     <%= for sub <- @sublanes do %>
       <div
         :if={sub.collapsed}
         id={"sublane-#{sub.id}-strip"}
         class="sublane-strip stage-cards"
         data-stage-id={sub.id}
         phx-click="expand_stage"
         phx-value-stage-id={sub.id}
         aria-label={"Expand #{sub.name} lane"}
         style={"flex:0 0 34px;width:34px;display:flex;flex-direction:column;align-items:center;gap:9px;padding:12px 0;box-sizing:border-box;background:#{lane_tint(sub.lane)};border-left:1px solid #{lane_divider(sub.lane)};cursor:pointer;"}
       >
         <span
           class="sublane-strip-dot"
           style={"width:6px;height:6px;border-radius:50%;background:#{lane_color(sub.lane)};opacity:0.6;flex:0 0 auto;"}
         >
         </span>
         <span
           class="sublane-strip-name"
           style={"writing-mode:vertical-rl;transform:rotate(180deg);font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(sub.lane)};white-space:nowrap;"}
         >
           {sub.name}
         </span>
         <span
           class="sublane-strip-count"
           style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(sub.lane)};opacity:0.7;flex:0 0 auto;"}
         >
           {sub.count}
         </span>
       </div>
       <div
         :if={!sub.collapsed}
         id={"sublane-#{sub.id}"}
         style={"flex:0 0 178px;width:178px;min-width:0;display:flex;flex-direction:column;box-sizing:border-box;background:#{lane_tint(sub.lane)};border-left:1px solid #{lane_divider(sub.lane)};"}
       >
         <div style="display:flex;align-items:center;gap:6px;padding:11px 13px 7px 13px;flex:0 0 auto;">
           <span style={"font-size:10px;font-weight:600;letter-spacing:0.05em;font-family:var(--font-mono);color:#{lane_color(sub.lane)};"}>
             {sub.name}
           </span>
           <span style={"font-size:10px;font-family:var(--font-mono);color:#{lane_color(sub.lane)};opacity:0.7;"}>
             {sub.count}
           </span>
         </div>
         <div
           id={"sublane-#{sub.id}-cards"}
           phx-update="stream"
           data-stage-id={sub.id}
           class="stage-cards"
           style="flex:1;min-height:0;overflow-y:auto;overflow-x:hidden;display:flex;flex-direction:column;gap:8px;padding:0 13px 13px 13px;"
         >
           <div
             id={"sublane-#{sub.id}-empty"}
             class="stage-empty hidden only:block"
             style="border:1px dashed var(--color-base-300);border-radius:8px;padding:14px 8px;text-align:center;font-size:11px;font-family:var(--font-mono);color:oklch(0.70 0.02 255);"
           >
             Empty
           </div>
           <.board_card
             :for={{dom_id, card} <- sub.cards}
             id={dom_id}
             title={card.title}
             tag={card.tag}
             ref={"#{@board_key}-#{card.ref_number}"}
             status={card.status}
             progress={card.progress}
             owners={card.owners}
             active_owner={Cards.active_owner_type(card)}
             stage_owner={sub.owner}
             lane={sub.lane}
             category={@category}
           />
         </div>
       </div>
     <% end %>
     ```

  4. Add the width helper next to `lane_color/1` (around line 810):

     ```elixir
     defp sublane_width(%{collapsed: true}), do: 34
     defp sublane_width(_sub), do: 178
     ```

- [ ] Run `mix test test/relay_web/components/core_components_test.exs` — expect PASS (including the untouched Task 1 and pre-existing stage_column tests).

- [ ] **Write the failing BoardLive tests.** In `test/relay_web/live/board_live_test.exs`, add a new describe after `describe "collapsed empty stages (MMF 12c)"` (mirrors the existing "sub-lanes" describe's session setup):

  ```elixir
  describe "collapsed empty sub-lanes (MMF 12c)" do
    setup %{conn: conn} do
      user = insert(:user)
      board = Boards.get_or_create_default_board(user)
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Boards.enable_lane(code, :review)

      %{
        conn: Plug.Test.init_test_session(conn, user_id: user.id),
        board: board,
        code: code,
        review: review
      }
    end

    test "an empty review sub-lane renders its 34px strip inside the expanded stage",
         %{conn: conn, code: code, review: review} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#sublane-#{review.id}-strip.sublane-strip.stage-cards[data-stage-id='#{review.id}']"
             )

      assert has_element?(view, "#sublane-#{review.id}-strip .sublane-strip-name", "Review")
      assert has_element?(view, "#sublane-#{review.id}-strip .sublane-strip-count", "0")
      refute has_element?(view, "#sublane-#{review.id}-cards")

      strip_html = view |> element("#sublane-#{review.id}-strip") |> render()
      assert strip_html =~ "flex:0 0 34px"
      assert strip_html =~ "writing-mode:vertical-rl"
      assert strip_html =~ "oklch(0.52 0.12 65)"
    end

    test "a sub-lane with a card renders expanded", %{conn: conn, review: review} do
      insert(:card, stage: review, title: "Please review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "Please review")
      refute has_element?(view, "#sublane-#{review.id}-strip")
    end

    test "moving a card onto the sub-lane strip expands it and the card renders there",
         %{conn: conn, code: code, review: review} do
      card = insert(:card, stage: code, title: "Ready for review", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#sublane-#{review.id}-strip")

      render_hook(view, "move_card", %{
        "ref" => "RLY-#{card.ref_number}",
        "stage_id" => review.id,
        "index" => 0
      })

      refute has_element?(view, "#sublane-#{review.id}-strip")
      assert has_element?(view, "#sublane-#{review.id}-cards .board-card", "Ready for review")
    end

    test "clicking the sub-lane strip force-opens the empty lane",
         %{conn: conn, code: code, review: review} do
      insert(:card, stage: code, title: "Main work", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#sublane-#{review.id}-strip") |> render_click()

      refute has_element?(view, "#sublane-#{review.id}-strip")
      assert has_element?(view, "#sublane-#{review.id}-cards .stage-empty", "Empty")
    end
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect the new describe to FAIL (BoardLive never passes `collapsed:` for sub-lanes yet).

- [ ] **Implement in `lib/relay_web/live/board_live.ex`.**

  1. In `render/1`, add the `collapsed` key to the sublane map:

     ```heex
     sublanes={
       for sub <- Map.get(@sublanes_by_parent, stage.id, []) do
         %{
           id: sub.id,
           name: lane_label(sub.lane),
           lane: sub.lane,
           owner: sub.owner,
           count: Map.fetch!(@stage_counts, sub.id),
           cards: Map.fetch!(@streams, stream_name(sub.id)),
           collapsed: sublane_collapsed?(sub, @stage_counts, @force_open)
         }
       end
     }
     ```

  2. Add the predicate directly under `stage_collapsed?/4`:

     ```elixir
     # MMF 12c — a Review/Done sub-lane collapses to its 34px strip when empty
     # and not force-opened (mockup: laneCollapsed = isSub && laneCards.length === 0).
     defp sublane_collapsed?(%Stage{} = sub, stage_counts, force_open) do
       Map.fetch!(stage_counts, sub.id) == 0 and not MapSet.member?(force_open, sub.id)
     end
     ```

     (The Task 1 `expand_stage` handler already covers lane strips — no new event.)

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — new describe passes. Then run `mix test test/relay_web/live/board_live_realtime_test.exs` — one test now fails because the freshly enabled (empty) Review lane renders as a strip; update it:

  In `test/relay_web/live/board_live_realtime_test.exs`, test `"enabling and disabling a lane restructures another open session"`, replace the two assertions:

  ```elixir
  {:ok, review} = Boards.enable_lane(code, :review)
  assert has_element?(view_b, "#sublane-#{review.id}-strip")

  {:ok, :disabled} = Boards.disable_lane(code, :review)
  refute has_element?(view_b, "#sublane-#{review.id}-strip")
  ```

  (The `"renders a stage's review sub-lane stacked with its own count"` test in `board_live_test.exs` needs NO further change: its `html =~ "sublane-#{review.id}"` assertion matches the strip's `sublane-<id>-strip` id as a substring, and `"Review"` is the strip label. The `"a card moved into the review sub-lane renders there"` test also holds: the lane starts as a strip, the `move_card` hook fires regardless of DOM, and the post-move assertion targets the now-expanded `#sublane-<id>-cards`.)

- [ ] Run `mix test test/relay_web/live/board_live_realtime_test.exs` — expect PASS.

- [ ] **Refresh the storybook story.** In `storybook/core_components/stage_column.story.exs`, add after the `:with_sublanes` variation:

  ```elixir
  %Variation{
    id: :with_collapsed_sublanes,
    description: "Empty Review/Done sub-lanes collapse to 34px strips (MMF 12c)",
    attributes: %{
      id: "story-stage-collapsed-sublanes",
      name: "Code",
      owner: :ai,
      stage_id: 5,
      count: 1,
      board_key: "RLY",
      category: :in_progress,
      cards: [
        {"story-card-5",
         %{
           title: "Implement the API",
           tag: "api",
           ref_number: 5,
           status: :working,
           progress: 30,
           owners: [%{actor_type: :agent}]
         }}
      ],
      sublanes: [
        %{id: 501, name: "Review", lane: :review, owner: :human, count: 0, cards: [], collapsed: true},
        %{id: 502, name: "Done", lane: :done, owner: :ai, count: 0, cards: [], collapsed: true}
      ]
    }
  },
  ```

- [ ] Run `mix precommit` — the full gate must be green (this also re-proves the side-by-side lane layout, DnD wiring, MMF 06 baton rendering, and MMF 18 realtime suites against both collapse levels).

**Deliverable:** inside an expanded stage, an empty Review/Done sub-lane renders the mockup's 34px strip (6px lane-colour dot at 0.6 opacity, rotated mono label, mono count) with the same left divider as an expanded lane; it accepts drops (expanding with the arriving card) and click-expands for the session; non-empty sub-lanes render exactly as before; the stage card width shrinks to fit (240 + 34/178 per lane). Storybook shows both collapse levels. Full suite + precommit green.

**Commit message:** `feat(board): auto-collapse empty sub-lanes into 34px strips (MMF 12c)`
