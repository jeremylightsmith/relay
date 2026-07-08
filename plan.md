# MMF 11 — WIP limits

**Spec:** `docs/superpowers/specs/2026-07-08-wip-limits-design.md`
**Branch discipline:** trunk-based on `main`.

## Goal

A stage can carry an optional WIP limit (`Stage.wip_limit`, nullable positive integer, `nil` = no
limit). The board's stage header shows a mono `wip {used}/{limit}` chip — neutral within the
limit, rose when over. `used` is the stage's **main-lane card count only**: Review/Done sub-lane
cards live in their own child `Stage` rows (MMF 10b), so the exclusion is structural. Enforcement
is **soft**: moving a card into a stage at/over its limit still succeeds everywhere (UI, drawer,
API — API response unchanged), but the acting web session gets a non-blocking warning flash. The
limit is configured from Board Settings' stage card (MMF 12's shell) with the mockup's `WIP`
On/Off toggle + `− / value / +` stepper: toggling on defaults to **3**, stepping floors at **1**.
Limit changes broadcast `{:stages_changed, board_id}` (MMF 18, already fired by
`Boards.update_stage/2`) so every open board re-renders the chip live.

## Architecture

- **Schema:** `stages.wip_limit :integer, null: true` migration; `Schemas.Stage.changeset/2`
  casts it and validates `greater_than: 0` when present. Casting `wip_limit: nil` clears an
  existing limit.
- **Context:** no new functions. `Relay.Boards.update_stage/2` already routes through
  `Stage.changeset/2` (its doc says "any future per-stage fields cast by `Schemas.Stage.changeset/2`;
  MMFs 11/13 reuse this") and already broadcasts `{:stages_changed, board_id}` — adding the cast
  is the whole domain change. Reads use the existing per-stage counts.
- **Board (`RelayWeb.BoardLive` + `RelayWeb.CoreComponents.stage_column/1`):** BoardLive passes
  `wip_limit={stage.wip_limit}` into `stage_column`; the chip renders in the **expanded** stage
  header after the count, driven by the existing `count` attr (which is `@stage_counts[stage.id]`
  — the main lane's own count, so sub-lane cards are excluded by construction). The collapsed
  strip (MMF 12c) and sub-lane strips/headers never render a chip — an empty (collapsed) stage is
  never over-WIP. Counters stay live because `@stage_counts` already recomputes on
  create/move/broadcast, and limit changes arrive via the `{:stages_changed}` → `reload_board/1`
  path.
- **Soft move warning:** in BoardLive's `"move_card"` handler only (drag-and-drop and the
  drawer's Move menu share it), after a successful **cross-stage** move whose target's new `used`
  exceeds its `wip_limit`, `put_flash(:error, "<stage> is over its WIP limit — used/limit")`.
  The move still succeeds; `handle_info({:card_moved, ...})` (broadcast echoes, other sessions,
  API-driven moves) never flashes; the REST API response is untouched.
- **Settings (`RelayWeb.BoardSettingsLive`):** the mockup's WIP row (`docs/designs/Relay
  Board.dc.html` lines ~248–257) slots into the stage card's controls row **between** the OWNER
  segmented control and the DONE COLUMN toggle. Two new events: `"toggle_wip"` (nil→3 / value→nil,
  mockup `onToggleLimit` line ~1102) and `"bump_wip"` (±1, floored at 1, mockup `bumpWip` line
  ~892), both persisting via `Boards.update_stage/2`.

## Tech

Phoenix 1.8 + LiveView (streams), Ecto/Postgres, daisyUI/Tailwind v4 with inline `oklch` style
strings for mockup-exact colours, ExMachina factories, `Phoenix.LiveViewTest` + LazyHTML,
PhoenixStorybook.

### Mockup fidelity (`docs/designs/Relay Board.dc.html` — cite these values exactly)

- **Board WIP chip** (markup lines ~88–89, style line ~1010, label line ~1061):
  `font-size:11px;font-weight:600;font-family:var(--font-mono);padding:2px 7px;border-radius:5px`,
  text `wip {used}/{limit}`. Within limit: `background:oklch(0.96 0.006 255)`,
  `color:oklch(0.48 0.02 255)`. Over limit (`used > limit`): `background:oklch(0.96 0.03 15)`,
  `color:oklch(0.55 0.16 15)`.
- **Settings WIP toggle** (line ~1092): `font-size:12px;font-weight:600;padding:5px 12px;
  border-radius:7px`; On: `border:1px solid oklch(0.75 0.10 250);background:oklch(0.96 0.03 250);
  color:oklch(0.45 0.13 250)`; Off: `border:1px solid oklch(0.90 0.006 255);
  background:oklch(1 0 0);color:oklch(0.52 0.02 255)`. Label `On`/`Off` (line ~1091).
- **Settings stepper** (lines ~252–255): wrapper `display:inline-flex;align-items:center;
  border:1px solid oklch(0.90 0.006 255);border-radius:8px;overflow:hidden`; `−`/`+` buttons
  `width:26px;height:30px;border:none;background:oklch(0.98 0.002 255);color:oklch(0.50 0.02 255);
  font-size:15px;padding:0`; value `width:32px;text-align:center;font-size:13px` mono
  `color:oklch(0.30 0.02 255)`.

## Global Constraints

- `mix precommit` is REQUIRED and must pass before any task is done: compile with warnings as
  errors, `mix format` (Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`, full test
  suite (warnings as errors). Never finish with it failing.
- Boundary-enforced context layering: `RelayWeb` calls the domain only through `Relay`'s exported
  contexts (`Relay.Boards`, `Relay.Cards`, …); a violation fails compilation. This MMF adds no
  context, so no `lib/relay.ex` change.
- HEEx rules: class lists use `[...]` syntax; interpolate attrs with `{...}`; `<%= %>` only in tag
  bodies; comments are `<%!-- --%>`; use `<.icon>` for icons and `<.input>` for form inputs; never
  inline `<script>` tags (colocated hooks only). Give key elements unique DOM ids and use those
  ids in tests (`element/2`, `has_element?/2` — never assert on raw HTML dumps).
- LiveView streams stay the collection mechanism; don't enumerate streams; `@stage_counts` is the
  count source (streams can't be counted).
- Predicate functions end in `?`, never start with `is_`. No `Process.sleep` in tests. Ecto:
  `wip_limit` IS a user-set settings field, so casting it in `Stage.changeset/2` is correct
  (`board_id`/`parent_id` remain programmatic and un-cast).
- Use inline `oklch(...)` style strings for the exact mockup colours (the board columns already do
  this) and `font-family:var(--font-mono)` / `class="font-mono"` for mono text, matching the
  surrounding code.
- Every reusable-component change refreshes its story under `storybook/` — this MMF touches
  `stage_column`, so its story gains WIP-chip variations, and the final report must tell the user
  the storybook page (`/storybook/core_components/stage_column`).
- Soft enforcement only: no move is ever rejected for WIP; no API contract change; no hard-block
  toggle, per-sub-lane limits, or WIP on Review/Done lanes (out of scope).

---

### Task 1: `Stage.wip_limit` domain field + board header WIP chip

**Files**
- Create: `priv/repo/migrations/<timestamp>_add_wip_limit_to_stages.exs` (via
  `mix ecto.gen.migration add_wip_limit_to_stages`)
- Modify: `lib/schemas/stage.ex`, `lib/relay_web/components/core_components.ex`
  (`stage_column/1`), `lib/relay_web/live/board_live.ex` (pass-through only),
  `storybook/core_components/stage_column.story.exs`
- Test (create): `test/relay/boards_wip_test.exs`, `test/relay_web/live/board_live_wip_test.exs`

**Interfaces**

*Consumes (already shipped — do not change their signatures):*
- `Relay.Boards.update_stage(%Schemas.Stage{}, attrs) :: {:ok, %Schemas.Stage{}} | {:error, %Ecto.Changeset{}}`
  — routes through `Schemas.Stage.changeset/2`, broadcasts `{:stages_changed, board_id}` on success.
- `Relay.Boards.get_or_create_default_board(%Schemas.User{})`, `Relay.Boards.get_stage(board, id)`,
  `Relay.Boards.enable_lane(parent, :done | :review)`.
- `Relay.Cards.create_card(stage, attrs)`, `Relay.Cards.move_card(card, target_stage, index, actor \\ :agent)`,
  `Relay.Events.subscribe(board_id)`.
- `stage_column/1` header structure: expanded id `stage-col-<position>`, collapsed strip id
  `stage-strip-<stage_id>`, sub-lane container id `sublane-<id>`; `count` attr is the main lane's
  card count from `@stage_counts` in BoardLive.

*Produces (Task 2 relies on these exact names):*
- `Schemas.Stage` gains `field :wip_limit, :integer` (nullable); `changeset/2` casts `:wip_limit`
  and validates `greater_than: 0`; `Boards.update_stage(stage, %{wip_limit: 3})` persists,
  `%{wip_limit: nil}` clears, `%{wip_limit: 0}` returns `{:error, changeset}`.
- `stage_column/1` gains `attr :wip_limit, :integer, default: nil`; when set, the expanded header
  renders `<span class="stage-wip" data-over>` (the `data-over` attribute present only when
  `used > limit`) with text `wip {used}/{limit}`.
- `RelayWeb.CoreComponents` private helper `wip_chip_colors(over? :: boolean) :: String.t()`.

**Steps**

- [x] Write the failing domain test file `test/relay/boards_wip_test.exs`:

  ```elixir
  defmodule Relay.BoardsWipTest do
    use Relay.DataCase, async: true

    alias Relay.Boards

    defp seeded_board, do: Boards.get_or_create_default_board(insert(:user))

    defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

    describe "wip_limit through update_stage/2" do
      test "persists a positive limit" do
        board = seeded_board()
        code = stage_named(board, "Code")

        assert {:ok, %{wip_limit: 3}} = Boards.update_stage(code, %{wip_limit: 3})
        assert Boards.get_stage(board, code.id).wip_limit == 3
      end

      test "nil clears an existing limit" do
        board = seeded_board()
        code = stage_named(board, "Code")
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})

        assert {:ok, %{wip_limit: nil}} =
                 Boards.update_stage(Boards.get_stage(board, code.id), %{wip_limit: nil})

        assert Boards.get_stage(board, code.id).wip_limit == nil
      end

      test "rejects zero and negative limits, persisting nothing" do
        board = seeded_board()
        code = stage_named(board, "Code")

        assert {:error, changeset} = Boards.update_stage(code, %{wip_limit: 0})
        assert %{wip_limit: ["must be greater than 0"]} = errors_on(changeset)
        assert {:error, %Ecto.Changeset{}} = Boards.update_stage(code, %{wip_limit: -2})
        assert Boards.get_stage(board, code.id).wip_limit == nil
      end

      test "a successful limit change broadcasts {:stages_changed, board_id}" do
        board = seeded_board()
        board_id = board.id
        :ok = Relay.Events.subscribe(board_id)

        {:ok, _stage} = Boards.update_stage(stage_named(board, "Code"), %{wip_limit: 3})
        assert_receive {:stages_changed, ^board_id}
      end
    end
  end
  ```

- [x] Run `mix test test/relay/boards_wip_test.exs` — expect failures (`wip_limit` is not a field
  on `Schemas.Stage`).

- [x] Add the migration and schema field. Run
  `mix ecto.gen.migration add_wip_limit_to_stages` and fill the generated file:

  ```elixir
  defmodule Relay.Repo.Migrations.AddWipLimitToStages do
    use Ecto.Migration

    def change do
      alter table(:stages) do
        add :wip_limit, :integer, null: true
      end
    end
  end
  ```

  In `lib/schemas/stage.ex`, add the field to the schema block (after `field :lane, ...`):

  ```elixir
  field :wip_limit, :integer
  ```

  and replace `changeset/2` with:

  ```elixir
  @doc "Changeset for stage attributes. `board_id` must already be set on the struct."
  def changeset(stage, attrs) do
    stage
    |> cast(attrs, [:name, :description, :position, :category, :owner, :wip_limit])
    |> validate_required([:name, :position, :category, :owner])
    |> validate_number(:wip_limit, greater_than: 0)
    |> unique_constraint(:position, name: :stages_board_id_position_index)
  end
  ```

  Also extend the `@moduledoc` with one sentence: `wip_limit` is the optional MMF 11 WIP limit —
  `nil` means no limit; it is only meaningful on `lane: :main` stages. No change to
  `lib/relay/boards.ex` is needed: `update_stage/2` already casts through this changeset and
  broadcasts `{:stages_changed, board_id}`. Run `mix ecto.migrate`.

- [x] Run `mix test test/relay/boards_wip_test.exs` — expect pass.

- [x] Write the failing board-chip test file `test/relay_web/live/board_live_wip_test.exs`.
  Seeded main-stage order is Backlog(1), Spec(2), Plan(3), Code(4), Review(5), Deploy(6), Done(7)
  — expanded column DOM ids are `stage-col-<position>`:

  ```elixir
  defmodule RelayWeb.BoardLiveWipTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards
    alias Relay.Cards

    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      %{board: board, spec: stage_named(board, "Spec"), code: stage_named(board, "Code")}
    end

    defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

    defp create_cards(stage, count) do
      for n <- 1..count do
        {:ok, card} = Cards.create_card(stage, %{title: "Card #{n}"})
        card
      end
    end

    defp chip_style(view, selector) do
      [style] =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query(selector)
        |> LazyHTML.attribute("style")

      style
    end

    describe "the stage header WIP chip" do
      test "within the limit it renders the neutral mockup chip", %{conn: conn, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        create_cards(code, 2)

        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#stage-col-4 .stage-wip", "wip 2/3")
        refute has_element?(view, "#stage-col-4 .stage-wip[data-over]")

        style = chip_style(view, "#stage-col-4 .stage-wip")
        assert style =~ "background:oklch(0.96 0.006 255)"
        assert style =~ "color:oklch(0.48 0.02 255)"
        assert style =~ "font-family:var(--font-mono)"
      end

      test "over the limit it flips to the rose treatment", %{conn: conn, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        create_cards(code, 4)

        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 4/3")

        style = chip_style(view, "#stage-col-4 .stage-wip")
        assert style =~ "background:oklch(0.96 0.03 15)"
        assert style =~ "color:oklch(0.55 0.16 15)"
      end

      test "no chip renders when wip_limit is nil", %{conn: conn, code: code} do
        create_cards(code, 2)

        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#stage-col-4 .stage-count", "2")
        refute has_element?(view, ".stage-wip")
      end

      test "sub-lane cards do not count toward used, and sub-lanes never show a chip",
           %{conn: conn, code: code} do
        {:ok, done_lane} = Boards.enable_lane(code, :done)
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})
        [first, second, _third] = create_cards(code, 3)
        {:ok, _moved} = Cards.move_card(first, done_lane, 0)
        {:ok, _moved} = Cards.move_card(second, done_lane, 1)

        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#stage-col-4 .stage-wip", "wip 1/2")
        refute has_element?(view, "#stage-col-4 .stage-wip[data-over]")
        refute has_element?(view, "#sublane-#{done_lane.id} .stage-wip")
      end

      test "an empty limited stage collapses to the strip, which shows no chip",
           %{conn: conn, spec: spec} do
        {:ok, _stage} = Boards.update_stage(spec, %{wip_limit: 3})

        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#stage-strip-#{spec.id}")
        refute has_element?(view, "#stage-strip-#{spec.id} .stage-wip")
        refute has_element?(view, ".stage-wip")
      end

      test "clearing the limit hides the chip live via the stages_changed broadcast",
           %{conn: conn, board: board, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        create_cards(code, 2)

        {:ok, view, _html} = live(conn, ~p"/board")
        assert has_element?(view, "#stage-col-4 .stage-wip", "wip 2/3")

        {:ok, _stage} = Boards.update_stage(Boards.get_stage(board, code.id), %{wip_limit: nil})

        render(view)
        refute has_element?(view, ".stage-wip")
      end
    end
  end
  ```

- [x] Run `mix test test/relay_web/live/board_live_wip_test.exs` — expect failures (the
  `.stage-wip` chip does not exist and `stage_column` has no `wip_limit` attr).

- [x] Implement the chip in `lib/relay_web/components/core_components.ex`. Add the attr to
  `stage_column/1`, directly after the existing `attr :count, ...` line:

  ```elixir
  attr :wip_limit, :integer,
    default: nil,
    doc: "the stage's optional WIP limit (MMF 11); the header chip is hidden when nil"
  ```

  In the **expanded** header (the `<header>` inside the `<% else %>` branch of
  `<%= if @collapsed do %>`), insert the chip immediately after the `stage-count` span
  (`<span :if={@count} class="stage-count" ...>{@count}</span>`) and before
  `<span style="flex:1;"></span>`:

  ```heex
  <span
    :if={@wip_limit}
    class="stage-wip"
    data-over={(@count || 0) > @wip_limit}
    style={"font-size:11px;font-weight:600;font-family:var(--font-mono);padding:2px 7px;border-radius:5px;flex:0 0 auto;#{wip_chip_colors((@count || 0) > @wip_limit)}"}
  >
    wip {@count || 0}/{@wip_limit}
  </span>
  ```

  The collapsed-strip branch and the sub-lane markup are untouched — neither ever renders a chip.
  Add the private helper near the other stage_column helpers (`owner_hex/1`, `lane_color/1`),
  with the mockup citation as a comment:

  ```elixir
  # MMF 11 WIP chip colours (mockup "Relay Board.dc.html" line ~1010):
  # over-limit rose vs. within-limit neutral.
  defp wip_chip_colors(true), do: "background:oklch(0.96 0.03 15);color:oklch(0.55 0.16 15);"
  defp wip_chip_colors(false), do: "background:oklch(0.96 0.006 255);color:oklch(0.48 0.02 255);"
  ```

  In `lib/relay_web/live/board_live.ex`, pass the limit through — in the `<.stage_column ...>`
  call inside `render/1`, add one line after `count={Map.fetch!(@stage_counts, stage.id)}`:

  ```heex
  wip_limit={stage.wip_limit}
  ```

  (`used` is the existing `count` attr — BoardLive's `@stage_counts[stage.id]` is the main
  stage's own card count; sub-lane cards sit in child stage rows with their own counts, so the
  exclusion is structural. Limit edits re-render live because `update_stage/2` broadcasts
  `{:stages_changed}` and BoardLive's `handle_info` reloads the board.)

- [x] Run `mix test test/relay_web/live/board_live_wip_test.exs test/relay/boards_wip_test.exs` —
  expect pass.

- [x] Refresh the storybook story. In `storybook/core_components/stage_column.story.exs`, append
  two variations to the `variations/0` list (after `:composing`):

  ```elixir
  %Variation{
    id: :wip_within_limit,
    description: "A WIP-limited stage within its limit shows the neutral wip chip (MMF 11)",
    attributes: %{
      id: "story-stage-wip-ok",
      name: "Code",
      owner: :ai,
      stage_id: 7,
      count: 2,
      wip_limit: 3,
      category: :in_progress,
      board_key: "RLY",
      cards: [
        {"story-card-wip-1",
         %{
           title: "Wire up Google sign-in",
           tag: "auth",
           ref_number: 6,
           status: :working,
           progress: 61,
           owners: [%{actor_type: :agent}]
         }},
        {"story-card-wip-2",
         %{
           title: "Render the stage columns",
           tag: "ui",
           ref_number: 7,
           status: :queued,
           progress: nil,
           owners: []
         }}
      ]
    }
  },
  %Variation{
    id: :wip_over_limit,
    description: "Exceeding the limit flips the chip to the rose over-WIP treatment (MMF 11)",
    attributes: %{
      id: "story-stage-wip-over",
      name: "Code",
      owner: :ai,
      stage_id: 8,
      count: 4,
      wip_limit: 3,
      category: :in_progress,
      board_key: "RLY",
      cards: [
        {"story-card-wip-3",
         %{
           title: "Ship the WIP chip",
           tag: "ui",
           ref_number: 8,
           status: :working,
           progress: 40,
           owners: [%{actor_type: :agent}]
         }},
        {"story-card-wip-4",
         %{
           title: "Fix the flaky deploy",
           tag: "infra",
           ref_number: 9,
           status: :queued,
           progress: nil,
           owners: []
         }},
        {"story-card-wip-5",
         %{
           title: "Add the settings stepper",
           tag: nil,
           ref_number: 10,
           status: :working,
           progress: 15,
           owners: [%{actor_type: :agent}]
         }},
        {"story-card-wip-6",
         %{
           title: "Write the move warning",
           tag: nil,
           ref_number: 11,
           status: :queued,
           progress: nil,
           owners: []
         }}
      ]
    }
  }
  ```

- [x] Run `mix precommit` — fix anything it reports until green.

**Deliverable:** `stages.wip_limit` exists end-to-end — `Boards.update_stage/2` persists/clears/
validates it (broadcasting `{:stages_changed}`), and a limited stage's board header shows the
mockup-exact `wip used/limit` chip (neutral within limit, rose + `data-over` when over; counting
main-lane cards only; no chip when `nil`, on collapsed strips, or on sub-lanes), updating live on
broadcast. Independently testable via the two new test files. Storybook shows both chip states at
`/storybook/core_components/stage_column`.

**Commit message:** `feat(wip): add Stage.wip_limit and the board header WIP chip (MMF 11)`

---

### Task 2: soft over-WIP warning on move + settings WIP control

**Files**
- Modify: `lib/relay_web/live/board_live.ex` (`"move_card"` handler + new private helper),
  `lib/relay_web/live/board_settings_live.ex` (WIP control in the stage card's controls row, two
  new events, style helper, intro-paragraph/comment touch-ups)
- Test (create): `test/relay_web/live/board_live_wip_move_test.exs`,
  `test/relay_web/live/board_settings_wip_test.exs`

**Interfaces**

*Consumes (from Task 1 and shipped code — exact names):*
- `Schemas.Stage.wip_limit` (integer | nil); `Relay.Boards.update_stage(stage, %{wip_limit: 3 | nil})`
  (validates `> 0`, broadcasts `{:stages_changed, board_id}`).
- The `.stage-wip` / `data-over` chip DOM contract from Task 1 (`#stage-col-<position> .stage-wip`).
- BoardLive internals: the `"move_card"` `handle_event` `with`-chain ending in
  `{:noreply, apply_move(socket, card.stage_id, moved)}`; `apply_move/3` refreshes
  `@stage_counts` from the DB before returning; `resolve_stage/2` returns a `%Schemas.Stage{}`
  from `@board.stages` (so it carries `wip_limit`).
- BoardSettingsLive internals: `find_stage(socket, stage_id)` (string id → `%Schemas.Stage{}`
  from `@stages`), `refresh_stages(socket)` (re-reads stages after a mutation), the controls row
  `<div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">` containing the OWNER
  segmented control and the DONE COLUMN toggle.
- Flash: `Layouts.app` renders `<.flash_group>`; the error flash's DOM id is `#flash-error`
  (`core_components.ex` `flash/1` defaults `id` to `"flash-#{kind}"`). The flash component only
  supports `:info`/`:error` kinds — the warning uses `:error` (rose, matching the over-WIP
  treatment) and is non-blocking by construction (just a flash; the move has already persisted).

*Produces:*
- BoardLive private `maybe_warn_over_wip(socket, %Schemas.Stage{} = target, from_stage_id) :: socket`.
- BoardSettingsLive events `"toggle_wip"` (`phx-value-stage-id`) and `"bump_wip"`
  (`phx-value-stage-id`, `phx-value-delta` in `["1", "-1"]`); DOM ids
  `#stage-<id>-wip-toggle`, `#stage-<id>-wip-down`, `#stage-<id>-wip-value`, `#stage-<id>-wip-up`;
  private `wip_toggle_style(on? :: boolean) :: String.t()`.

**Steps**

- [x] Write the failing move-warning test file `test/relay_web/live/board_live_wip_move_test.exs`
  (cards are ref'd sequentially per board: three cards created in Code are RLY-1..3, the next in
  Spec is RLY-4):

  ```elixir
  defmodule RelayWeb.BoardLiveWipMoveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards
    alias Relay.Cards
    alias Relay.Repo
    alias Schemas.Card

    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      %{board: board, spec: stage_named(board, "Spec"), code: stage_named(board, "Code")}
    end

    defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

    describe "soft over-WIP warning on move" do
      test "moving into an at-limit stage still succeeds and warns the acting session",
           %{conn: conn, spec: spec, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        for n <- 1..3, do: {:ok, _card} = Cards.create_card(code, %{title: "Busy #{n}"})
        {:ok, card} = Cards.create_card(spec, %{title: "One more"})

        {:ok, view, _html} = live(conn, ~p"/board")

        render_hook(view, "move_card", %{"ref" => "RLY-4", "stage_id" => code.id, "index" => 0})

        assert has_element?(view, "#stage-col-4-cards .board-card", "One more")
        assert Repo.get!(Card, card.id).stage_id == code.id
        assert has_element?(view, "#flash-error", "Code is over its WIP limit — 4/3")
        assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 4/3")
      end

      test "moving into a stage below its limit does not warn", %{conn: conn, spec: spec, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        {:ok, _card} = Cards.create_card(code, %{title: "Busy"})
        {:ok, _card} = Cards.create_card(spec, %{title: "Fits fine"})

        {:ok, view, _html} = live(conn, ~p"/board")

        render_hook(view, "move_card", %{"ref" => "RLY-2", "stage_id" => code.id, "index" => 0})

        assert has_element?(view, "#stage-col-4-cards .board-card", "Fits fine")
        refute has_element?(view, "#flash-error")
        assert has_element?(view, "#stage-col-4 .stage-wip", "wip 2/3")
      end

      test "reordering within an already over-limit stage does not warn", %{conn: conn, code: code} do
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 1})
        {:ok, _card} = Cards.create_card(code, %{title: "First"})
        {:ok, _card} = Cards.create_card(code, %{title: "Second"})

        {:ok, view, _html} = live(conn, ~p"/board")

        render_hook(view, "move_card", %{"ref" => "RLY-2", "stage_id" => code.id, "index" => 0})

        refute has_element?(view, "#flash-error")
        assert has_element?(view, "#stage-col-4 .stage-wip[data-over]", "wip 2/1")
      end

      test "moving into an unlimited stage never warns", %{conn: conn, spec: spec, code: code} do
        for n <- 1..3, do: {:ok, _card} = Cards.create_card(code, %{title: "Busy #{n}"})
        {:ok, _card} = Cards.create_card(spec, %{title: "Free flow"})

        {:ok, view, _html} = live(conn, ~p"/board")

        render_hook(view, "move_card", %{"ref" => "RLY-4", "stage_id" => code.id, "index" => 0})

        assert has_element?(view, "#stage-col-4-cards .board-card", "Free flow")
        refute has_element?(view, "#flash-error")
      end
    end
  end
  ```

- [x] Run `mix test test/relay_web/live/board_live_wip_move_test.exs` — expect the first test to
  fail on the missing `#flash-error` assertion (the move itself already succeeds).

- [x] Implement the warning in `lib/relay_web/live/board_live.ex`. Change the `"move_card"`
  handler's success branch from `{:noreply, apply_move(socket, card.stage_id, moved)}` to:

  ```elixir
  def handle_event("move_card", %{"ref" => ref, "stage_id" => stage_id} = params, socket) do
    with %Card{} = card <- Cards.get_card_by_ref(socket.assigns.board, ref),
         %Stage{} = stage <- resolve_stage(socket, stage_id),
         index when is_integer(index) <- resolve_index(params, socket, stage),
         {:ok, moved} <- Cards.move_card(card, stage, index, current_actor(socket)) do
      {:noreply, socket |> apply_move(card.stage_id, moved) |> maybe_warn_over_wip(stage, card.stage_id)}
    else
      _ -> {:noreply, socket}
    end
  end
  ```

  and add the private helper (near `apply_move/3`):

  ```elixir
  # MMF 11 — soft enforcement: a cross-stage move into a limited stage that
  # ends up over its WIP limit still succeeds; the acting session just gets
  # a non-blocking warning flash. `used` reads the freshly recomputed
  # @stage_counts from apply_move/3. Reorders within the stage never warn,
  # and only this handler flashes — broadcast-applied moves in handle_info
  # (other sessions, API moves) stay silent, so the API contract and remote
  # sessions see only the rose chip.
  defp maybe_warn_over_wip(socket, %Stage{wip_limit: limit} = target, from_stage_id) when is_integer(limit) do
    used = Map.fetch!(socket.assigns.stage_counts, target.id)

    if target.id != from_stage_id and used > limit do
      put_flash(socket, :error, "#{target.name} is over its WIP limit — #{used}/#{limit}")
    else
      socket
    end
  end

  defp maybe_warn_over_wip(socket, _target, _from_stage_id), do: socket
  ```

  (Sub-lane targets always have `wip_limit: nil` — settings only offers the control on main
  stages — so they fall through the second clause; `target.name` is a main stage's own name, so
  no composite-name leak.)

- [x] Run `mix test test/relay_web/live/board_live_wip_move_test.exs` — expect pass.

- [x] Write the failing settings test file `test/relay_web/live/board_settings_wip_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardSettingsWipTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards
    alias Relay.Cards

    setup :register_and_log_in_user

    setup %{user: user} do
      %{board: Boards.get_or_create_default_board(user)}
    end

    defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

    describe "the stage card's WIP control" do
      test "renders Off with no stepper when the stage has no limit", %{conn: conn, board: board} do
        code = stage_named(board, "Code")

        {:ok, view, _html} = live(conn, ~p"/board/settings")

        assert has_element?(view, "#stage-#{code.id}-wip-toggle", "Off")
        refute has_element?(view, "#stage-#{code.id}-wip-value")
      end

      test "toggling on defaults the limit to 3", %{conn: conn, board: board} do
        code = stage_named(board, "Code")

        {:ok, view, _html} = live(conn, ~p"/board/settings")
        view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

        assert has_element?(view, "#stage-#{code.id}-wip-toggle", "On")
        assert has_element?(view, "#stage-#{code.id}-wip-value", "3")
        assert Boards.get_stage(board, code.id).wip_limit == 3
      end

      test "toggling off clears the limit and hides the stepper", %{conn: conn, board: board} do
        code = stage_named(board, "Code")
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})

        {:ok, view, _html} = live(conn, ~p"/board/settings")
        view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

        assert has_element?(view, "#stage-#{code.id}-wip-toggle", "Off")
        refute has_element?(view, "#stage-#{code.id}-wip-value")
        assert Boards.get_stage(board, code.id).wip_limit == nil
      end

      test "the stepper increments, decrements, and floors at 1", %{conn: conn, board: board} do
        code = stage_named(board, "Code")
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 2})

        {:ok, view, _html} = live(conn, ~p"/board/settings")

        view |> element("#stage-#{code.id}-wip-up") |> render_click()
        assert has_element?(view, "#stage-#{code.id}-wip-value", "3")
        assert Boards.get_stage(board, code.id).wip_limit == 3

        view |> element("#stage-#{code.id}-wip-down") |> render_click()
        view |> element("#stage-#{code.id}-wip-down") |> render_click()
        assert has_element?(view, "#stage-#{code.id}-wip-value", "1")

        view |> element("#stage-#{code.id}-wip-down") |> render_click()
        assert has_element?(view, "#stage-#{code.id}-wip-value", "1")
        assert Boards.get_stage(board, code.id).wip_limit == 1
      end

      test "toggling off hides the chip on an open board via the broadcast",
           %{conn: conn, board: board} do
        code = stage_named(board, "Code")
        {:ok, _stage} = Boards.update_stage(code, %{wip_limit: 3})
        {:ok, _card} = Cards.create_card(code, %{title: "Busy"})

        {:ok, board_view, _html} = live(conn, ~p"/board")
        assert has_element?(board_view, "#stage-col-4 .stage-wip", "wip 1/3")

        {:ok, settings_view, _html} = live(conn, ~p"/board/settings")
        settings_view |> element("#stage-#{code.id}-wip-toggle") |> render_click()

        render(board_view)
        refute has_element?(board_view, ".stage-wip")
      end
    end
  end
  ```

- [x] Run `mix test test/relay_web/live/board_settings_wip_test.exs` — expect failures (the
  `#stage-<id>-wip-toggle` element does not exist).

- [x] Implement the settings control in `lib/relay_web/live/board_settings_live.ex`. In the
  controls row — the `<div style="display:flex;align-items:center;gap:20px;flex-wrap:wrap;">`
  whose preceding HEEx comment mentions "MMF 11's WIP control slots in between OWNER and DONE
  COLUMN" — insert this block **between** the OWNER group's closing `</div>` and the DONE COLUMN
  group's `<div style="display:flex;align-items:center;gap:10px;">`, and update that comment to
  `<%!-- Controls row — OWNER / WIP (MMF 11) / DONE COLUMN (mockup lines ~241-262). --%>`:

  ```heex
  <div style="display:flex;align-items:center;gap:9px;">
    <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
      WIP
    </span>
    <button
      type="button"
      id={"stage-#{stage.id}-wip-toggle"}
      phx-click="toggle_wip"
      phx-value-stage-id={stage.id}
      style={wip_toggle_style(stage.wip_limit != nil)}
    >
      {if stage.wip_limit, do: "On", else: "Off"}
    </button>
    <div
      :if={stage.wip_limit}
      style="display:inline-flex;align-items:center;border:1px solid oklch(0.90 0.006 255);border-radius:8px;overflow:hidden;"
    >
      <button
        type="button"
        id={"stage-#{stage.id}-wip-down"}
        phx-click="bump_wip"
        phx-value-stage-id={stage.id}
        phx-value-delta="-1"
        aria-label="Decrease WIP limit"
        style="width:26px;height:30px;border:none;background:oklch(0.98 0.002 255);color:oklch(0.50 0.02 255);font-size:15px;padding:0;"
      >
        −
      </button>
      <span
        id={"stage-#{stage.id}-wip-value"}
        class="font-mono"
        style="width:32px;text-align:center;font-size:13px;color:oklch(0.30 0.02 255);"
      >
        {stage.wip_limit}
      </span>
      <button
        type="button"
        id={"stage-#{stage.id}-wip-up"}
        phx-click="bump_wip"
        phx-value-stage-id={stage.id}
        phx-value-delta="1"
        aria-label="Increase WIP limit"
        style="width:26px;height:30px;border:none;background:oklch(0.98 0.002 255);color:oklch(0.50 0.02 255);font-size:15px;padding:0;"
      >
        +
      </button>
    </div>
  </div>
  ```

  Add the two event handlers (next to `"set_owner"`; both persist via `Boards.update_stage/2`,
  which broadcasts `{:stages_changed}` so open boards re-render live):

  ```elixir
  # MMF 11 — the mockup's onToggleLimit (line ~1102): enabling defaults the
  # limit to 3, disabling clears it (nil = no limit, chip hidden, enforcement off).
  def handle_event("toggle_wip", %{"stage-id" => stage_id}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{wip_limit: if(stage.wip_limit, do: nil, else: 3)})
    {:noreply, refresh_stages(socket)}
  end

  # MMF 11 — the mockup's bumpWip (line ~892): step by ±1, flooring at 1.
  def handle_event("bump_wip", %{"stage-id" => stage_id, "delta" => delta}, socket)
      when delta in ["1", "-1"] do
    stage = find_stage(socket, stage_id)
    limit = max(1, (stage.wip_limit || 1) + String.to_integer(delta))
    {:ok, _stage} = Boards.update_stage(stage, %{wip_limit: limit})
    {:noreply, refresh_stages(socket)}
  end
  ```

  Add the style helper next to `segment_style/1`, with the mockup citation:

  ```elixir
  # The mockup's limitToggleStyle (line ~1092): blue-tinted when On.
  defp wip_toggle_style(true) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid oklch(0.75 0.10 250);background:oklch(0.96 0.03 250);color:oklch(0.45 0.13 250);"
  end

  defp wip_toggle_style(false) do
    "font-size:12px;font-weight:600;padding:5px 12px;border-radius:7px;" <>
      "border:1px solid oklch(0.90 0.006 255);background:oklch(1 0 0);color:oklch(0.52 0.02 255);"
  end
  ```

  Finally, two copy touch-ups now that the WIP limit exists: in the stages-pane intro paragraph
  change "Set each stage's owner and whether finished work waits in a Done sub-column." to
  "Set each stage's owner, WIP limit, and whether finished work waits in a Done sub-column."
  (matching mockup line ~217), and change the paragraph's preceding HEEx comment from
  `<%!-- Mockup line ~217; the WIP-limit mention is deferred to MMF 11. --%>` to
  `<%!-- Mockup line ~217. --%>`.

- [x] Run `mix test test/relay_web/live/board_settings_wip_test.exs` — expect pass.

- [x] Run `mix precommit` — fix anything it reports until green.

**Deliverable:** moving a card into an at-/over-limit stage completes (soft — the card renders in
the target, DB updated, API untouched) while the acting session sees the "`<stage>` is over its
WIP limit — used/limit" flash and the rose chip; the Board Settings stage card carries the
mockup's WIP On/Off toggle + `−/value/+` stepper (on defaults to 3, floor 1, off clears), and
every change reflects live on open boards via the `{:stages_changed}` broadcast. Independently
testable via the two new test files.

**Commit message:** `feat(wip): soft over-WIP move warning and settings WIP control (MMF 11)`
