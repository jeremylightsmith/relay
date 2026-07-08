# Plan — MMF 10b: Stage substages (Review / Done sub-lanes)

**Spec:** `docs/superpowers/specs/2026-07-07-substages-design.md`  ·  **Milestone:** Post-MVP

## Goal

A stage can carry optional **Review** and/or **Done** sub-lanes. A sub-lane *is* a child
`Stage` (`parent_id` + `lane` role). The board renders a stage's sub-lanes stacked beneath its
main lane (label + count + cards, **no owner pill**); cards move into a sub-lane through the
existing move path (a sub-lane is a stage with its own drop zone). Sub-lane owners are
predictable — **Review = `:human`, Done = mirrors the parent** — set at creation. Per-stage
toggles live in `/board/settings`; toggling a non-empty lane off is guarded.

## Architecture

- **Sub-lanes are stages.** `Schemas.Stage` gains `parent_id` (nullable self-ref) + `lane`
  (`:main | :review | :done`, default `:main`). A parent has at most one `:review` and one
  `:done` child. `Relay.Boards` owns `enable_lane/2` (creates the child with the right owner) and
  `disable_lane/2` (guarded delete). Children are ordinary stages, so they already get a per-lane
  LiveView stream, a count, a DnD drop zone, and work as `move_card/4` targets — no move changes.
- **Rendering.** `BoardLive` groups only `lane: :main` stages into category columns and hands each
  column its children (sorted Review→Done) to render as stacked sub-lanes.
- The MMF 06 red **mismatch** styling applies per-lane automatically: a sub-lane card's
  `stage_owner` is the child's owner, so a card whose active-owner type differs flags red.

## Tech

Ecto migration + `Ecto.Enum`, LiveView, daisyUI. No new deps.

## Global Constraints (verbatim intent from AGENTS.md + spec)

- `mix precommit` MUST pass (compile warnings-as-errors, format+Styler, credo --strict, sobelow,
  deps.audit, full suite).
- **Boundaries enforced by the compiler.** `Relay.Boards` (`deps: [Relay.Repo, Schemas]`) may query
  `Schemas.Card` via `Repo` for the emptiness guard; it must NOT call `Relay.Cards`.
- Programmatic/structural fields (`board_id`, `parent_id`, `lane`) are set on the struct, never
  cast from params.
- LiveView streams: each (sub-)lane has its own `phx-update="stream"` container with a DOM id;
  counts live in the `:stage_counts` assign (streams can't be counted).
- No `String.to_atom/1` on user input; predicate fns end in `?`.
- HEEx: list class syntax; `<%= for %>`/`:for`; `<.icon>`/`<.input>`.

## Interfaces (Consumes — from earlier MMFs)

- `Relay.Boards.get_or_create_default_board(user)` → board with `stages` preloaded (position order; includes children).
- `Relay.Boards.list_stages/1`, `get_stage/2` (MMF 09).
- `Relay.Cards.move_card(card, %Schemas.Stage{}, index, actor)` — targets ANY stage incl. a sub-lane.
- `Relay.Cards.active_owner_type/1`; `board_card` component takes `active_owner` + `stage_owner`.
- Factory: `insert(:board)`, `insert(:stage, board:, ...)`, `insert(:card, stage:)`.

---

## Task 1: Schema + `Relay.Boards` lane domain

**Files**
- create `priv/repo/migrations/<ts>_add_stage_sublanes.exs` (via `mix ecto.gen.migration add_stage_sublanes`)
- modify `lib/schemas/stage.ex` — `lane` + `parent_id` + associations
- modify `lib/relay/boards.ex` — `enable_lane/2`, `disable_lane/2`, `sublanes/1`, helpers
- modify `test/support/factory.ex` — allow `lane`/`parent` on `stage_factory` (schema default covers `:main`)
- create `test/relay/boards_lanes_test.exs`

**Interfaces**
- *Produces:*
  - `Relay.Boards.enable_lane(%Schemas.Stage{lane: :main}, :review | :done) :: {:ok, %Schemas.Stage{}}` (idempotent — returns the existing child if already enabled)
  - `Relay.Boards.disable_lane(%Schemas.Stage{}, :review | :done) :: {:ok, :disabled | :not_enabled} | {:error, :not_empty}`
  - `Relay.Boards.sublanes(%Schemas.Stage{}) :: [%Schemas.Stage{}]` (its `:review`/`:done` children, Review→Done)

### Steps

- [x] **Migration.** Run `mix ecto.gen.migration add_stage_sublanes`, then set its body:

```elixir
defmodule Relay.Repo.Migrations.AddStageSublanes do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :lane, :string, null: false, default: "main"
      add :parent_id, references(:stages, on_delete: :delete_all)
    end

    create index(:stages, [:parent_id])
    # At most one review + one done child per parent.
    create unique_index(:stages, [:parent_id, :lane], where: "parent_id IS NOT NULL", name: :stages_parent_lane_index)
  end
end
```

- [x] **Schema — failing test first.** Add `test/relay/boards_lanes_test.exs`:

```elixir
defmodule Relay.BoardsLanesTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  defp main_stage(attrs \\ []) do
    board = insert(:board)
    insert(:stage, Keyword.merge([board: board, name: "Code", owner: :ai, category: :in_progress, position: 1], attrs))
  end

  test "enable_lane creates a review child owned by a human" do
    parent = main_stage()
    assert {:ok, child} = Boards.enable_lane(parent, :review)
    assert child.parent_id == parent.id
    assert child.lane == :review
    assert child.owner == :human
    assert child.category == parent.category
  end

  test "enable_lane's done child mirrors the parent's owner" do
    parent = main_stage(owner: :ai)
    assert {:ok, child} = Boards.enable_lane(parent, :done)
    assert child.lane == :done
    assert child.owner == :ai
  end

  test "enable_lane is idempotent" do
    parent = main_stage()
    {:ok, first} = Boards.enable_lane(parent, :review)
    {:ok, second} = Boards.enable_lane(parent, :review)
    assert first.id == second.id
  end

  test "sublanes/1 returns review then done" do
    parent = main_stage()
    {:ok, _} = Boards.enable_lane(parent, :done)
    {:ok, _} = Boards.enable_lane(parent, :review)
    assert [%{lane: :review}, %{lane: :done}] = Boards.sublanes(parent)
  end

  test "disable_lane removes an empty lane, guards a non-empty one" do
    parent = main_stage()
    {:ok, review} = Boards.enable_lane(parent, :review)

    assert {:ok, :disabled} = Boards.disable_lane(parent, :review)
    assert Boards.sublanes(parent) == []
    assert {:ok, :not_enabled} = Boards.disable_lane(parent, :done)

    {:ok, review2} = Boards.enable_lane(parent, :review)
    insert(:card, stage: review2)
    assert {:error, :not_empty} = Boards.disable_lane(parent, :review)
    assert [%{lane: :review}] = Boards.sublanes(parent)
  end
end
```

- [x] **Run — expect fail** (schema/functions missing).

- [x] **Extend the schema.** In `lib/schemas/stage.ex`, add to the `schema "stages"` block:

```elixir
    field :lane, Ecto.Enum, values: [:main, :review, :done], default: :main

    belongs_to :parent, Schemas.Stage
    has_many :sublanes, Schemas.Stage, foreign_key: :parent_id
```

(Leave `changeset/2` casting `[:name, :position, :category, :owner]` unchanged — `lane`/`parent_id` are structural, set on the struct.)

- [x] **Implement the Boards lane API.** In `lib/relay/boards.ex`, add `alias Schemas.Card` and these public functions:

```elixir
  @doc """
  Enables a `:review` or `:done` sub-lane on `parent` (a main stage),
  creating the child stage with the predictable owner (review → :human,
  done → the parent's owner). Idempotent — returns the existing child if
  the lane is already enabled.
  """
  def enable_lane(%Stage{lane: :main} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      %Stage{} = existing ->
        {:ok, existing}

      nil ->
        %Stage{board_id: parent.board_id, parent_id: parent.id, lane: lane}
        |> Stage.changeset(%{
          name: "#{parent.name}:#{lane_word(lane)}",
          position: next_position(parent.board_id),
          category: parent.category,
          owner: lane_owner(lane, parent)
        })
        |> Repo.insert()
    end
  end

  @doc """
  Disables `parent`'s `lane` sub-lane. Returns `{:ok, :disabled}` when the
  (empty) child is removed, `{:ok, :not_enabled}` when there is nothing to
  remove, or `{:error, :not_empty}` when the lane still holds cards.
  """
  def disable_lane(%Stage{} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      nil ->
        {:ok, :not_enabled}

      %Stage{} = child ->
        if Repo.exists?(from c in Card, where: c.stage_id == ^child.id) do
          {:error, :not_empty}
        else
          {:ok, _} = Repo.delete(child)
          {:ok, :disabled}
        end
    end
  end

  @doc "The stage's `:review`/`:done` children, ordered Review then Done."
  def sublanes(%Stage{} = parent) do
    Repo.all(
      from s in Stage,
        where: s.parent_id == ^parent.id,
        order_by: fragment("array_position(ARRAY['review','done'], ?)", s.lane)
    )
  end

  defp get_sublane(%Stage{} = parent, lane) do
    Repo.get_by(Stage, parent_id: parent.id, lane: lane)
  end

  defp lane_owner(:review, _parent), do: :human
  defp lane_owner(:done, %Stage{owner: owner}), do: owner

  defp lane_word(:review), do: "Review"
  defp lane_word(:done), do: "Done"

  defp next_position(board_id) do
    (Repo.one(from s in Stage, where: s.board_id == ^board_id, select: max(s.position)) || 0) + 1
  end
```

- [x] **Run — expect pass.**

- [x] **Full check + commit.** `mix precommit`. Commit: `feat(boards): stage sub-lanes (parent_id + lane) with enable/disable`.

**Deliverable:** the sub-lane data model + guarded `enable_lane`/`disable_lane`/`sublanes`, fully unit-tested (owner rules, idempotency, order, emptiness guard).

---

## Task 2: Board renders sub-lanes stacked under their parent

**Files**
- modify `lib/relay_web/components/core_components.ex` — `stage_column` gains a `sublanes` attr
- modify `lib/relay_web/live/board_live.ex` — filter main stages into columns; build sub-lane views
- modify `storybook/core_components/stage_column.story.exs` — a sub-lane variation
- modify `test/relay_web/live/board_live_test.exs` — sub-lane rendering + move-into-lane

**Interfaces**
- *Consumes:* `Relay.Boards.sublanes/1` (via preloaded children), `stream_name/1`, `@stage_counts`, `Cards.move_card/4`.
- *Produces:* `stage_column` `sublanes` attr = `[%{id, name, count, owner, cards}]`.

### Steps

- [x] **Failing LiveView tests.** Add to `test/relay_web/live/board_live_test.exs` (new describe block):

```elixir
  describe "sub-lanes" do
    setup %{conn: conn} do
      user = Relay.Factory.insert(:user)
      board = Relay.Boards.get_or_create_default_board(user)
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, _review} = Relay.Boards.enable_lane(code, :review)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board, code: code}
    end

    test "renders a stage's review sub-lane stacked with its own count", %{conn: conn, code: code} do
      {:ok, _view, html} = live(conn, ~p"/board")
      review = Relay.Boards.sublanes(code) |> hd()
      assert html =~ "sublane-#{review.id}"
      assert html =~ "Review"
    end

    test "a card moved into the review sub-lane renders there", %{conn: conn, code: code} do
      review = Relay.Boards.sublanes(code) |> hd()
      card = Relay.Factory.insert(:card, stage: Enum.find(Relay.Repo.all(Schemas.Stage), &(&1.id == code.id)))

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "#{card_ref(card)}", "stage_id" => review.id})

      # Assert by container + title (the card's DOM id is stream-generated, not #card-<id>).
      assert has_element?(view, "#sublane-#{review.id}-cards", card.title)
    end

    defp card_ref(card), do: "RLY-#{card.ref_number}"
  end
```

(If a `card_ref`/board-key helper already exists in the test file, reuse it instead of redefining.)

- [x] **Run — expect fail** (no sub-lane DOM yet).

- [x] **Add the `sublanes` attr + rendering to `stage_column`.** In `lib/relay_web/components/core_components.ex`, add near the other `stage_column` attrs:

```elixir
  attr :sublanes, :list, default: []
```

Then, inside `stage_column`'s `~H`, insert this block **immediately after** the main `.stage-cards` `</div>` and before the composer block:

```heex
      <div
        :for={sub <- @sublanes}
        id={"sublane-#{sub.id}"}
        class="stage-sublane mt-1 rounded-lg border border-base-300/60 bg-base-100/40 p-2"
      >
        <header class="mb-1.5 flex items-center justify-between gap-2">
          <h4 class="text-xs font-semibold uppercase tracking-wide text-base-content/50">{sub.name}</h4>
          <span class="badge badge-ghost badge-xs font-mono">{sub.count}</span>
        </header>
        <div
          id={"sublane-#{sub.id}-cards"}
          phx-update="stream"
          data-stage-id={sub.id}
          class="stage-cards flex flex-col gap-2"
        >
          <div
            id={"sublane-#{sub.id}-empty"}
            class="stage-empty hidden only:block rounded-lg border border-dashed border-base-content/20 px-3 py-4 text-center text-xs text-base-content/40"
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
            active_owner={Cards.active_owner_type(card)}
            stage_owner={sub.owner}
          />
        </div>
      </div>
```

- [x] **Wire BoardLive to render only main columns + pass sub-lanes.** In `lib/relay_web/live/board_live.ex`:

  1. In `mount/3`, after assigning `:stage_groups`, add a sub-lanes-by-parent assign:

```elixir
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))
```

  2. Change `group_stages/1` to only column the main stages:

```elixir
  defp group_stages(stages) do
    groups = stages |> Enum.filter(&(&1.lane == :main)) |> Enum.group_by(& &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end
```

  3. Add the grouping + label helpers:

```elixir
  # Children grouped under their parent's id, each list ordered Review→Done.
  defp sublanes_by_parent(stages) do
    stages
    |> Enum.filter(&(&1.lane != :main))
    |> Enum.group_by(& &1.parent_id)
    |> Map.new(fn {parent_id, children} -> {parent_id, Enum.sort_by(children, &lane_order/1)} end)
  end

  defp lane_order(%Stage{lane: :review}), do: 0
  defp lane_order(%Stage{lane: :done}), do: 1

  defp lane_label(:review), do: "Review"
  defp lane_label(:done), do: "Done"
```

  4. In `render/1`, pass `sublanes` to `<.stage_column>` (add the attr to the existing call):

```heex
                sublanes={
                  for sub <- Map.get(@sublanes_by_parent, stage.id, []) do
                    %{
                      id: sub.id,
                      name: lane_label(sub.lane),
                      owner: sub.owner,
                      count: Map.fetch!(@stage_counts, sub.id),
                      cards: Map.fetch!(@streams, stream_name(sub.id))
                    }
                  end
                }
```

- [x] **Refresh the storybook story.** In `storybook/core_components/stage_column.story.exs`, add a variation passing a `sublanes` list (one review lane with a card map `%{count: 1, ...}` and an empty `cards` — mirror the existing story's data shape) so the component's sub-lane rendering has a story. Tell the user the page: `/storybook/core_components/stage_column`.

- [x] **Run — expect pass.**

- [x] **Full check + commit.** `mix precommit`. Commit: `feat(board): render stage sub-lanes stacked under their parent`.

**Deliverable:** a stage's Review/Done sub-lanes render stacked beneath it (label + count + cards, no owner pill); a card dragged or moved into a sub-lane renders there (the sub-lane is a real stream + drop zone); move-into-lane needs no move-path change.

---

## Task 3: `/board/settings` per-stage sub-lane toggles

**Files**
- modify `lib/relay_web/live/board_settings_live.ex` — a "Stages" pane with Review/Done toggles
- modify `test/relay_web/live/board_settings_live_test.exs` — toggle on/off + guard

**Interfaces**
- *Consumes:* `Relay.Boards.enable_lane/2`, `disable_lane/2`, `sublanes/1`, `list_stages/1`.

### Steps

- [ ] **Failing tests.** Add to `test/relay_web/live/board_settings_live_test.exs` (new describe; reuse the file's existing login setup — a `register_and_log_in_user`/board setup):

```elixir
  describe "stage sub-lanes" do
    setup %{conn: conn} do
      user = Relay.Factory.insert(:user)
      board = Relay.Boards.get_or_create_default_board(user)
      %{conn: Plug.Test.init_test_session(conn, user_id: user.id), board: board}
    end

    test "toggling Review on creates the child lane; off removes it", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert [%{lane: :review}] = Relay.Boards.sublanes(code)

      view |> element("#stage-#{code.id}-review-toggle") |> render_click()
      assert Relay.Boards.sublanes(code) == []
    end

    test "toggling off a non-empty lane is blocked with a flash", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, review} = Relay.Boards.enable_lane(code, :review)
      Relay.Factory.insert(:card, stage: review)

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      html = view |> element("#stage-#{code.id}-review-toggle") |> render_click()

      assert html =~ "still has cards"
      assert [%{lane: :review}] = Relay.Boards.sublanes(code)
    end
  end
```

- [ ] **Run — expect fail.**

- [ ] **Add the Stages pane.** In `lib/relay_web/live/board_settings_live.ex`:

  1. In `mount/3`, assign the main stages + their current lanes:

```elixir
     |> assign(:stages, board |> Boards.list_stages() |> Enum.filter(&(&1.lane == :main)))
     |> assign(:lane_map, lane_map(board))
```

  with a private helper:

```elixir
  defp lane_map(board) do
    board
    |> Boards.list_stages()
    |> Enum.filter(&(&1.lane != :main))
    |> Enum.group_by(& &1.parent_id, & &1.lane)
    |> Map.new(fn {parent_id, lanes} -> {parent_id, MapSet.new(lanes)} end)
  end

  defp lane_on?(lane_map, stage_id, lane), do: MapSet.member?(Map.get(lane_map, stage_id, MapSet.new()), lane)
```

  2. Add a Stages `<section>` after the API-key pane inside the template's outer container:

```heex
        <section id="stages-pane" class="card border border-base-300 bg-base-100">
          <div class="card-body space-y-4">
            <div>
              <h2 class="card-title text-base">Stages</h2>
              <p class="text-sm text-base-content/60">
                Add a Review or Done sub-lane to a stage. A Review lane is for humans; a Done lane matches the stage.
              </p>
            </div>
            <ul class="divide-y divide-base-200">
              <li :for={stage <- @stages} id={"stage-#{stage.id}-row"} class="flex items-center justify-between py-2">
                <span class="text-sm font-medium">{stage.name}</span>
                <div class="flex items-center gap-4">
                  <label class="flex items-center gap-2 text-xs">
                    <input
                      id={"stage-#{stage.id}-review-toggle"}
                      type="checkbox"
                      class="toggle toggle-sm"
                      checked={lane_on?(@lane_map, stage.id, :review)}
                      phx-click="toggle_lane"
                      phx-value-stage-id={stage.id}
                      phx-value-lane="review"
                    /> Review
                  </label>
                  <label class="flex items-center gap-2 text-xs">
                    <input
                      id={"stage-#{stage.id}-done-toggle"}
                      type="checkbox"
                      class="toggle toggle-sm"
                      checked={lane_on?(@lane_map, stage.id, :done)}
                      phx-click="toggle_lane"
                      phx-value-stage-id={stage.id}
                      phx-value-lane="done"
                    /> Done
                  </label>
                </div>
              </li>
            </ul>
          </div>
        </section>
```

  3. Add the toggle handler (aliases: `Schemas.Stage`, `Relay.Boards` already aliased):

```elixir
  def handle_event("toggle_lane", %{"stage-id" => stage_id, "lane" => lane}, socket) do
    lane = lane_atom(lane)
    stage = Enum.find(socket.assigns.stages, &(&1.id == String.to_integer(stage_id)))

    result =
      if lane_on?(socket.assigns.lane_map, stage.id, lane) do
        Boards.disable_lane(stage, lane)
      else
        Boards.enable_lane(stage, lane)
      end

    {:noreply, apply_lane_result(socket, result)}
  end

  defp lane_atom("review"), do: :review
  defp lane_atom("done"), do: :done

  defp apply_lane_result(socket, {:error, :not_empty}) do
    put_flash(socket, :error, "That lane still has cards — move them out first.")
  end

  defp apply_lane_result(socket, {:ok, _}) do
    board = socket.assigns.board
    assign(socket, :lane_map, lane_map(board))
  end
```

- [ ] **Run — expect pass.**

- [ ] **Full check + commit.** `mix precommit`. Commit: `feat(settings): per-stage Review/Done sub-lane toggles`.

**Deliverable:** the settings page lists each stage with Review/Done toggles that create/remove the child lane via `Relay.Boards`; toggling off a non-empty lane is blocked with a flash and leaves the lane intact.

---

## Spec coverage

| Spec requirement / acceptance criterion | Task |
|---|---|
| `Stage.parent_id` (self-ref) + `lane` enum (`main`/`review`/`done`), ≤1 review + ≤1 done child | 1 |
| Sub-lane owner: Review = `:human`, Done = mirrors parent (set at creation) | 1 |
| `enable_lane` creates the child; `disable_lane` guarded (non-empty blocked) | 1, 3 |
| Board renders sub-lanes stacked under the parent (label + count + cards, no owner pill) | 2 |
| A card can be moved into a Review/Done sub-lane and renders there | 2 |
| Owner chrome only on the main stage; red mismatch still applies per-lane | 2 |
| Per-stage Review/Done toggles in `/board/settings`; non-empty toggle-off guarded | 3 |
