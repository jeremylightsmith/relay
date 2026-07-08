# MMF 12d — Category model: add `:planning` + fix cross-category reorder

**Spec:** `docs/superpowers/specs/2026-07-08-category-model-design.md`
**Branch discipline:** trunk-based on `main`.

## Goal

Two coupled changes to the stage-category model:

1. **Fix the cross-category reorder bug.** `Relay.Boards.reorder_stage/2` currently delegates to
   `swap_stages/2`, which swaps **both position and category** between the moved stage and its
   board-order neighbour ("a true exchange"). At a category boundary the neighbour is in a
   *different* category, so the swap drags the neighbour into the moved stage's old category:
   moving the last `:unstarted` stage down makes the moved stage `:in_progress` (right) **but also
   makes the first `:in_progress` stage `:unstarted`** (wrong — it "comes up"). The fix is
   **one-directional adoption**: only the moved stage ever changes category.
2. **Add a `:planning` category** between `:unstarted` and `:in_progress` (order:
   `[:unstarted, :planning, :in_progress, :complete]`), with label ("Planning"/"PLANNING") and a
   distinct violet dot everywhere the other three categories have chrome. The seeded `Plan` stage
   moves from `:in_progress` to `:planning` (keeping owner `:ai`). No DB migration — `category`
   is a string-backed `Ecto.Enum`.

### New reorder semantics (the contract)

- **Same-category neighbour in the move direction** → the two stages **swap positions**;
  categories untouched (unchanged behaviour).
- **No same-category neighbour** (the stage is first in its category moving up, or last moving
  down — the board-order neighbour is in another category or absent) → the stage crosses
  **one-directionally** into the **immediately adjacent category in `@category_order`** (even if
  that category is **empty** — never skip past it), adopting that category and landing at its
  **edge**: **top** of the next category moving down, **bottom** of the previous category moving
  up. **No other stage's category or relative order changes.** Because a category's stages are
  contiguous in position order, this landing spot keeps the flat board order unchanged — only
  the moved stage's `category` field changes.
- **No adjacent category** (already in `:unstarted` moving up, or `:complete` moving down) →
  no-op: `{:ok, stage}`, **no broadcast**.
- Implementation is robust against the `stages_board_id_position_index` unique index: inside one
  transaction, park the board's main stages out of range (`+@position_park_offset`), then
  re-number them 1..n in the new order, force-writing `position` and setting `category` **only on
  the moved stage**. (Sub-lane children always occupy positions above every main stage, so 1..n
  stays collision-free and children are untouched.)

## Architecture

Phoenix v1.8 + LiveView app. Domain contexts live under `Relay` (boundary-enforced; the web layer
only calls exported contexts). Relevant modules:

- `Relay.Boards` (`lib/relay/boards.ex`) — boards + stages context. Owns `@seed_stages`,
  `@category_order`, `reorder_stage/2`, `create_stage/2`, the `@position_park_offset` parking
  mechanism, and broadcasts `Relay.Events.broadcast(board_id, {:stages_changed, board_id})` on
  every successful stage mutation (MMF 18) — **keep that**.
- `Schemas.Stage` (`lib/schemas/stage.ex`) — the stage schema; `category` is an `Ecto.Enum`.
- `RelayWeb.BoardLive` (`lib/relay_web/live/board_live.ex`) — the board. Groups stages under
  category bands via its own `@category_order` + `group_stages/1` (drops empty categories —
  keep), renders a dot (`category_dot_style/1`) + label (`category_label/1`) per band. Already
  handles `{:stages_changed, _}` by reloading the board.
- `RelayWeb.BoardSettingsLive` (`lib/relay_web/live/board_settings_live.ex`) — settings Stages
  pane. Shows **all** categories always (`@categories`), each with a
  `#settings-group-<category>` group, `category_band_label/1`, `category_dot_style/1`, and an
  `#add-stage-<category>` button wired to the `add_stage` event.
- `RelayWeb.CoreComponents` (`lib/relay_web/components/core_components.ex`) — `board_card` and
  `stage_column` components each declare `attr :category, :atom, values: [...]`.

## Tech

Elixir/Phoenix 1.8, Ecto (Postgres), Phoenix LiveView, ExMachina factories
(`test/support/factory.ex`), `Phoenix.LiveViewTest` + LazyHTML for LiveView tests.

## Global Constraints

- `mix precommit` is REQUIRED and must pass before a task is done: compile (warnings as errors),
  `mix format` (Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`, full test suite
  (warnings as errors). Never finish with it failing.
- Strict TDD: write the failing test first, watch it fail, then implement.
- Boundary is compiler-enforced: web code calls the domain only through `Relay`'s exported
  contexts. No new contexts are needed here.
- Keep the MMF 18 `{:stages_changed, board_id}` broadcast on every successful stage mutation
  (already wired via `broadcast_stages_changed/2`); edge no-ops stay silent.
- A reorder must **never** touch any card's `card_owners` rows.
- No DB migration (`category` is a string-backed enum).
- HEEx rules: `{...}` in attrs, list syntax for multi-value `class` attrs, `<.icon>` for icons,
  `<%!-- --%>` comments. Predicate functions end in `?`. Never `String.to_atom/1` on user input
  (the settings LiveView converts category params through explicit `category_atom/1` clauses —
  extend those, don't atomize).
- `test/relay_web/live/board_live_test.exs` asserts the seeded board renders **7 stages** — the
  seed keeps 7 stages; only `Plan`'s category changes.

---

### Task 1: Add `:planning` end-to-end and rewrite `reorder_stage/2` as one-directional

**Files**

- Modify: `lib/schemas/stage.ex`
- Modify: `lib/relay/boards.ex`
- Modify: `lib/relay_web/live/board_live.ex`
- Modify: `lib/relay_web/live/board_settings_live.ex`
- Test (modify): `test/relay/boards_test.exs`
- Test (modify): `test/relay/boards_stage_config_test.exs`
- Test (modify): `test/relay_web/live/board_live_test.exs`
- Test (modify): `test/relay_web/live/board_settings_stages_test.exs`

**Interfaces**

- Consumes (existing, unchanged): `Relay.Boards.get_or_create_default_board/1`,
  `Relay.Boards.list_stages/1`, `Relay.Boards.get_stage/2`, `Relay.Boards.delete_stage/1`,
  `Relay.Boards.enable_lane/2`, `Relay.Boards.create_stage/2` (its
  `when category in @category_order` guard picks up `:planning` automatically),
  `Schemas.Stage.changeset/2`, `Relay.Events.subscribe/1`, factories `insert(:card, stage: ...)`,
  `insert(:card_owner, card: ..., user: ...)`, `insert(:user)`.
- Produces (Task 2 relies on these):
  - `Schemas.Stage` `category` enum: `[:unstarted, :planning, :in_progress, :complete]`.
  - `Relay.Boards.reorder_stage(%Schemas.Stage{lane: :main}, :up | :down) :: {:ok, %Schemas.Stage{}}`
    with the one-directional semantics above (private helpers `cross_category/3`,
    `persist_order/3`, `renumber!/4`; `swap_stages/2` is deleted).
  - `@seed_stages` seeds `{"Plan", :ai, :planning}` — a fresh board has Plan in `:planning`.
  - `RelayWeb.BoardLive`: `@category_order` includes `:planning`;
    `category_label(:planning) => "Planning"`; `category_dot_style(:planning)` returns the violet
    quarter-conic style (below). Board renders a `#category-planning` band when non-empty.
  - `RelayWeb.BoardSettingsLive`: `@categories` includes `:planning`;
    `category_band_label(:planning) => "PLANNING"`; `category_dot_style(:planning)` (same style);
    `category_atom("planning") => :planning`; the `add_stage` event guard accepts `"planning"`.
    Settings always renders `#settings-group-planning` with `#add-stage-planning`.

**Steps**

- [x] Update the seed expectation in `test/relay/boards_test.exs`. Find the line

  ```elixir
               %Stage{name: "Plan", position: 3, owner: :ai, category: :in_progress},
  ```

  and replace it with

  ```elixir
               %Stage{name: "Plan", position: 3, owner: :ai, category: :planning},
  ```

- [x] In `test/relay/boards_stage_config_test.exs`, add a `categories/1` helper right after the
  existing `stage_named/2` helper (near the top of the module):

  ```elixir
  defp categories(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(&1.lane == :main))
    |> Enum.map(& &1.category)
  end
  ```

  Then replace the ENTIRE existing `describe "reorder_stage/2" do ... end` block with:

  ```elixir
  describe "reorder_stage/2" do
    test ":up swaps with the stage above within a category" do
      board = seeded_board()

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :up)
      assert moved.category == :unstarted
      assert main_names(board) == ["Spec", "Backlog", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test ":down across a boundary adopts the next category and leaves the neighbour untouched" do
      board = seeded_board()
      plan = stage_named(board, "Plan")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :down)

      # Spec alone crosses the band, landing at the TOP of Planning: the flat
      # board order is unchanged. Plan — which the old bidirectional swap
      # dragged up into :unstarted (the reported bug) — stays put.
      assert moved.category == :planning
      assert Boards.get_stage(board, plan.id).category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]

      assert categories(board) ==
               [:unstarted, :planning, :planning, :in_progress, :in_progress, :in_progress, :complete]
    end

    test ":up across a boundary adopts the previous category and leaves the neighbour untouched" do
      board = seeded_board()
      spec = stage_named(board, "Spec")

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Plan"), :up)

      # Plan lands at the BOTTOM of Unstarted; Spec keeps its category.
      assert moved.category == :unstarted
      assert Boards.get_stage(board, spec.id).category == :unstarted
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test ":down into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Spec"), :down)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Code", "Review", "Deploy", "Done"]

      # A second :down crosses on into In progress, again without touching Code.
      assert {:ok, again} = Boards.reorder_stage(Boards.get_stage(board, moved.id), :down)
      assert again.category == :in_progress
      assert Boards.get_stage(board, stage_named(board, "Code").id).category == :in_progress
    end

    test ":up into an empty adjacent category lands there instead of skipping past it" do
      board = seeded_board()
      {:ok, _} = Boards.delete_stage(stage_named(board, "Plan"))

      assert {:ok, moved} = Boards.reorder_stage(stage_named(board, "Code"), :up)
      assert moved.category == :planning
      assert main_names(board) == ["Backlog", "Spec", "Code", "Review", "Deploy", "Done"]
    end

    test "the first and last categories no-op at the board's edges" do
      board = seeded_board()

      assert {:ok, %{position: 1, category: :unstarted}} =
               Boards.reorder_stage(stage_named(board, "Backlog"), :up)

      assert {:ok, %{name: "Done", category: :complete}} =
               Boards.reorder_stage(stage_named(board, "Done"), :down)

      assert main_names(board) == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
    end

    test "swapping skips over sub-lane children" do
      board = seeded_board()
      {:ok, _child} = Boards.enable_lane(stage_named(board, "Code"), :review)

      assert {:ok, _moved} = Boards.reorder_stage(stage_named(board, "Review"), :up)
      assert main_names(board) == ["Backlog", "Spec", "Plan", "Review", "Code", "Deploy", "Done"]
    end

    test "reordering never touches card owners and keeps main positions contiguous" do
      board = seeded_board()
      code = stage_named(board, "Code")
      card = insert(:card, stage: code)
      owner_row = insert(:card_owner, card: card, user: insert(:user))

      {:ok, _} = Boards.reorder_stage(stage_named(board, "Spec"), :down)
      {:ok, _} = Boards.reorder_stage(Boards.get_stage(board, code.id), :up)

      assert [%CardOwner{} = row] = Repo.all(CardOwner)
      assert row.id == owner_row.id

      positions =
        board |> Boards.list_stages() |> Enum.filter(&(&1.lane == :main)) |> Enum.map(& &1.position)

      assert positions == Enum.to_list(1..7)
    end
  end
  ```

  Leave the `update_stage/2`, `create_stage/2`, `delete_stage/1`, and `broadcasts` describes
  untouched (they remain valid under the new semantics: `reorder_stage(backlog, :down)` in the
  broadcasts test is a same-category swap with Spec; `reorder_stage(backlog, :up)` in the
  silent-no-op test hits the no-adjacent-category branch).

- [x] Run `mix test test/relay/boards_test.exs test/relay/boards_stage_config_test.exs` — expect
  failures: the seed test fails (Plan is `:in_progress`), the boundary-crossing tests fail
  because the current `swap_stages/2` makes `moved.category == :in_progress` and drags the
  neighbour's category (the bug repro), and the empty-category tests fail too.

- [x] In `lib/schemas/stage.ex`, add `:planning` to the enum. Replace

  ```elixir
  field :category, Ecto.Enum, values: [:unstarted, :in_progress, :complete]
  ```

  with

  ```elixir
  field :category, Ecto.Enum, values: [:unstarted, :planning, :in_progress, :complete]
  ```

  and in the moduledoc change `(unstarted → in_progress → complete)` to
  `(unstarted → planning → in_progress → complete)`.

- [x] In `lib/relay/boards.ex`:

  1. Update the seed — replace `{"Plan", :ai, :in_progress},` with `{"Plan", :ai, :planning},`
     in `@seed_stages`.
  2. Replace `@category_order [:unstarted, :in_progress, :complete]` with
     `@category_order [:unstarted, :planning, :in_progress, :complete]`.
  3. Replace the whole `reorder_stage/2` `@doc` + function with:

     ```elixir
     @doc """
     Moves `stage` one step up or down among the board's main stages (`:up` =
     toward position 1), inside a transaction. With a same-category neighbour
     in the move direction the two stages swap positions (categories are
     untouched). When the stage is already first/last in its category it
     crosses one-directionally into the adjacent category in `@category_order`
     — adopting that category even when it is empty, landing at its edge (top
     when moving down, bottom when moving up) — and no other stage's category
     or relative order changes. Already in the first category moving up (or
     the last moving down) it is a no-op: `{:ok, stage}`, no broadcast.
     """
     def reorder_stage(%Stage{lane: :main} = stage, direction) when direction in [:up, :down] do
       mains = main_stages(stage.board_id)
       index = Enum.find_index(mains, &(&1.id == stage.id))
       stage = Enum.at(mains, index)
       neighbor_index = if direction == :up, do: index - 1, else: index + 1
       neighbor = fetch_neighbor(mains, neighbor_index)

       if neighbor && neighbor.category == stage.category do
         mains
         |> List.replace_at(index, neighbor)
         |> List.replace_at(neighbor_index, stage)
         |> persist_order(stage, stage.category)
       else
         cross_category(mains, stage, direction)
       end
     end
     ```

  4. Delete the private `swap_stages/2` function AND the comment block above it (the one
     beginning `# stages_board_id_position_index is not deferrable, so a direct swap` and ending
     `# the neighbour reverts to the category it had before the first swap.`).
  5. Generalize `fetch_neighbor/2`'s parameter name (it now also fetches from
     `@category_order`) — replace both clauses with:

     ```elixir
     defp fetch_neighbor(_list, index) when index < 0, do: nil
     defp fetch_neighbor(list, index), do: Enum.at(list, index)
     ```

  6. Add the new private helpers where `swap_stages/2` used to be:

     ```elixir
     # The stage is first/last in its category: it alone adopts the adjacent
     # category in @category_order (even an empty one — never skipping past
     # it). Because a category's stages are contiguous in position order,
     # landing at the adjacent category's near edge (top going down, bottom
     # going up) keeps the flat board order unchanged — only the moved
     # stage's category changes. No adjacent category -> silent no-op.
     defp cross_category(mains, stage, direction) do
       category_index = Enum.find_index(@category_order, &(&1 == stage.category))
       adjacent_index = if direction == :up, do: category_index - 1, else: category_index + 1

       case fetch_neighbor(@category_order, adjacent_index) do
         nil -> {:ok, stage}
         category -> persist_order(mains, stage, category)
       end
     end

     # Persists `ordered_mains` as the board's main-stage order, renumbering
     # positions 1..n and setting `category` on `moved` alone. The whole block
     # is parked out of range first so no renumbering step collides with the
     # stages_board_id_position_index unique index (sub-lane children always
     # sit above every main-stage position, so 1..n stays free and children
     # are untouched). Returns the broadcast-wrapped moved stage.
     defp persist_order(ordered_mains, %Stage{} = moved, category) do
       {:ok, updated} =
         Repo.transaction(fn ->
           ids = Enum.map(ordered_mains, & &1.id)
           parked = from s in Stage, where: s.id in ^ids
           Repo.update_all(parked, inc: [position: @position_park_offset])

           ordered_mains
           |> Enum.with_index(1)
           |> Enum.map(fn {stage, position} -> renumber!(stage, position, moved.id, category) end)
           |> Enum.find(&(&1.id == moved.id))
         end)

       broadcast_stages_changed({:ok, updated}, updated.board_id)
     end

     # `position` is force-changed: a stage's final position often equals its
     # stale in-memory one (cross-category moves keep the flat order), yet the
     # parked row still needs writing back to its real position.
     defp renumber!(stage, position, moved_id, category) do
       attrs = if stage.id == moved_id, do: %{category: category}, else: %{}

       stage
       |> Stage.changeset(attrs)
       |> Ecto.Changeset.force_change(:position, position)
       |> Repo.update!()
     end
     ```

- [x] Run `mix test test/relay/boards_test.exs test/relay/boards_stage_config_test.exs` — expect
  all green.

- [x] Add the minimal `:planning` chrome so the LiveViews render the new category without
  crashing (a seeded board now has a `:planning` stage, and the settings pane always renders
  every category — a missing `category_label/1` or `category_dot_style/1` clause is a
  `FunctionClauseError`).

  In `lib/relay_web/live/board_live.ex`:

  1. Replace `@category_order [:unstarted, :in_progress, :complete]` with
     `@category_order [:unstarted, :planning, :in_progress, :complete]`.
  2. After `defp category_label(:unstarted), do: "Unstarted"` insert:

     ```elixir
     defp category_label(:planning), do: "Planning"
     ```

  3. Update the dot comment — the existing one reads
     `# catMeta dots: a hollow ring (unstarted), a half-filled conic (in progress),` /
     `# and a solid green disc (complete).`; change it to
     `# catMeta dots: a hollow ring (unstarted), a quarter-filled violet conic` /
     `# (planning — where AI planning lives), a half-filled blue conic` /
     `# (in progress), and a solid green disc (complete).`
     Then, after the `category_dot_style(:unstarted)` clause, insert:

     ```elixir
     defp category_dot_style(:planning),
       do:
         "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, oklch(0.86 0.03 250) 25% 100%);display:block;flex:0 0 auto;"
     ```

     (Violet-leaning by design: `--color-secondary` is the app's AI/violet theme token; the style
     mirrors the `:in_progress` dot's conic pattern —
     `conic-gradient(var(--color-primary) 0 50%, oklch(0.86 0.03 250) 50% 100%)` — but at quarter
     fill with the violet hue, so all four dots stay distinct.)

  In `lib/relay_web/live/board_settings_live.ex`:

  4. Replace `@categories [:unstarted, :in_progress, :complete]` with
     `@categories [:unstarted, :planning, :in_progress, :complete]`.
  5. Widen the `add_stage` guard — replace

     ```elixir
     def handle_event("add_stage", %{"category" => category}, socket)
         when category in ["unstarted", "in_progress", "complete"] do
     ```

     with

     ```elixir
     def handle_event("add_stage", %{"category" => category}, socket)
         when category in ["unstarted", "planning", "in_progress", "complete"] do
     ```

  6. After `defp category_atom("unstarted"), do: :unstarted` insert:

     ```elixir
     defp category_atom("planning"), do: :planning
     ```

  7. After `defp category_band_label(:unstarted), do: "UNSTARTED"` insert:

     ```elixir
     defp category_band_label(:planning), do: "PLANNING"
     ```

  8. After the settings module's `category_dot_style(:unstarted)` clause insert the same
     `:planning` clause as in BoardLive:

     ```elixir
     defp category_dot_style(:planning),
       do:
         "width:9px;height:9px;border-radius:50%;background:conic-gradient(var(--color-secondary) 0 25%, oklch(0.86 0.03 250) 25% 100%);display:block;flex:0 0 auto;"
     ```

- [x] Update the two existing LiveView tests that pin the old category layout.

  In `test/relay_web/live/board_live_test.exs`, replace the entire
  `test "groups the stages under their category bands in order"` with:

  ```elixir
  test "groups the stages under their category bands in order", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    [backlog, spec, plan, code, review, deploy, done] = board.stages

    {:ok, view, _html} = live(conn, ~p"/board")

    assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
    assert has_element?(view, "#category-planning h2.category-band", "Planning")
    assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
    assert has_element?(view, "#category-complete h2.category-band", "Complete")

    # a fresh board is empty, so every stage renders as its collapsed strip
    assert has_element?(view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
    assert has_element?(view, "#category-unstarted #stage-strip-#{spec.id}", "Spec")
    assert has_element?(view, "#category-planning #stage-strip-#{plan.id}", "Plan")
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

    assert bands == ["Unstarted", "Planning", "In progress", "Complete"]
  end
  ```

  In `test/relay_web/live/board_settings_stages_test.exs`, replace the entire
  `test "the arrows reorder stages and crossing a band adopts the category"` with:

  ```elixir
  test "the arrows reorder stages and crossing a band adopts the category",
       %{conn: conn, board: board} do
    spec = stage_named(board, "Spec")
    plan = stage_named(board, "Plan")
    {:ok, view, _html} = live(conn, ~p"/board/settings")

    view |> element("#stage-#{spec.id}-down") |> render_click()

    assert has_element?(view, "#settings-group-planning #stage-#{spec.id}-row")
    assert Boards.get_stage(board, spec.id).category == :planning
    # one-directional: the old first-Planning stage keeps its category
    assert Boards.get_stage(board, plan.id).category == :planning

    view |> element("#stage-#{spec.id}-up") |> render_click()

    assert has_element?(view, "#settings-group-unstarted #stage-#{spec.id}-row")
    assert Boards.get_stage(board, spec.id).category == :unstarted
  end
  ```

- [x] Run `mix test` — expect the full suite green.
- [x] Run `mix precommit` — must pass. Fix anything it flags.
- [x] Commit.

**Deliverable:** A fresh board seeds `Plan` in `:planning`; `Relay.Boards.reorder_stage/2` is
one-directional (bug fixed, empty categories crossable, category-order edges no-op, main
positions contiguous 1..n, card owners untouched, `{:stages_changed}` still broadcast); the
board and settings render the Planning band/group without crashing. Full suite + `mix precommit`
green.

**Commit message:**
`feat(boards): add :planning category and one-directional cross-category reorder (MMF 12d)`

---

### Task 2: Planning chrome coverage — dot hook, LiveView tests, copy, component attrs

**Files**

- Modify: `lib/relay_web/live/board_live.ex`
- Modify: `lib/relay_web/live/board_settings_live.ex`
- Modify: `lib/relay_web/components/core_components.ex`
- Test (modify): `test/relay_web/live/board_live_test.exs`
- Test (modify): `test/relay_web/live/board_settings_stages_test.exs`
- Test (modify): `test/relay_web/live/board_live_realtime_test.exs`

**Interfaces**

- Consumes (from Task 1): the seeded `Plan` stage in `:planning`; the `#category-planning` band
  on `RelayWeb.BoardLive`; `#settings-group-planning` + `#add-stage-planning` on
  `RelayWeb.BoardSettingsLive`; `category_dot_style(:planning)` (style string contains
  `var(--color-secondary)`); `category_band_label(:planning) => "PLANNING"`;
  `Relay.Boards.create_stage(board, :planning)`; `Relay.Boards.reorder_stage/2` one-directional
  semantics; `Relay.Boards.list_stages/1`; `Relay.Boards.get_or_create_default_board/1`.
- Produces: a `category-dot` CSS class on the category dot `<span>` in both LiveViews (test
  hook); `board_card`/`stage_column` `attr :category` values include `:planning`.

**Steps**

- [ ] Write the LiveView tests first.

  In `test/relay_web/live/board_live_test.exs`, add inside the `describe "when logged in"`
  block (after the `"groups the stages under their category bands in order"` test):

  ```elixir
  test "renders the Planning band with its label and violet dot", %{conn: conn, user: user} do
    board = Boards.get_or_create_default_board(user)
    plan = Enum.find(board.stages, &(&1.name == "Plan"))

    {:ok, view, _html} = live(conn, ~p"/board")

    assert has_element?(view, "#category-planning h2.category-band", "Planning")
    assert has_element?(view, "#category-planning #stage-strip-#{plan.id}", "Plan")

    [style] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#category-planning .category-dot")
      |> LazyHTML.attribute("style")

    assert style =~ "--color-secondary"
  end
  ```

  In `test/relay_web/live/board_settings_stages_test.exs`, add inside the
  `describe "two-pane shell"` block:

  ```elixir
  test "the stages pane always shows all four category groups with add buttons", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/board/settings")

    for category <- ["unstarted", "planning", "in_progress", "complete"] do
      assert has_element?(view, "#settings-group-#{category}")
      assert has_element?(view, "#add-stage-#{category}")
    end

    assert has_element?(view, "#settings-group-planning", "PLANNING")
    assert has_element?(view, "#add-stage-planning", "+ Add stage to PLANNING")

    [style] =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#settings-group-planning .category-dot")
      |> LazyHTML.attribute("style")

    assert style =~ "--color-secondary"
  end
  ```

  and inside the `describe "adding and deleting stages"` block:

  ```elixir
  test "add stage to Planning creates a planning stage", %{conn: conn, board: board} do
    {:ok, view, _html} = live(conn, ~p"/board/settings")

    view |> element("#add-stage-planning") |> render_click()

    new_stage = board |> Boards.list_stages() |> Enum.find(&(&1.name == "New stage"))
    assert new_stage.category == :planning
    assert has_element?(view, "#settings-group-planning #stage-#{new_stage.id}-row")
  end
  ```

  In `test/relay_web/live/board_live_realtime_test.exs`, add inside the
  `describe "stage configuration changes reflect on open boards (MMF 12)"` block (next to the
  existing `"reordering swaps the columns and keeps card streams attached"` test):

  ```elixir
  test "reordering a stage across the Planning band updates the open board live",
       %{conn: conn, board: board} do
    spec = Enum.find(board.stages, &(&1.name == "Spec"))
    backlog = Enum.find(board.stages, &(&1.name == "Backlog"))

    {:ok, board_view, _html} = live(conn, ~p"/board")
    {:ok, settings_view, _html} = live(conn, ~p"/board/settings")

    settings_view |> element("#stage-#{spec.id}-down") |> render_click()

    assert has_element?(board_view, "#category-planning #stage-strip-#{spec.id}", "Spec")
    assert has_element?(board_view, "#category-unstarted #stage-strip-#{backlog.id}", "Backlog")
  end
  ```

- [ ] Run
  `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_settings_stages_test.exs test/relay_web/live/board_live_realtime_test.exs`
  — expect the two dot tests to FAIL (no `.category-dot` class exists yet); the add-to-planning
  and realtime tests should already pass on Task 1's work (they are regression coverage — verify
  they do).

- [ ] Add the `category-dot` class to both dot spans.

  In `lib/relay_web/live/board_live.ex` (the category `<section>` band header), replace

  ```heex
  <span style={category_dot_style(category)}></span>
  ```

  with

  ```heex
  <span class="category-dot" style={category_dot_style(category)}></span>
  ```

  In `lib/relay_web/live/board_settings_live.ex` (the settings group header), replace

  ```heex
  <span style={category_dot_style(category)}></span>
  ```

  with

  ```heex
  <span class="category-dot" style={category_dot_style(category)}></span>
  ```

- [ ] Update the settings pane copy and comments in `lib/relay_web/live/board_settings_live.ex`:

  1. Replace the intro paragraph fragment

     ```heex
     Stages live inside three categories — <b style="color:oklch(0.34 0.02 255);">Unstarted</b>, <b style="color:oklch(0.34 0.02 255);">In progress</b>, and
     <b style="color:oklch(0.34 0.02 255);">Complete</b>
     ```

     with

     ```heex
     Stages live inside four categories — <b style="color:oklch(0.34 0.02 255);">Unstarted</b>, <b style="color:oklch(0.34 0.02 255);">Planning</b>,
     <b style="color:oklch(0.34 0.02 255);">In progress</b>, and
     <b style="color:oklch(0.34 0.02 255);">Complete</b>
     ```

     (keep the rest of the sentence — `— so everyone knows what a stage <i>means</i>. …` —
     unchanged; let `mix format` settle any wrapping).
  2. Change the HEEx comment
     `<%!-- All three groups always render so an emptied category stays reachable. --%>` to
     `<%!-- All four groups always render so an emptied category stays reachable. --%>`.
  3. In the `refresh_stages/1` code comment, change `All three categories always render` to
     `All four categories always render`.

- [ ] Add `:planning` to the component attr enums in
  `lib/relay_web/components/core_components.ex` — in BOTH the `board_card` and `stage_column`
  components, replace

  ```elixir
  attr :category, :atom,
    values: [:unstarted, :in_progress, :complete, nil],
  ```

  with

  ```elixir
  attr :category, :atom,
    values: [:unstarted, :planning, :in_progress, :complete, nil],
  ```

  (two occurrences; keep each attr's `default:`/`doc:` lines as they are).

- [ ] Grep-verify nothing was missed: run
  `grep -rn "unstarted" lib test storybook | grep -v planning` and inspect the hits — every
  place that enumerates the category set (module attributes, `category_*` function clause
  groups, `values:` lists, seed tuples, guards, tests iterating categories) must now include
  `:planning` / `"planning"` / "Planning". The
  `storybook/core_components/stage_column.story.exs` variations use a single
  `category: :in_progress` value and do not enumerate the category set — no change needed there.

- [ ] Run `mix test` — full suite green (the dot tests now pass).
- [ ] Run `mix precommit` — must pass. Fix anything it flags.
- [ ] Commit.

**Deliverable:** The board renders the PLANNING band (label + violet `--color-secondary` dot)
when non-empty; settings always shows all four category groups, each with its dot, PLANNING
label, and working "+ Add stage to PLANNING" button; reordering a stage into Planning updates an
open board live via the existing `{:stages_changed}` broadcast; component attr enums and
user-facing copy reflect the four-category model. Full suite + `mix precommit` green.

**Commit message:**
`feat(board): Planning category chrome — band dot, settings group, four-category copy (MMF 12d)`
