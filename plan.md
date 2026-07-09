# Plan: Card `branch` + `plan` fields (API read/write + collapsed drawer plan)

**Spec:** `docs/superpowers/specs/2026-07-08-card-branch-plan-design.md`

## Goal

Give each card two new nullable fields that let the autonomous board runner carry its work
with the card instead of colliding in shared repo state: `branch` (which git branch the
card's work lives on) and `plan` (the implementation plan text). Both are readable and
writable through the existing REST API (`PATCH /api/cards/:ref`, `GET /api/cards/:ref`,
`GET /api/board`), every write broadcasts `{:card_upserted, card}` so open boards update
live, and the card drawer renders `plan` in a **collapsed-by-default** daisyUI collapse
section plus a mono **branch chip** in the properties rail.

## Architecture

- **One migration** adds `branch :string` + `plan :text` (both nullable) to `cards`.
- **`Schemas.Card.changeset/2`** casts `:branch` and `:plan` alongside
  `:title/:description/:tag`. Programmatic fields (`board_id`, `stage_id`, `position`,
  `ref_number`) stay uncast — never settable from input.
- **No new context functions.** `Relay.Cards.update_card/2` already routes through
  `Card.changeset/2` and broadcasts `{:card_upserted, card}` via `Relay.Events` (MMF 18),
  so casting the two fields makes them persist + broadcast for free.
- **API:** `RelayWeb.Api.CardController.update/2` builds its field-update payload with
  `Map.take(params, [...])` — add `"branch"` and `"plan"` to that take list.
  `RelayWeb.Api.CardJSON.data/2` is the shared card shape used by `GET /api/cards`,
  `GET /api/cards/:ref`, and `GET /api/board` (via `BoardJSON`) — add `branch` + `plan`
  there once and all three endpoints include them.
- **Drawer (`RelayWeb.CoreComponents.card_drawer/1`):** a `<details class="collapse">`
  "Plan" section (daisyUI details-style collapse, **no `open` attribute** so it is collapsed
  by default) with a whitespace-preserving `<pre>` body, rendered only when `card.plan` is
  present; and a `Branch` row in the properties rail (`<dl id="card-drawer-rail">`) showing
  a mono badge chip with an icon, only when `card.branch` is present. Read-only UI — the
  runner writes both via the API. `BoardLive` already refreshes an open drawer on
  `{:card_upserted}` (`maybe_refresh_drawer/2`), so live updates need no LiveView changes.
- **Board cards are unchanged** — branch/plan are drawer-level detail only.

## Tech

Elixir / Phoenix 1.8, Ecto (Postgres), Phoenix LiveView, daisyUI + Tailwind v4,
Phoenix Storybook, ExMachina factories, `boundary`-enforced contexts.

## Global Constraints

- `mix precommit` MUST pass before a task is done: compile with warnings-as-errors,
  `mix format` (Styler), `mix credo --strict`, `mix sobelow`, `mix deps.audit`, full test
  suite (warnings as errors).
- Context boundaries are compiler-enforced (`boundary`): the web layer only calls the domain
  through `Relay`'s exported contexts. This plan adds no new context or boundary.
- Programmatic card fields (`board_id`, `stage_id`, `position`, `ref_number`) are **never
  cast** from input — do not add them to any `cast/3` list.
- `Ecto.Schema` fields use `:string` even for `:text` columns (`field :plan, :string`).
- HEEx: use the list `[...]` syntax for multi-value `class` attributes; use the imported
  `<.icon name="hero-...">` component for icons; give key elements unique DOM ids; HEEx
  comments are `<%!-- ... --%>`; interpolate with `{...}` in attributes/bodies.
- Prefer daisyUI primitives (`collapse`, `badge`) over hand-written CSS.
- Predicate functions end in `?`, never start with `is_`.
- Tests: use element ids with `has_element?/2`/`element/2`, never assert on raw HTML; no
  `Process.sleep/1`.
- Reusable-component changes refresh the matching story under `storybook/` — and the final
  report to the user must link the storybook page.
- Keep scope minimal: two fields, their API surface, and the drawer rendering. No board-card
  chrome, no drawer editing of branch/plan, no runner changes.

---

### Task 1: `branch` + `plan` on the Card — schema, migration, context cast, API read/write

**Files**

- Create: `priv/repo/migrations/<timestamp>_add_branch_and_plan_to_cards.exs`
  (generate with `mix ecto.gen.migration add_branch_and_plan_to_cards`)
- Modify: `lib/schemas/card.ex`
- Modify: `lib/relay/cards.ex` (doc only — behaviour comes from the changeset)
- Modify: `lib/relay_web/controllers/api/card_controller.ex`
- Modify: `lib/relay_web/controllers/api/card_json.ex`
- Test: `test/relay/cards_test.exs`
- Test: `test/relay/context_broadcasts_test.exs`
- Test: `test/relay_web/api/card_controller_test.exs`

**Interfaces**

- Consumes (already shipped, unchanged signatures):
  - `Relay.Cards.update_card(%Schemas.Card{}, attrs :: map()) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`
    — routes through `Schemas.Card.changeset/2`, preloads owners, broadcasts
    `{:card_upserted, card}` on success via `Relay.Events.broadcast/2`.
  - `Relay.Events.subscribe(board_id :: integer()) :: :ok | {:error, term()}`
  - `RelayWeb.Api.CardJSON.data(board, card) :: map()` — the shared card JSON shape used by
    `CardJSON.index/1`, `CardJSON.show/1`, and `RelayWeb.Api.BoardJSON.show/1`.
- Produces (Task 2 relies on these):
  - `%Schemas.Card{}` structs now carry `branch :: String.t() | nil` and
    `plan :: String.t() | nil`, settable via
    `Relay.Cards.update_card(card, %{branch: "...", plan: "..."})` and via the card factory
    (`insert(:card, branch: "...", plan: "...")` — `merge_attributes/2` handles the new
    schema fields with no factory change; defaults are `nil`).
  - `PATCH /api/cards/:ref` accepts `"branch"` and `"plan"`; card JSON from
    `GET /api/cards`, `GET /api/cards/:ref`, and `GET /api/board` includes `"branch"` and
    `"plan"` keys.

**Steps**

- [x] Generate the migration with `mix ecto.gen.migration add_branch_and_plan_to_cards`
      and fill it in (both columns nullable — no defaults, no not-null):

  ```elixir
  defmodule Relay.Repo.Migrations.AddBranchAndPlanToCards do
    use Ecto.Migration

    def change do
      alter table(:cards) do
        add :branch, :string
        add :plan, :text
      end
    end
  end
  ```

- [x] Run `mix ecto.migrate` (the test DB migrates automatically on `mix test`).

- [x] Write the failing context tests. In `test/relay/cards_test.exs`, add these two tests
      inside the existing `describe "update_card/2" do` block (the file already has
      `alias Relay.Cards`, `alias Schemas.Card`, a `%{board: board, stage: stage}` setup,
      and `Repo` via `Relay.DataCase`):

  ```elixir
  test "persists branch and plan and they survive a reload", %{stage: stage} do
    {:ok, card} = Cards.create_card(stage, %{title: "Runner card"})

    assert {:ok, %Card{} = updated} =
             Cards.update_card(card, %{
               branch: "rly-21-card-branch-plan",
               plan: "## Task 1\n\n- [ ] add the fields"
             })

    assert updated.branch == "rly-21-card-branch-plan"
    assert updated.plan == "## Task 1\n\n- [ ] add the fields"

    reloaded = Repo.get!(Card, card.id)
    assert reloaded.branch == "rly-21-card-branch-plan"
    assert reloaded.plan == "## Task 1\n\n- [ ] add the fields"
  end

  test "setting branch and plan never touches the programmatic fields", %{stage: stage} do
    {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

    assert {:ok, updated} =
             Cards.update_card(card, %{
               branch: "rly-21-card-branch-plan",
               plan: "the plan",
               board_id: card.board_id + 1,
               stage_id: card.stage_id + 1,
               position: 99,
               ref_number: 99
             })

    assert updated.branch == "rly-21-card-branch-plan"
    assert updated.plan == "the plan"
    assert updated.board_id == card.board_id
    assert updated.stage_id == card.stage_id
    assert updated.position == card.position
    assert updated.ref_number == card.ref_number
  end
  ```

- [x] Write the failing broadcast test. In `test/relay/context_broadcasts_test.exs`, add
      inside the existing `describe "Cards broadcasts" do` block (setup already subscribes
      via `Events.subscribe(board.id)` and provides `%{backlog: backlog}`):

  ```elixir
  test "update_card with branch and plan broadcasts {:card_upserted, card} carrying them",
       %{backlog: backlog} do
    {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Runner"})
    assert_receive {:card_upserted, %Card{id: ^card_id}}

    {:ok, _card} = Cards.update_card(card, %{branch: "rly-9-live", plan: "Step 1: do it"})

    assert_receive {:card_upserted, %Card{id: ^card_id, branch: "rly-9-live", plan: "Step 1: do it"}}
  end
  ```

- [x] Write the failing API tests. In `test/relay_web/api/card_controller_test.exs`, add at
      the bottom of the module (the file already has the Bearer-token `setup`, the
      `ref(board, card)` helper, and `alias Relay.Cards`):

  ```elixir
  test "PATCH sets branch and plan and GET /api/cards/:ref returns them",
       %{conn: conn, board: board, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")

    body =
      conn
      |> patch(~p"/api/cards/#{ref(board, card)}", %{
        branch: "rly-21-card-branch-plan",
        plan: "## Task 1\n\nDo the thing"
      })
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["branch"] == "rly-21-card-branch-plan"
    assert body["plan"] == "## Task 1\n\nDo the thing"

    fetched = conn |> get(~p"/api/cards/#{ref(board, card)}") |> json_response(200) |> Map.fetch!("data")
    assert fetched["branch"] == "rly-21-card-branch-plan"
    assert fetched["plan"] == "## Task 1\n\nDo the thing"
  end

  test "GET /api/board card JSON includes branch and plan", %{conn: conn, stage: stage} do
    card = insert(:card, stage: stage, title: "Runner card")
    {:ok, _card} = Cards.update_card(card, %{branch: "rly-21-b", plan: "the plan"})

    body = conn |> get(~p"/api/board") |> json_response(200)

    assert [card_json] = body["cards"]
    assert card_json["branch"] == "rly-21-b"
    assert card_json["plan"] == "the plan"
  end
  ```

- [x] Run the new tests — expect failures (unknown fields / missing JSON keys):
      `mix test test/relay/cards_test.exs test/relay/context_broadcasts_test.exs test/relay_web/api/card_controller_test.exs`

- [x] Implement the schema change in `lib/schemas/card.ex`. Add the two fields to the
      schema block, right after `field :blocked_since, :utc_datetime`:

  ```elixir
      field :branch, :string
      field :plan, :string
  ```

  and replace `changeset/2` (doc + cast list — `validate_required` and the unique
  constraint are unchanged):

  ```elixir
    @doc """
    Changeset for user/agent-supplied card attributes (`:title`,
    `:description`, `:tag`, `:branch`, `:plan`). `board_id`, `stage_id`,
    `position`, and `ref_number` must already be set on the struct and are
    never cast.
    """
    def changeset(card, attrs) do
      card
      |> cast(attrs, [:title, :description, :tag, :branch, :plan])
      |> validate_required([:title])
      |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
    end
  ```

  Also mention the new fields in the schema `@moduledoc` by appending one sentence to the
  existing paragraph: `` `branch` and `plan` (MMF spec 2026-07-08) carry the runner's git
  branch and implementation plan with the card; both nullable, both cast like
  `description`. ``

- [x] Update the `Relay.Cards.update_card/2` `@doc` in `lib/relay/cards.ex` so the contract
      names the new fields (implementation body unchanged):

  ```elixir
    @doc """
    Updates a card's user/agent-editable attributes (`:title`, `:description`,
    `:tag`, `:branch`, `:plan`), returning `{:ok, card}` or
    `{:error, changeset}`. The programmatic fields (`board_id`, `stage_id`,
    `position`, `ref_number`) are never cast and cannot be changed here.
    """
  ```

- [x] Extend the API surface. In `lib/relay_web/controllers/api/card_controller.ex`, change
      the take list in `update_fields/2`:

  ```elixir
    defp update_fields(card, params) do
      case Map.take(params, ["title", "description", "tag", "branch", "plan"]) do
        empty when map_size(empty) == 0 -> {:ok, card}
        fields -> Cards.update_card(card, fields)
      end
    end
  ```

  In `lib/relay_web/controllers/api/card_json.ex`, add the two keys to the shared shape in
  `data/2` (after `progress:`):

  ```elixir
        branch: card.branch,
        plan: card.plan,
  ```

  so the full map reads:

  ```elixir
    def data(board, card) do
      %{
        id: card.id,
        ref: Cards.ref(board, card),
        title: card.title,
        tag: card.tag,
        status: card.status,
        progress: card.progress,
        branch: card.branch,
        plan: card.plan,
        stage_id: card.stage_id,
        owners: Enum.map(card.owners, &owner/1),
        active_owner: Cards.active_owner_type(card)
      }
    end
  ```

- [x] Re-run the three test files — expect all green:
      `mix test test/relay/cards_test.exs test/relay/context_broadcasts_test.exs test/relay_web/api/card_controller_test.exs test/relay_web/api/board_controller_test.exs`

- [x] Run `mix precommit` and fix anything it flags.

- [x] Commit.

**Deliverable:** `branch` and `plan` persist through `Cards.update_card/2` (programmatic
fields untouched), are settable via `PATCH /api/cards/:ref`, appear in `GET /api/cards/:ref`
/ `GET /api/cards` / `GET /api/board` card JSON, and every write broadcasts
`{:card_upserted, card}` carrying the new values. `mix precommit` green.

**Commit message:**
`feat(cards): branch + plan card fields — schema, update_card cast, API read/write`

---

### Task 2: Drawer UI — collapsed "Plan" section + branch chip, storybook variation

**Files**

- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1`)
- Modify: `storybook/core_components/card_drawer.story.exs`
- Test: `test/relay_web/live/board_live_test.exs`
- Test: `test/relay_web/live/board_live_realtime_test.exs`

**Interfaces**

- Consumes (from Task 1):
  - `%Schemas.Card{}` exposes `branch :: String.t() | nil` and `plan :: String.t() | nil`;
    set them in tests with
    `Relay.Cards.update_card(card, %{branch: "...", plan: "..."}) :: {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}`.
  - `PATCH /api/cards/:ref` accepts `%{branch: "...", plan: "..."}` with a Bearer API key.
  - `{:card_upserted, card}` broadcasts on every such write; `RelayWeb.BoardLive` already
    applies it (`handle_info({:card_upserted, ...})` → `maybe_refresh_drawer/2`), so an open
    drawer re-renders with the fresh card — no LiveView changes in this task.
- Produces:
  - `card_drawer/1` renders `details#card-plan` (collapsed daisyUI collapse, only when
    `card.plan` present, body in `pre#card-plan-body` with `whitespace-pre-wrap`) and
    `span#card-branch` (mono badge chip inside the `#card-drawer-rail` properties `<dl>`,
    only when `card.branch` present). The `@card` attr now additionally reads `card.branch`
    and `card.plan` — every caller passing a plain map (storybook) must include both keys.

**Steps**

- [ ] Write the failing drawer tests. In `test/relay_web/live/board_live_test.exs`, add a
      new describe block after the existing `describe "card drawer" do` block (the module
      already imports `Phoenix.LiveViewTest` and aliases `Relay.Boards` / `Relay.Cards`):

  ```elixir
    describe "drawer plan and branch" do
      setup :register_and_log_in_user

      setup %{user: user} do
        board = Boards.get_or_create_default_board(user)
        [backlog | _rest] = board.stages
        {:ok, card} = Cards.create_card(backlog, %{title: "Wire the runner"})
        %{board: board, backlog: backlog, card: card}
      end

      test "a card with a plan renders the Plan section collapsed by default",
           %{conn: conn, card: card} do
        {:ok, _card} = Cards.update_card(card, %{plan: "## Task 1\n\n- [ ] do the thing"})

        {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

        assert has_element?(view, "details#card-plan .collapse-title", "Plan")
        assert has_element?(view, "details#card-plan pre#card-plan-body", "do the thing")
        assert has_element?(view, "details#card-plan pre.whitespace-pre-wrap")
        # collapsed by default: the <details> must NOT carry the open attribute
        refute has_element?(view, "details#card-plan[open]")
      end

      test "a card with a branch renders the branch chip in the rail",
           %{conn: conn, card: card} do
        {:ok, _card} = Cards.update_card(card, %{branch: "rly-21-card-branch-plan"})

        {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

        assert has_element?(view, "#card-drawer-rail #card-branch", "rly-21-card-branch-plan")
        assert has_element?(view, "#card-branch.font-mono")
      end

      test "a card with neither branch nor plan renders neither", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

        assert has_element?(view, "#card-drawer")
        refute has_element?(view, "#card-plan")
        refute has_element?(view, "#card-branch")
      end
    end
  ```

- [ ] Write the failing live-update test. In
      `test/relay_web/live/board_live_realtime_test.exs`, add inside the existing
      `describe "API-driven changes update mounted LiveViews" do` block (its setup already
      provides `%{backlog: backlog, token: token}` and the module defines
      `api_conn(token)`):

  ```elixir
    test "an API branch/plan update refreshes another session's open drawer",
         %{conn: conn, backlog: backlog, token: token} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Runner card"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
      refute has_element?(view, "#card-plan")

      assert token
             |> api_conn()
             |> patch(~p"/api/cards/RLY-1", %{branch: "rly-9-live", plan: "Step 1: do it"})
             |> json_response(200)

      assert has_element?(view, "#card-drawer-rail #card-branch", "rly-9-live")
      assert has_element?(view, "details#card-plan pre#card-plan-body", "Step 1: do it")
      refute has_element?(view, "details#card-plan[open]")
    end
  ```

- [ ] Run them — expect failures (no `#card-plan` / `#card-branch` elements):
      `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs`

- [ ] Implement in `lib/relay_web/components/core_components.ex`, inside `card_drawer/1`.

      First update the `@card` attr doc so the contract names the new fields — replace the
      existing `attr :card, :any` doc string with:

  ```elixir
    attr :card, :any,
      required: true,
      doc:
        "a card exposing title, description, tag, status, progress, blocked_since, branch, plan, a loaded owners list, inserted_at, and updated_at"
  ```

      **Plan section** — insert this block immediately after the closing `</section>` of the
      Description section (the one ending with the description `<.form>`) and before the
      `<dl id={"#{@id}-rail"} ...>` properties rail. A `<details>` without the `open`
      attribute is collapsed by default; daisyUI's details-style `collapse` needs no
      checkbox input:

  ```heex
            <details
              :if={@card.plan}
              id="card-plan"
              class="collapse collapse-arrow rounded-lg border border-base-300 bg-base-200/40"
            >
              <summary class="collapse-title min-h-0 py-3 font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60">
                Plan
              </summary>
              <div class="collapse-content">
                <pre
                  id="card-plan-body"
                  class="overflow-x-auto whitespace-pre-wrap font-mono text-xs leading-relaxed text-base-content/80"
                  phx-no-format
                >{@card.plan}</pre>
              </div>
            </details>
  ```

      **Branch chip** — insert this `<dt>`/`<dd>` pair inside the `<dl id={"#{@id}-rail"}>`
      properties rail, between the Stage `<dd class="rail-stage">…</dd>` and the
      `<dt>…Tags…</dt>` entry:

  ```heex
            <dt
              :if={@card.branch}
              class="font-mono text-[10px] font-semibold uppercase tracking-[0.06em] text-base-content/60"
            >
              Branch
            </dt>
            <dd :if={@card.branch} class="rail-branch">
              <span id="card-branch" class="badge badge-ghost badge-sm gap-1 font-mono">
                <.icon name="hero-share" class="size-3" />
                {@card.branch}
              </span>
            </dd>
  ```

      Also extend the component `@doc` (the paragraph describing the drawer contents) by
      appending: `When the card carries a runner \`plan\` it renders in a collapsed-by-default
      "Plan" collapse section below the description; a \`branch\` renders as a mono chip in
      the properties rail. Both are read-only here — the runner sets them via the API.`

- [ ] Re-run the two LiveView test files — expect all green:
      `mix test test/relay_web/live/board_live_test.exs test/relay_web/live/board_live_realtime_test.exs`

- [ ] Refresh the storybook story `storybook/core_components/card_drawer.story.exs`
      (`card_drawer/1` reads `@card.branch` / `@card.plan` on plain maps, so the story card
      MUST gain both keys or every variation raises `KeyError`).

      1. In `defp story_card do`, add the two defaults after `blocked_since: nil,`:

  ```elixir
        branch: nil,
        plan: nil,
  ```

      2. Add a new variation at the end of the `variations/0` list (after
         `:in_review_request_changes`):

  ```elixir
        %Variation{
          id: :with_branch_and_plan,
          attributes: %{
            id: "story-drawer-6",
            ref: "RLY-12",
            card: %{
              story_card()
              | branch: "rly-12-wire-the-runner",
                plan:
                  "## Task 1 — Schema + API\n\n- [x] migration: add branch + plan\n- [x] cast in Card.changeset/2\n- [ ] PATCH /api/cards/:ref accepts both\n\n## Task 2 — Drawer\n\n- [ ] collapsed Plan section\n- [ ] branch chip in the rail"
            },
            stage_name: "Code",
            stage_owner: :ai,
            active_owner: :ai,
            current_user_id: 1,
            close_patch: "/storybook/core_components/card_drawer",
            title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
            status_form: Phoenix.Component.to_form(%{"status" => "working", "progress" => 61}, as: :card),
            timeline: story_timeline(),
            comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment)
          }
        }
  ```

- [ ] Run `mix precommit` and fix anything it flags.

- [ ] Commit.

**Deliverable:** an open card drawer shows a collapsed-by-default "Plan" collapse section
(`details#card-plan`, whitespace-preserved `pre#card-plan-body`) only when the card has a
plan, and a mono branch chip (`span#card-branch`) in the properties rail only when it has a
branch; a `PATCH /api/cards/:ref` setting either updates an already-open drawer live via
`{:card_upserted}`; the `card_drawer` storybook story has a branch+plan variation at
`/storybook/core_components/card_drawer` (tell the user this storybook link in the final
report). `mix precommit` green.

**Commit message:**
`feat(drawer): collapsed Plan section + branch chip in the card drawer`

---

## Self-review notes (verified against the shipped code)

- **Spec coverage:** branch+plan API read/write → Task 1 (PATCH take-list, `CardJSON.data/2`
  covers `:ref`, index, and `/api/board` since `BoardJSON.show/1` delegates to it); plan
  collapsed by default → Task 2 (`<details>` with no `open`, asserted via
  `refute has_element?(view, "details#card-plan[open]")`); branch chip → Task 2; live
  broadcast → Task 1 broadcast test + Task 2 two-session API test (`maybe_refresh_drawer/2`
  already re-renders the open drawer on `{:card_upserted}`); programmatic-field protection →
  Task 1 test casting sneaky `board_id`/`stage_id`/`position`/`ref_number` alongside
  branch/plan; empty-state (neither renders) → Task 2 test.
- **Signature consistency:** Task 2 consumes exactly what Task 1 produces
  (`Cards.update_card/2` attrs `%{branch:, plan:}`, `PATCH /api/cards/:ref` params,
  `card.branch`/`card.plan` struct fields).
- **No placeholders:** every step carries the actual code; test helper names
  (`register_and_log_in_user`, `ref/2`, `api_conn/1`, `insert(:card, ...)`) all exist in the
  named files today.
- Storybook `story_card/0` gains `branch: nil, plan: nil` so all pre-existing variations
  keep working after `card_drawer/1` starts reading the new keys.
