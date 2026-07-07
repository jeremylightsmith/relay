# Plan: MMF 05 — Move cards between stages

**Spec:** `docs/superpowers/specs/2026-07-07-move-cards-design.md`

## Goal

Cards move. A user drags a card to another stage (or reorders it within a stage) and the move
persists; the drawer gains a "Move to…" menu that produces the same persisted result. No schema
change — `Card` already carries `stage_id` + `position`.

## Architecture

- **One move path, two entry points.** `Relay.Cards.move_card/3` is the single write path.
  Entry point 1: a hand-rolled HTML5 drag-and-drop JS hook (`BoardDnD`). Entry point 2: the
  card drawer's "Move to…" menu. Both push the same LiveView event
  `"move_card"` with `%{"ref" => ref, "stage_id" => id, "index" => i}` (`index` omitted by the
  drawer = append to bottom).
- **The server owns all state.** The hook never mutates the card list — it only reports what was
  dropped where. `RelayWeb.BoardLive.handle_event("move_card", ...)` resolves the card and target
  stage **on this board only** (reusing `Cards.get_card_by_ref/2` scoping + the board's own
  `stages`), calls `Cards.move_card/3`, then resets the source and target per-stage streams and
  the per-stage count assigns.
- **Positions are re-indexed on the target stage** inside a transaction so ordering stays
  gap-free (1..n) and deterministic.
- **Stage-change emit seam:** `move_card/3` calls a private no-op `emit_stage_changed/2` when the
  stage actually changed. MMF 07 hooks `Activity.log/2` into it — do NOT build activity logging
  here.
- **Lane counts** come from a `:stage_counts` assign (`%{stage_id => count}`) because LiveView
  streams cannot be counted.

## Tech

Phoenix v1.8 + LiveView (per-stage streams named `:"stage_cards_<id>"`), daisyUI components,
Tailwind v4 (`assets/css/app.css`), esbuild (`assets/js/app.js`), ExMachina factories
(`test/support/factory.ex`, `insert(:board | :stage | :card)`), `Relay.DataCase` /
`RelayWeb.ConnCase` + `Phoenix.LiveViewTest` + LazyHTML for tests. No new dependencies —
**no SortableJS, no external JS library** (spec decision).

## Global Constraints

- Running `mix precommit` is REQUIRED on every development cycle and must pass before work is
  considered done. It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings as
  errors). Fix any failure before finishing — never commit work with a failing `mix precommit`.
- Context boundaries are enforced by `boundary` (wired into the compiler). The web layer
  (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may not
  reach into the web layer. A boundary violation fails compilation. (No new context is added in
  this MMF — `Relay.Cards` already exists and is exported.)
- **Always** use LiveView streams for card collections. Streams are *not* enumerable — to
  filter, prune, or refresh items you **must refetch the data and re-stream the entire stream
  collection, passing `reset: true`**. Streams *do not support counting* — track counts in a
  separate assign. Keep `phx-update="stream"` on each per-stage container with a DOM id.
- Elixir lists **do not support index based access via the access syntax** — use `Enum.at`,
  pattern matching, or `List`.
- **Never** write raw embedded `<script>` tags in HEEx. External JS hooks live in `assets/js/`
  and are passed to the `LiveSocket` constructor. **Always** provide a unique DOM id alongside
  `phx-hook`. Only set `phx-update="ignore"` when a hook manages its own DOM (the `BoardDnD`
  hook does NOT manage DOM — do not add `ignore` anywhere).
- HEEx: interpolate attributes with `{...}`; class attrs with multiple/conditional values use
  list syntax `class={[...]}`; comments use `<%!-- --%>`; block constructs in bodies use
  `<%= ... %>`.
- Tests: **never** test raw HTML when `element/2` / `has_element?/2` work; reference the key
  element IDs added in templates; avoid `Process.sleep/1`.
- Storybook is the home for every reusable component — refresh the stories of any
  `core_components` component this plan touches (`stage_column`, `card_drawer`), and the final
  report to the user must link the storybook pages
  (`/storybook/core_components/stage_column`, `/storybook/core_components/card_drawer`).
- daisyUI first: prefer daisyUI primitives (`badge`, `btn`, `dropdown`, `menu`); never use
  `@apply` in raw CSS; mirror `assets/css/app.css` additions into `assets/css/storybook.css`
  (the app.css header comment requires it).
- Out of scope (do NOT build): WIP limits, approval gates, owner/status changes on move,
  sub-lane targets, cross-client live sync, activity logging (MMF 07), the Schemas boundary
  refactor (MMF 06).

---

### Task 1: `Cards.move_card/3` — transactional move with target-stage reindex

**Files**
- Modify: `lib/relay/cards.ex`
- Test: `test/relay/cards_test.exs`

**Interfaces**

*Consumes (existing code):*
- `Relay.Cards.create_card(%Stage{}, attrs) :: {:ok, %Card{}} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.list_cards(%Board{}) :: [%Card{}]` (ordered by `stage_id`, `position`, `id`)
- Factories: `insert(:stage, board: board, position: n)`,
  `insert(:card, stage: stage, title: t, position: p, ref_number: r)`
- `Relay.Repo`, `Relay.Boards.Stage`, `Relay.Cards.Card`

*Produces (later tasks rely on these exact names/types):*
- `Relay.Cards.move_card(%Card{} = card, %Stage{} = target_stage, index) ::
  {:ok, %Card{}} | {:error, Ecto.Changeset.t()}` — `index` is the **0-based insertion index
  among the target stage's cards excluding the moved card**, clamped into range; positions are
  rewritten contiguous starting at 1; raises `FunctionClauseError` when
  `card.board_id != target_stage.board_id` or `index` is not an integer.
- Private seam `emit_stage_changed(moved_card, previous_stage_id)` — no-op, called inside the
  transaction only when the stage actually changed (MMF 07 extends it; nothing else calls it).

**Steps**

- [x] Add a failing `describe "move_card/3"` block to `test/relay/cards_test.exs`, inserted
  after the `describe "get_card_by_ref/2"` block, plus two private helpers at the bottom of the
  module (before the final `end`):

  ```elixir
  describe "move_card/3" do
    setup %{board: board} do
      %{target: insert(:stage, board: board, position: 2)}
    end

    test "moves a card to another stage at the index, reindexing the target gap-free",
         %{board: board, stage: stage, target: target} do
      # Gappy target positions prove the whole target stage is re-indexed.
      a = insert(:card, stage: target, title: "A", position: 3, ref_number: 10)
      b = insert(:card, stage: target, title: "B", position: 7, ref_number: 11)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, %Card{} = moved} = Cards.move_card(card, target, 1)

      assert moved.stage_id == target.id
      assert moved.position == 2
      assert stage_card_ids(board, target) == [a.id, moved.id, b.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "index 0 inserts at the top of the target stage",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert stage_card_ids(board, target) == [moved.id, existing.id]
      assert stage_positions(board, target) == [1, 2]
    end

    test "an index past the end and a negative index clamp into range",
         %{board: board, stage: stage, target: target} do
      existing = insert(:card, stage: target, title: "Existing", position: 1, ref_number: 10)
      {:ok, card_a} = Cards.create_card(stage, %{title: "Bottom"})
      {:ok, card_b} = Cards.create_card(stage, %{title: "Top"})

      {:ok, bottom} = Cards.move_card(card_a, target, 99)
      {:ok, top} = Cards.move_card(card_b, target, -5)

      assert stage_card_ids(board, target) == [top.id, existing.id, bottom.id]
      assert stage_positions(board, target) == [1, 2, 3]
    end

    test "reorders within the same stage keeping positions contiguous",
         %{board: board, stage: stage} do
      {:ok, first} = Cards.create_card(stage, %{title: "First"})
      {:ok, second} = Cards.create_card(stage, %{title: "Second"})
      {:ok, third} = Cards.create_card(stage, %{title: "Third"})

      assert {:ok, moved} = Cards.move_card(third, stage, 0)

      assert moved.stage_id == stage.id
      assert stage_card_ids(board, stage) == [moved.id, first.id, second.id]
      assert stage_positions(board, stage) == [1, 2, 3]
    end

    test "moving into an empty stage lands at position 1", %{stage: stage, target: target} do
      {:ok, card} = Cards.create_card(stage, %{title: "Loner"})

      assert {:ok, moved} = Cards.move_card(card, target, 0)

      assert moved.stage_id == target.id
      assert moved.position == 1
    end

    test "refuses a target stage on another board", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Stay"})
      foreign_stage = insert(:stage)

      assert_raise FunctionClauseError, fn -> Cards.move_card(card, foreign_stage, 0) end
      assert Repo.get!(Card, card.id).stage_id == stage.id
    end
  end
  ```

  Helpers (bottom of the test module, they read through the public API only):

  ```elixir
  defp stage_card_ids(board, stage) do
    board |> Cards.list_cards() |> Enum.filter(&(&1.stage_id == stage.id)) |> Enum.map(& &1.id)
  end

  defp stage_positions(board, stage) do
    board
    |> Cards.list_cards()
    |> Enum.filter(&(&1.stage_id == stage.id))
    |> Enum.map(& &1.position)
  end
  ```

- [x] Run `mix test test/relay/cards_test.exs` — expect the six new tests to fail with
  `UndefinedFunctionError` for `Relay.Cards.move_card/3`.
- [x] Implement `move_card/3` in `lib/relay/cards.ex`. Add the public function after
  `get_card_by_ref/2` and the private functions after `parse_ref_number/2` (keep
  public-with-public, private-with-private ordering):

  ```elixir
  @doc """
  Moves `card` into `target_stage` at the 0-based `index` among the
  stage's cards (excluding the moved card itself), returning
  `{:ok, card}` or `{:error, changeset}`.

  The whole target stage is re-indexed inside a transaction so
  `position` stays contiguous (1..n) and deterministic; `index` is
  clamped into range. The target stage must belong to the card's board —
  callers resolve both on the current board, and a cross-board call
  raises `FunctionClauseError`. A cross-stage move fires the
  stage-change seam (`emit_stage_changed/2`), a no-op until MMF 07 hooks
  activity logging into it.
  """
  def move_card(%Card{board_id: board_id} = card, %Stage{board_id: board_id} = target_stage, index)
      when is_integer(index) do
    previous_stage_id = card.stage_id

    Repo.transaction(fn ->
      moved = place_at(card, target_stage, index)

      if moved.stage_id != previous_stage_id do
        emit_stage_changed(moved, previous_stage_id)
      end

      moved
    end)
  end
  ```

  Private functions:

  ```elixir
  # Re-indexes the target stage: its other cards keep their relative
  # order, `card` is inserted at the clamped index, and positions are
  # rewritten 1..n (updates are no-ops for cards whose row is unchanged).
  defp place_at(%Card{} = card, %Stage{} = target_stage, index) do
    others =
      Repo.all(
        from c in Card,
          where: c.stage_id == ^target_stage.id and c.id != ^card.id,
          order_by: [asc: c.position, asc: c.id]
      )

    index = index |> max(0) |> min(length(others))

    others
    |> List.insert_at(index, card)
    |> Enum.with_index(1)
    |> Enum.map(&reposition(&1, target_stage.id))
    |> Enum.find(&(&1.id == card.id))
  end

  defp reposition({%Card{} = card, position}, stage_id) do
    case Repo.update(Ecto.Changeset.change(card, stage_id: stage_id, position: position)) do
      {:ok, card} -> card
      {:error, changeset} -> Repo.rollback(changeset)
    end
  end

  # MMF 07 seam: activity logging ("moved" timeline entries) hooks in
  # here. Intentionally a no-op today — do not add behaviour in MMF 05.
  defp emit_stage_changed(%Card{} = _moved_card, _previous_stage_id), do: :ok
  ```

  Note: `stage_id`/`position` are programmatic fields (never cast), so the change is built with
  `Ecto.Changeset.change/2`, matching the existing convention in this module.
- [x] Run `mix test test/relay/cards_test.exs` — expect all tests (existing + 6 new) to pass.
- [x] Run `mix precommit` — expect a clean pass.
- [x] Commit.

**Deliverable:** `Relay.Cards.move_card/3` moves and reorders cards transactionally with
gap-free target positions, rejects cross-board targets, and carries the no-op MMF 07 emit seam —
fully covered by `test/relay/cards_test.exs`.

**Commit message:** `feat(cards): add Cards.move_card/3 with target-stage reindex and MMF 07 emit seam`

---

### Task 2: Per-stage lane counts

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`stage_column/1`)
- Modify: `lib/relay_web/live/board_live.ex`
- Modify: `storybook/core_components/stage_column.story.exs`
- Test: `test/relay_web/live/board_live_test.exs`

**Interfaces**

*Consumes (existing code):*
- `RelayWeb.CoreComponents.stage_column/1` (attrs `id`, `name`, `owner`, `stage_id`,
  `board_key`, `cards`, `composing`, `compose_form`)
- `RelayWeb.BoardLive` assigns: `@board`, `@streams`, `stream_name/1`
  (`:"stage_cards_<id>"`), `@stage_groups`; `mount/3` builds
  `cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)`
- `Relay.Boards.get_or_create_default_board(user)`; `register_and_log_in_user` from ConnCase

*Produces (later tasks rely on these exact names/types):*
- `stage_column` attr `count :: integer | nil` (default `nil` hides the badge) rendering
  `<span class="stage-count badge badge-ghost badge-sm font-mono">{@count}</span>`
- BoardLive assign `:stage_counts :: %{integer() => non_neg_integer()}` (stage id → card
  count), set in `mount/3` and incremented in the `"create_card"` handler
- Private helper `stage_counts(stages, cards_by_stage) :: %{integer() => non_neg_integer()}`
  in `RelayWeb.BoardLive`

**Steps**

- [ ] Add a failing `describe "lane counts"` block to `test/relay_web/live/board_live_test.exs`,
  inserted after the `describe "cards"` block:

  ```elixir
  describe "lane counts" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "every stage renders its card count", %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "One", position: 1, ref_number: 1)
      insert(:card, stage: backlog, title: "Two", position: 2, ref_number: 2)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1 .stage-count", "2")

      for position <- 2..7 do
        assert has_element?(view, "#stage-col-#{position} .stage-count", "0")
      end
    end

    test "creating a card bumps its stage's count", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "Count me"}) |> render_submit()

      assert has_element?(view, "#stage-col-1 .stage-count", "1")
      assert has_element?(view, "#stage-col-2 .stage-count", "0")
    end
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect the two new tests to fail
  (no `.stage-count` element exists yet).
- [ ] In `lib/relay_web/components/core_components.ex`, add the `count` attr to `stage_column`.
  Directly below the existing `attr :owner, :atom, values: [:human, :ai], required: true` in the
  `stage_column` attr block (line ~684), add:

  ```elixir
  attr :count, :integer, default: nil, doc: "the number of cards in the stage; badge hidden when nil"
  ```

  Then replace the `stage_column` header:

  ```heex
  <header class="flex items-center justify-between gap-2">
    <h3 class="text-sm font-semibold">{@name}</h3>
    <.owner_pill owner={@owner} />
  </header>
  ```

  with:

  ```heex
  <header class="flex items-center justify-between gap-2">
    <div class="flex items-center gap-1.5">
      <h3 class="text-sm font-semibold">{@name}</h3>
      <span :if={@count} class="stage-count badge badge-ghost badge-sm font-mono">{@count}</span>
    </div>
    <.owner_pill owner={@owner} />
  </header>
  ```

  (`:if={@count}` hides only `nil` — `0` is truthy in Elixir and renders.) Also extend the
  `stage_column` `@doc`'s first paragraph: change `header (stage name + Human/AI owner pill)`
  to `header (stage name, card-count badge, Human/AI owner pill)`.
- [ ] In `lib/relay_web/live/board_live.ex`:
  1. In `mount/3`, add the counts assign — replace:

     ```elixir
     |> assign(:stage_groups, group_stages(board.stages))
     ```

     with:

     ```elixir
     |> assign(:stage_groups, group_stages(board.stages))
     |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
     ```

  2. In the template's `<.stage_column ...>` call, add the attribute line
     `count={Map.fetch!(@stage_counts, stage.id)}` directly below `stage_id={stage.id}`.
  3. In the `"create_card"` handler's `{:ok, card}` branch, replace:

     ```elixir
     {:ok, card} ->
       {:noreply,
        socket
        |> stream_insert(stream_name(stage.id), card)
        |> assign(:compose_form, empty_compose_form())}
     ```

     with:

     ```elixir
     {:ok, card} ->
       {:noreply,
        socket
        |> stream_insert(stream_name(stage.id), card)
        |> update(:stage_counts, &Map.update!(&1, stage.id, fn count -> count + 1 end))
        |> assign(:compose_form, empty_compose_form())}
     ```

  4. Add the private helper next to `group_stages/1`:

     ```elixir
     # Streams can't be counted, so lane counts live in their own assign,
     # recomputed from the grouped cards (mount, moves) and bumped on create.
     defp stage_counts(stages, cards_by_stage) do
       Map.new(stages, fn stage -> {stage.id, length(Map.get(cards_by_stage, stage.id, []))} end)
     end
     ```

- [ ] Update `storybook/core_components/stage_column.story.exs` so the story shows the badge:
  add `count: 0` to the `:empty_human` variation's attributes map and `count: 2` to the
  `:with_cards` variation's attributes map (leave `:composing` without a count to demonstrate
  the nil default).
- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect all tests to pass
  (existing header/`h3` assertions are unaffected).
- [ ] Run `mix precommit` — expect a clean pass.
- [ ] Commit.

**Deliverable:** every stage column header shows a live card-count badge (`.stage-count`),
correct at mount and after composing a card; the storybook stage_column story demonstrates it.

**Commit message:** `feat(board): per-stage lane count badges`

---

### Task 3: `"move_card"` LiveView event — persist, re-stream, recount

**Files**
- Modify: `lib/relay_web/live/board_live.ex`
- Test: `test/relay_web/live/board_live_test.exs`

**Interfaces**

*Consumes:*
- `Relay.Cards.move_card(%Card{}, %Stage{}, index :: integer)` (Task 1)
- BoardLive assign `:stage_counts` and helper `stage_counts/2` (Task 2)
- Existing: `Cards.get_card_by_ref(board, ref)`, `Cards.list_cards(board)`,
  `find_stage_by_id(socket, stage_id)`, `stream_name(stage_id)`, and the `@selected_card` /
  `@selected_stage` assigns produced by `assign_selected_card/2`

*Produces (Tasks 4 and 5 rely on this exact contract):*
- `handle_event("move_card", %{"ref" => ref, "stage_id" => stage_id} = params, socket)` where
  `stage_id` may be an integer or a numeric string, and `params["index"]` (integer or numeric
  string) is **optional — when omitted the card is appended to the bottom of the target stage**.
  Unresolvable ref/stage/index on this board → silent no-op (`{:noreply, socket}` unchanged).
- Private helpers in BoardLive: `resolve_stage(socket, stage_id)`,
  `resolve_index(params, socket, stage)`, `parse_int(value)`,
  `apply_move(socket, source_stage_id, moved)`,
  `restream_stage(socket, stage_id, cards_by_stage)`,
  `refresh_selected_after_move(socket, moved)`

**Steps**

- [ ] Add a failing `describe "moving cards"` block to
  `test/relay_web/live/board_live_test.exs`, inserted after the `describe "lane counts"` block,
  plus one private helper at the bottom of the module (before the final `end`). Write exactly
  this block:

  ```elixir
  describe "moving cards" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec, plan | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec, plan: plan}
    end

    test "a move_card event moves the card to the target stage and persists across reloads",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Take the baton"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-col-2-cards .board-card", "Take the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert Repo.get!(Card, card.id).stage_id == spec.id

      {:ok, reloaded, _html} = live(conn, ~p"/board")
      assert has_element?(reloaded, "#stage-col-2-cards .board-card", "Take the baton")
    end

    test "moving updates both lane counts", %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Mover"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view, "#stage-col-1 .stage-count", "0")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "reordering within a stage persists the new order across reloads",
         %{conn: conn, backlog: backlog} do
      {:ok, _first} = Cards.create_card(backlog, %{title: "First"})
      {:ok, _second} = Cards.create_card(backlog, %{title: "Second"})
      {:ok, _third} = Cards.create_card(backlog, %{title: "Third"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-3", "stage_id" => backlog.id, "index" => 0})

      assert stage_titles(view, 1) == ["Third", "First", "Second"]

      {:ok, reloaded, _html} = live(conn, ~p"/board")
      assert stage_titles(reloaded, 1) == ["Third", "First", "Second"]
    end

    test "accepts string stage_id and index (phx-value parity)",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stringly"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{
        "ref" => "RLY-1",
        "stage_id" => Integer.to_string(spec.id),
        "index" => "0"
      })

      assert Repo.get!(Card, card.id).stage_id == spec.id
    end

    test "omitting index appends the card to the bottom of the target stage",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})
      {:ok, existing} = Cards.create_card(spec, %{title: "Already there"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id})

      assert Repo.get!(Card, card.id).position == 2
      assert Repo.get!(Card, existing.id).position == 1
      assert stage_titles(view, 2) == ["Already there", "Mover"]
    end

    test "a ref that is not on this board is rejected", %{conn: conn, spec: spec} do
      other_stage = insert(:stage)
      theirs = insert(:card, stage: other_stage, title: "Theirs", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert Repo.get!(Card, theirs.id).stage_id == other_stage.id
      refute has_element?(view, "#stage-col-2-cards .board-card")
    end

    test "a target stage that is not on this board is rejected",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Stay home"})
      other_stage = insert(:stage)

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => other_stage.id, "index" => 0})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Stay home")
    end

    test "garbage stage_id or index is ignored", %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Unmoved"})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => "banana", "index" => 0})
      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => "banana"})

      assert Repo.get!(Card, card.id).stage_id == backlog.id
      assert has_element?(view, "#stage-col-1-cards .board-card", "Unmoved")
    end

    test "moving the drawer-selected card refreshes the drawer's stage chip",
         %{conn: conn, backlog: backlog, plan: plan} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chip check"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => plan.id, "index" => 0})

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-secondary", "Plan")
    end
  end
  ```

  Helper at the bottom of the module (before the final `end`):

  ```elixir
  defp stage_titles(view, position) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query("#stage-col-#{position}-cards .board-card .card-title")
    |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect the nine new tests to fail
  (the `"move_card"` event has no handler, so `render_hook` raises or the assertions fail).
- [ ] Implement in `lib/relay_web/live/board_live.ex`:
  1. Add `alias Relay.Boards.Stage` below `alias Relay.Boards` (keep aliases sorted).
  2. Add the handler after the `"select_card"` clause:

     ```elixir
     # One move path, two entry points (drag-and-drop hook and the drawer's
     # "Move to…" menu). `index` is the 0-based drop index among the target
     # stage's other cards; when omitted (drawer) the card appends to the
     # bottom. Anything that doesn't resolve on THIS board is a silent no-op.
     def handle_event("move_card", %{"ref" => ref, "stage_id" => stage_id} = params, socket) do
       with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
            %Stage{} = stage <- resolve_stage(socket, stage_id),
            index when is_integer(index) <- resolve_index(params, socket, stage),
            {:ok, moved} <- Cards.move_card(card, stage, index) do
         {:noreply, apply_move(socket, card.stage_id, moved)}
       else
         _ -> {:noreply, socket}
       end
     end
     ```

  3. Add the private helpers after `find_stage_by_id/2`:

     ```elixir
     defp resolve_stage(socket, stage_id) do
       case parse_int(stage_id) do
         nil -> nil
         id -> find_stage_by_id(socket, id)
       end
     end

     # The drop index from the DnD hook; the drawer omits it, meaning
     # "append to the bottom" — the target's current count clamps to the
     # last slot inside Cards.move_card/3.
     defp resolve_index(%{"index" => index}, _socket, _stage), do: parse_int(index)
     defp resolve_index(_params, socket, stage), do: Map.fetch!(socket.assigns.stage_counts, stage.id)

     defp parse_int(value) when is_integer(value), do: value

     defp parse_int(value) when is_binary(value) do
       case Integer.parse(value) do
         {int, ""} -> int
         _ -> nil
       end
     end

     defp parse_int(_value), do: nil

     # The move already persisted; stream items can't be reordered in
     # place, so refetch and reset the source and target stage streams,
     # refresh the lane counts, and keep the drawer in sync when the moved
     # card is the selected one.
     defp apply_move(socket, source_stage_id, %Card{} = moved) do
       cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

       socket
       |> restream_stage(source_stage_id, cards_by_stage)
       |> restream_stage(moved.stage_id, cards_by_stage)
       |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
       |> refresh_selected_after_move(moved)
     end

     defp restream_stage(socket, stage_id, cards_by_stage) do
       stream(socket, stream_name(stage_id), Map.get(cards_by_stage, stage_id, []), reset: true)
     end

     defp refresh_selected_after_move(socket, %Card{} = moved) do
       moved_id = moved.id

       case socket.assigns.selected_card do
         %Card{id: ^moved_id} ->
           socket
           |> assign(:selected_card, moved)
           |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))

         _ ->
           socket
       end
     end
     ```

  4. Append this sentence to the moduledoc as a new paragraph:
     `MMF 05 makes cards movable: the BoardDnD drag-and-drop hook and the drawer's "Move to…"
     menu both push a "move_card" event; the server persists via Cards.move_card/3, resets the
     affected stage streams, and keeps the lane counts in sync.`
- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect all tests to pass.
- [ ] Run `mix precommit` — expect a clean pass.
- [ ] Commit.

**Deliverable:** the server fully handles `"move_card"` (integer or string params, optional
index = append), persisting via `Cards.move_card/3`, resetting both stage streams, updating lane
counts and the open drawer, and silently rejecting anything not on this board — proven by
`render_hook` tests including reload-persistence.

**Commit message:** `feat(board): handle move_card events — persist, re-stream, recount`

---

### Task 4: Hand-rolled HTML5 drag-and-drop (BoardDnD hook)

**Files**
- Create: `assets/js/hooks/board_dnd.js`
- Modify: `assets/js/app.js`
- Modify: `lib/relay_web/components/core_components.ex` (`board_card/1`, `stage_column/1`)
- Modify: `lib/relay_web/live/board_live.ex` (attach `phx-hook` to `#board`)
- Modify: `assets/css/app.css`, `assets/css/storybook.css`
- Test: `test/relay_web/live/board_live_test.exs`

**Interfaces**

*Consumes:*
- The `"move_card"` event contract from Task 3: `pushEvent("move_card", {ref, stage_id, index})`
  where `ref` is the card's human ref (e.g. `"RLY-1"`), `stage_id` is the zone's
  `data-stage-id` (numeric string — Task 3 parses it), `index` is a JS number: the 0-based
  insertion index among the zone's cards **excluding the dragged card** (matches
  `Cards.move_card/3` semantics exactly).
- Existing markup: `board_card/1` renders `article.board-card`; `stage_column/1` renders the
  per-stage container `#<id>-cards` with `phx-update="stream"`; BoardLive renders
  `<div id="board" ...>`.

*Produces:*
- `BoardDnD` JS hook registered in the `LiveSocket` `hooks` map; attached as
  `phx-hook="BoardDnD"` on `#board` (single delegated hook — never per-column, never
  `phx-update="ignore"`).
- DOM contract: `.board-card[draggable="true"][data-ref="<ref>"]`;
  drop zones `.stage-cards[data-stage-id="<id>"]` (the existing `#stage-col-N-cards`
  containers); transient classes `dragging` (on the card) and `drag-over` (on the zone).

**Steps**

- [ ] Add a failing `describe "drag-and-drop wiring"` block to
  `test/relay_web/live/board_live_test.exs`, inserted after the `describe "moving cards"` block:

  ```elixir
  describe "drag-and-drop wiring" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, _card} = Cards.create_card(backlog, %{title: "Drag me"})
      %{board: board, backlog: backlog}
    end

    test "the board mounts the BoardDnD hook", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#board[phx-hook='BoardDnD']")
    end

    test "cards are draggable and carry their ref", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card[draggable='true'][data-ref='RLY-1']")
    end

    test "every stage's card container is a drop zone carrying its stage id",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards.stage-cards[data-stage-id='#{backlog.id}']")

      zones =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#board .stage-cards[data-stage-id]")
        |> Enum.count()

      assert zones == 7
    end
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect the three new tests to
  fail (no hook attribute, no `draggable`/`data-ref`, no `.stage-cards` class).
- [ ] In `lib/relay_web/components/core_components.ex`:
  1. `board_card/1`: replace the opening `<article ...>` tag:

     ```heex
     <article
       id={@id}
       class="board-card card cursor-pointer bg-base-100 shadow-sm transition-shadow hover:shadow-md"
       role="button"
       tabindex="0"
       phx-click="select_card"
       phx-value-ref={@ref}
     >
     ```

     with:

     ```heex
     <article
       id={@id}
       class="board-card card cursor-pointer bg-base-100 shadow-sm transition-shadow hover:shadow-md"
       role="button"
       tabindex="0"
       draggable="true"
       data-ref={@ref}
       phx-click="select_card"
       phx-value-ref={@ref}
     >
     ```

     and append to the `board_card` `@doc` (before `## Examples`):
     `The card is natively draggable (draggable="true" + data-ref) — the board-level BoardDnD
     hook turns drops into "move_card" events.`
  2. `stage_column/1`: replace the cards container opening tag:

     ```heex
     <div
       id={"#{@id}-cards"}
       phx-update={is_struct(@cards, Phoenix.LiveView.LiveStream) && "stream"}
       class="flex flex-col gap-2"
     >
     ```

     with:

     ```heex
     <div
       id={"#{@id}-cards"}
       phx-update={is_struct(@cards, Phoenix.LiveView.LiveStream) && "stream"}
       data-stage-id={@stage_id}
       class="stage-cards flex flex-col gap-2"
     >
     ```

- [ ] In `lib/relay_web/live/board_live.ex`, replace
  `<div id="board" class="space-y-4">` with
  `<div id="board" class="space-y-4" phx-hook="BoardDnD">` (the hook only listens; it does not
  manage DOM, so no `phx-update="ignore"`).
- [ ] Create `assets/js/hooks/board_dnd.js`:

  ```js
  // Hand-rolled HTML5 drag-and-drop for board cards (MMF 05) — no JS
  // dependency. One delegated hook on #board: dragstart/dragend bubble up
  // from .board-card, dragover/drop from the .stage-cards zones. The hook
  // never mutates the card lists — it only pushes "move_card" with what
  // was dropped where; the server owns all state and re-streams.
  const CARD_SELECTOR = ".board-card"
  const ZONE_SELECTOR = ".stage-cards"

  const BoardDnD = {
    mounted() {
      this.draggedRef = null
      this.draggedEl = null

      this.el.addEventListener("dragstart", e => {
        const card = e.target.closest(CARD_SELECTOR)
        if (!card) return
        this.draggedRef = card.dataset.ref
        this.draggedEl = card
        e.dataTransfer.effectAllowed = "move"
        e.dataTransfer.setData("text/plain", card.dataset.ref)
        card.classList.add("dragging")
      })

      this.el.addEventListener("dragend", e => {
        const card = e.target.closest(CARD_SELECTOR)
        if (card) card.classList.remove("dragging")
        this.clearDropTargets()
        this.draggedRef = null
        this.draggedEl = null
      })

      this.el.addEventListener("dragover", e => {
        const zone = e.target.closest(ZONE_SELECTOR)
        if (!zone || !this.draggedRef) return
        e.preventDefault() // required to allow the drop
        e.dataTransfer.dropEffect = "move"
        this.clearDropTargets(zone)
        zone.classList.add("drag-over")
      })

      this.el.addEventListener("dragleave", e => {
        const zone = e.target.closest(ZONE_SELECTOR)
        if (zone && !zone.contains(e.relatedTarget)) zone.classList.remove("drag-over")
      })

      this.el.addEventListener("drop", e => {
        const zone = e.target.closest(ZONE_SELECTOR)
        if (!zone || !this.draggedRef) return
        e.preventDefault()
        this.pushEvent("move_card", {
          ref: this.draggedRef,
          stage_id: zone.dataset.stageId,
          index: this.dropIndex(zone, e.clientY),
        })
        this.clearDropTargets()
      })
    },

    // 0-based insertion index among the zone's cards *excluding* the
    // dragged card — mirroring the server's ordered "other cards" list.
    dropIndex(zone, y) {
      const cards = Array.from(zone.querySelectorAll(CARD_SELECTOR))
        .filter(el => el !== this.draggedEl)
      return cards.filter(el => {
        const rect = el.getBoundingClientRect()
        return y > rect.top + rect.height / 2
      }).length
    },

    clearDropTargets(except = null) {
      this.el.querySelectorAll(`${ZONE_SELECTOR}.drag-over`).forEach(zone => {
        if (zone !== except) zone.classList.remove("drag-over")
      })
    },
  }

  export default BoardDnD
  ```

- [ ] In `assets/js/app.js`, add the import below `import topbar from "../vendor/topbar"`:

  ```js
  import BoardDnD from "./hooks/board_dnd"
  ```

  and change the `LiveSocket` hooks option from `hooks: {...colocatedHooks},` to:

  ```js
  hooks: {...colocatedHooks, BoardDnD},
  ```

- [ ] Append the drag affordance styles at the end of `assets/css/app.css`, and mirror the same
  block at the end of `assets/css/storybook.css` (the app.css header requires mirroring):

  ```css
  /* --- Drag-and-drop affordances (classes toggled by the BoardDnD hook) --- */
  .board-card.dragging {
    opacity: 0.5;
  }
  .stage-cards.drag-over {
    outline: 2px dashed var(--color-primary);
    outline-offset: 2px;
    border-radius: var(--radius-field);
  }
  ```

- [ ] Run `mix assets.build` — expect the bundle to compile without errors (proves the hook file
  and imports are valid).
- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect all tests to pass.
- [ ] Run `mix precommit` — expect a clean pass.
- [ ] Commit.

**Deliverable:** cards are natively draggable between and within stage columns; drops push
`"move_card"` (already handled server-side in Task 3) and the target zone highlights while
dragging. Server-rendered wiring (`phx-hook`, `draggable`, `data-ref`, `.stage-cards`
`data-stage-id`) is asserted in tests; the JS behaviour itself is exercised by the workflow's
browser smoke test.

**Commit message:** `feat(board): hand-rolled HTML5 drag-and-drop for cards`

---

### Task 5: Drawer "Move to…" menu

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1`)
- Modify: `lib/relay_web/live/board_live.ex`
- Modify: `storybook/core_components/card_drawer.story.exs`
- Test: `test/relay_web/live/board_live_test.exs`

**Interfaces**

*Consumes:*
- The `"move_card"` event contract from Task 3 — the menu buttons send
  `phx-click="move_card"` with `phx-value-ref` and `phx-value-stage_id` (string params) and
  **no index**, so the server appends the card to the bottom of the target stage.
- `refresh_selected_after_move/2` behaviour from Task 3 (drawer chip + rail update after a move
  of the selected card).
- `card_drawer/1` existing attrs (`id`, `ref`, `card`, `stage_name`, `stage_owner`,
  `close_patch`, `title_form`, `editing_description`, `description_form`).

*Produces:*
- `card_drawer` attr `stages :: list` (default `[]`) — move targets, each element exposing
  `id` and `name` (Stage structs or maps); when empty the menu is not rendered.
- DOM contract: dropdown `#<id>-move` with trigger `#<id>-move-button` and one
  `#<id>-move-to-<stage_id>` button per target stage, inside the rail's Stage row.
- BoardLive private helper `move_targets(board, card) :: [%Stage{}]` — the board's stages
  minus the card's current stage, in position order.

**Steps**

- [ ] Add a failing `describe "drawer move menu"` block to
  `test/relay_web/live/board_live_test.exs`, inserted after the `describe "card drawer"` block:

  ```elixir
  describe "drawer move menu" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Pass the baton"})
      %{board: board, backlog: backlog, spec: spec, plan: plan, card: card}
    end

    test "lists every stage except the card's current one",
         %{conn: conn, backlog: backlog, spec: spec, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-move")
      refute has_element?(view, "#card-drawer-move-to-#{backlog.id}")
      assert has_element?(view, "#card-drawer-move-to-#{spec.id}", "Spec")
      assert has_element?(view, "#card-drawer-move-to-#{plan.id}", "Plan")
    end

    test "moving from the drawer persists like a drag and appends to the bottom",
         %{conn: conn, spec: spec, card: card} do
      {:ok, existing} = Cards.create_card(spec, %{title: "Already in Spec"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-move-to-#{spec.id}") |> render_click()

      moved = Repo.get!(Card, card.id)
      assert moved.stage_id == spec.id
      assert moved.position == 2
      assert Repo.get!(Card, existing.id).position == 1

      assert has_element?(view, "#stage-col-2-cards .board-card", "Pass the baton")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-col-1 .stage-count", "0")
      assert has_element?(view, "#stage-col-2 .stage-count", "2")
    end

    test "the drawer stage chip and menu update after the move", %{conn: conn, plan: plan} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-move-to-#{plan.id}") |> render_click()

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-secondary", "Plan")
      refute has_element?(view, "#card-drawer-move-to-#{plan.id}")
    end
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect the three new tests to
  fail (no `#card-drawer-move` element exists yet).
- [ ] In `lib/relay_web/components/core_components.ex`, extend `card_drawer/1`:
  1. Add the attr below the existing `attr :description_form, ...` declaration:

     ```elixir
     attr :stages, :list,
       default: [],
       doc: "move targets: the board's other stages (each exposing id and name); [] hides the menu"
     ```

  2. Replace the rail's Stage row:

     ```heex
     <dd class="rail-stage">{@stage_name}</dd>
     ```

     with:

     ```heex
     <dd class="rail-stage flex flex-wrap items-center gap-2">
       {@stage_name}
       <div :if={@stages != []} id={"#{@id}-move"} class="dropdown">
         <div tabindex="0" role="button" id={"#{@id}-move-button"} class="btn btn-ghost btn-xs">
           Move to… <.icon name="hero-chevron-down" class="size-3" />
         </div>
         <ul
           tabindex="0"
           class="dropdown-content menu z-50 w-44 rounded-box border border-base-300 bg-base-100 p-2 shadow-lg"
         >
           <li :for={stage <- @stages}>
             <button
               type="button"
               id={"#{@id}-move-to-#{stage.id}"}
               phx-click="move_card"
               phx-value-ref={@ref}
               phx-value-stage_id={stage.id}
             >
               {stage.name}
             </button>
           </li>
         </ul>
       </div>
     </dd>
     ```

  3. In the `card_drawer` `@doc`, extend the "Events emitted" sentence to also list:
     `"move_card" (phx-value ref + stage_id, no index — the server appends to the target
     stage's bottom) when a "Move to…" target is picked`.
- [ ] In `lib/relay_web/live/board_live.ex`:
  1. Add `stages={move_targets(@board, @selected_card)}` to the `<.card_drawer ...>` call,
     directly below `stage_owner={@selected_stage.owner}`.
  2. Add the private helper next to `find_stage_by_id/2`:

     ```elixir
     # Drawer move targets: every stage on this board except the card's
     # current one, in position order.
     defp move_targets(board, %Card{stage_id: stage_id}) do
       Enum.reject(board.stages, &(&1.id == stage_id))
     end
     ```

- [ ] Update `storybook/core_components/card_drawer.story.exs`: add to the `:viewing`
  variation's attributes map:

  ```elixir
  stages: [%{id: 3, name: "Plan"}, %{id: 4, name: "Code"}, %{id: 7, name: "Done"}]
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect all tests to pass
  (the pre-existing `.rail-stage` test still matches: the row still contains the stage name).
- [ ] Run `mix precommit` — expect a clean pass.
- [ ] Commit.

**Deliverable:** the card drawer's properties rail offers a "Move to…" dropdown listing the
board's other stages; picking one persists through the exact same `"move_card"` →
`Cards.move_card/3` path as a drag (appended to the target's bottom), updates both columns,
lane counts, and the drawer's own stage chip. The storybook card_drawer story shows the menu.

**Commit message:** `feat(board): drawer "Move to…" menu via the shared move_card path`

---

## Spec coverage map

| Spec requirement | Task |
| --- | --- |
| `Cards.move_card/3` — transaction, target reindex, `{:ok, card}` / `{:error, changeset}`, no schema change | 1 |
| Stage-change emit seam (no-op; MMF 07 hooks `Activity.log/2`) | 1 |
| Cross-board card/stage rejected (context guard + LiveView scoping) | 1, 3 |
| `"move_card"` event `%{"ref", "stage_id", "index"}`, server owns state, re-streams source+target | 3 |
| Lane counts from a per-stage count assign | 2, 3 |
| Hand-rolled HTML5 DnD, no JS dependency, `phx-update="stream"` preserved | 4 |
| Drawer "Move to…" via the same `move_card/3` path | 5 |
| Acceptance: drag persists + renders after reload | 3 (server tests) + 4 (wiring) |
| Acceptance: reorder within a stage persists position | 1, 3 |
| Acceptance: lane counts reflect the new location | 3 |
| Acceptance: non-drag "Move to <stage>" produces the same result | 5 |
