# Plan: MMF 04 — Card detail drawer

Spec: `docs/superpowers/specs/2026-07-07-card-drawer-design.md`. Builds directly on MMFs
01–03, all already merged to `main` (auth, board + stages, create & title cards).

## Goal

Clicking a card on `/board` opens a right-side detail drawer (daisyUI `drawer drawer-end` +
scrim) rendered inside the existing `RelayWeb.BoardLive` — NO new route or LiveView. The
drawer is driven by a `?card=<ref>` query param (deep-linkable, e.g. `/board?card=RLY-3`)
via `handle_params`. It shows a header (stage chip in the stage-owner color, the card ref,
an **editable title**), a plain-text **description** section (whitespace-preserved view,
`textarea` to edit — no markdown/rich editing, that's MMF 16), and a properties rail
(current STAGE, TAGS, created/updated DATES). Title/description edits persist via a new
`Relay.Cards.update_card/2` and reflect on the board card without a full reload (re-stream
the card). ✕ or a scrim click patches back to `/board` and closes the drawer. A ref that is
unknown, malformed, or belongs to another user's board opens nothing (authorization via
board scoping).

## Architecture

- **Data:** the `cards` table gains a nullable `description` `:text` column (one `alter`
  migration). `Relay.Cards.Card` gains `field :description, :string`; `Card.changeset/2`
  casts `[:title, :description, :tag]` and keeps requiring `:title`.
  `board_id`/`stage_id`/`position`/`ref_number` stay programmatic-only (never cast).
- **Context:** two new public functions in `Relay.Cards` (context already exported from
  `Relay`, so NO Boundary changes): `update_card/2` (user-editable attrs only) and
  `get_card_by_ref/2` (parses `"KEY-N"` against the board's key, then `Repo.get_by` scoped
  by `board_id` — that scoping IS the authorization: another board's card is unreachable).
- **URL-driven drawer:** `BoardLive` gets `handle_params/3` (runs after `mount/3` on first
  render and on every patch) that reads `params["card"]`, resolves it via
  `Cards.get_card_by_ref/2`, and assigns `@selected_card` plus `@selected_stage`,
  `@title_form`, `@editing_description`, `@description_form` (all nil/false when no valid
  ref). Opening = a `phx-click` on `board_card` that the LiveView answers with
  `push_patch(to: ~p"/board?card=#{ref}")`; closing = `patch` links (✕ and scrim) back to
  `~p"/board"`.
- **Component:** a new reusable `card_drawer/1` in `RelayWeb.CoreComponents` following the
  same parent-handles-events pattern as `stage_column/1`, with a Storybook story at
  `storybook/core_components/card_drawer.story.exs` (page:
  `/storybook/core_components/card_drawer`).
- **Board reflection:** on a successful save, `stream_insert/3` the updated card into its
  per-stage stream via BoardLive's existing private `stream_name/1`
  (`:"stage_cards_#{stage_id}"`) so the column card updates in place.

Out of scope (per spec): markdown/rich text (MMF 16), comments/activity (07), AI result &
sub-tasks (16), owner/status action panels (06/14/15), moving cards between stages.

## Tech

Elixir / Phoenix 1.8 / LiveView 1.1 (streams, `handle_params`, `push_patch`), Ecto +
Postgres, Boundary (compiler-enforced), daisyUI (`drawer drawer-end`, `badge`, `btn`,
`textarea`) + Tailwind v4, phoenix_storybook, ExMachina factories, ExUnit +
`Phoenix.LiveViewTest` + LazyHTML. Toolchain via `mise`.

## Global Constraints

- `mix precommit` must pass on every development cycle and before any task is considered
  done. It runs compile (warnings as errors), `mix format` (with Styler), `mix credo
  --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings as errors).
  Never commit with a failing `mix precommit`.
- Boundary rules: the web layer (`RelayWeb`) may only call the domain through `Relay`'s
  exported contexts; contexts may not reach into the web layer. This MMF adds no new
  *context* (`Relay.Cards` is already in `Relay`'s `exports`) — but Task 2 does add one
  entry to `Relay`'s top-level `exports` list: `Cards.Card`. Referencing a context's struct
  type from the web layer (here, `%Card{}` pattern-matched in `BoardLive`) requires that
  struct to be separately exported from `Relay`, exactly like `Accounts.Scope` already is
  alongside `Accounts` — exporting the context module alone isn't enough once the web layer
  needs the struct type itself. (An earlier draft of this doc claimed no Boundary changes at
  all; that was wrong — verified by reverting the `Cards.Card` export and observing `mix
  compile --warnings-as-errors` fail on the `%Card{}` reference in `board_live.ex`.) Any
  *other* Boundary violation still fails compilation.
- Toolchain runs through `mise` — prefix mix commands with `mise exec --` (bare `mix` also
  works).
- Warnings-as-errors: both compilation and the test run treat warnings as errors — never
  introduce a warning.

Run all commands from the repo root `/Users/jeremy/src/relay`. Before Task 1, create the
working branch (we are on `main`):

```bash
git checkout -b mmf-04-card-drawer
```

(The spec mentions a shared `mmf-02-04-board` branch; in this repo MMFs 02 and 03 are
already merged to `main`, so branch fresh from `main`.)

## Interfaces inherited from MMFs 01–03 (exact, already merged)

- `Relay.Boards.get_or_create_default_board(%Relay.Accounts.User{}) :: %Board{}` — the
  user's board with `stages` preloaded in `position` order.
  `%Relay.Boards.Board{id, name, slug, key ("RLY" by default), card_seq, owner_id, stages}`.
- `%Relay.Boards.Stage{id, name, position, category :: :unstarted | :in_progress | :complete, owner :: :human | :ai, board_id}`.
- `Relay.Cards.create_card(%Stage{}, attrs) :: {:ok, %Card{}} | {:error, %Ecto.Changeset{}}`.
- `Relay.Cards.list_cards(%Board{}) :: [%Card{}]` — ordered stage → position.
- `Relay.Cards.ref(%Board{key: key}, %Card{ref_number: n}) :: String.t()` — e.g. `"RLY-12"`.
- `%Relay.Cards.Card{id, title, position, tag, ref_number, board_id, stage_id, inserted_at, updated_at}`
  with `timestamps(type: :utc_datetime)`; `Card.changeset(card, attrs)` currently casts
  `[:title, :tag]`, requires `:title`.
- `RelayWeb.BoardLive` at `live "/board", BoardLive` inside the authenticated
  `live_session`; per-stage streams named by the private
  `stream_name(stage_id) :: :"stage_cards_#{stage_id}"`; columns render as
  `#stage-col-<position>` with a `#stage-col-<position>-cards` stream container; the first
  seeded stage is "Backlog" (`:human`, position 1) so its column is `#stage-col-1`.
- `RelayWeb.CoreComponents.board_card/1` (attrs `id`, `ref`, `title`, `tag`) rendering
  `article.board-card` containing `p.card-title`, `span.card-tag`, `span.card-ref`.
- `RelayWeb.CoreComponents`: `owner_pill/1`, `stage_column/1`, `icon/1`, `input/1`
  (supports `type="textarea"`, explicit `id`, `class` override replaces ALL defaults),
  `button/1`.
- Tests: `RelayWeb.ConnCase` (imports the factory; `register_and_log_in_user/1` setup,
  `log_in_user/2`); `Relay.DataCase` (`errors_on/1`, aliased `Repo`);
  `Relay.Factory` — `insert(:user | :board | :stage | :card)`; the card factory requires a
  **persisted** `stage:` override and derives `stage_id`/`board_id` from it; factory boards
  default to `key: "RLY"`.

---

### Task 1 — Data layer: `description` column, `Cards.update_card/2`, `Cards.get_card_by_ref/2`

**Files**

- `priv/repo/migrations/<generated-timestamp>_add_description_to_cards.exs` (new, generated)
- `lib/relay/cards/card.ex` (edit)
- `lib/relay/cards.ex` (edit)
- `test/relay/cards_test.exs` (edit)

**Interfaces**

- Consumes: `Cards.create_card/2`, `Card.changeset/2`, `insert(:stage)`, `errors_on/1`,
  `Repo` (aliased in `Relay.DataCase`).
- Produces (later tasks rely on these EXACT signatures):
  - `%Relay.Cards.Card{}` gains `description :: String.t() | nil`.
  - `Relay.Cards.update_card(%Card{}, attrs :: map()) :: {:ok, %Card{}} | {:error, %Ecto.Changeset{}}`
    — casts only `title`/`description`/`tag`; never changes `board_id`, `stage_id`,
    `position`, or `ref_number`.
  - `Relay.Cards.get_card_by_ref(%Board{}, ref :: String.t()) :: %Card{} | nil` — `nil`
    for malformed refs, wrong board key, unknown numbers, and other boards' cards.

**Steps**

- [x] Create the feature branch:

  ```bash
  git checkout -b mmf-04-card-drawer
  ```

- [x] Write the failing tests. In `test/relay/cards_test.exs`, add these two `describe`
  blocks after the existing `describe "list_cards/1"` block (before the module's final
  `end`). The file's existing `setup` already provides `%{board, stage}` where
  `board = insert(:board, key: "RLY")` and `stage` belongs to it:

  ```elixir
  describe "update_card/2" do
    test "updates title, description, and tag", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Before"})

      assert {:ok, %Card{} = updated} =
               Cards.update_card(card, %{
                 title: "After",
                 description: "Line one\n\nLine two",
                 tag: "infra"
               })

      assert updated.title == "After"
      assert updated.description == "Line one\n\nLine two"
      assert updated.tag == "infra"
      assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
    end

    test "rejects a blank title and persists nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Keep me"})

      assert {:error, changeset} = Cards.update_card(card, %{title: ""})
      assert "can't be blank" in errors_on(changeset).title
      assert Repo.get!(Card, card.id).title == "Keep me"
    end

    test "clearing the description stores nil", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})
      {:ok, card} = Cards.update_card(card, %{description: "something"})

      assert {:ok, updated} = Cards.update_card(card, %{description: ""})
      assert updated.description == nil
    end

    test "never changes board_id, stage_id, position, or ref_number", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Pinned"})

      assert {:ok, updated} =
               Cards.update_card(card, %{
                 title: "Still pinned",
                 board_id: card.board_id + 1,
                 stage_id: card.stage_id + 1,
                 position: 99,
                 ref_number: 99
               })

      assert updated.board_id == card.board_id
      assert updated.stage_id == card.stage_id
      assert updated.position == card.position
      assert updated.ref_number == card.ref_number
    end
  end

  describe "get_card_by_ref/2" do
    test "returns the card the ref points at on the board", %{board: board, stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Find me"})

      assert %Card{id: id} = Cards.get_card_by_ref(board, "RLY-1")
      assert id == card.id
    end

    test "returns nil for an unknown ref number", %{board: board} do
      assert Cards.get_card_by_ref(board, "RLY-99") == nil
    end

    test "returns nil for malformed or foreign-key refs", %{board: board, stage: stage} do
      {:ok, _card} = Cards.create_card(stage, %{title: "Here"})

      for ref <- ["", "RLY", "RLY-", "RLY-abc", "RLY-1extra", "RLY--1", "RLY-0", "OPS-1", "rly-1"] do
        assert Cards.get_card_by_ref(board, ref) == nil, "expected nil for #{inspect(ref)}"
      end
    end

    test "never returns another board's card", %{board: board} do
      other_stage = insert(:stage)

      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Theirs"})

      assert Cards.get_card_by_ref(board, "RLY-1") == nil
    end
  end
  ```

  (In the last test, `insert(:stage)` builds its OWN board, which also defaults to key
  `"RLY"` — so `"RLY-1"` exists there but must not resolve on `board`.)

- [x] Run the tests and confirm they FAIL (undefined `Cards.update_card/2` and
  `Cards.get_card_by_ref/2`, unknown `:description` key):

  ```bash
  mise exec -- mix test test/relay/cards_test.exs
  ```

- [x] Generate the migration:

  ```bash
  mise exec -- mix ecto.gen.migration add_description_to_cards
  ```

  Replace the generated file's contents (keep the generated timestamped filename) with:

  ```elixir
  defmodule Relay.Repo.Migrations.AddDescriptionToCards do
    use Ecto.Migration

    def change do
      alter table(:cards) do
        add :description, :text
      end
    end
  end
  ```

- [x] Update the schema. In `lib/relay/cards/card.ex`, add directly under
  `field :title, :string`:

  ```elixir
  field :description, :string
  ```

  and in `changeset/2` replace the cast line

  ```elixir
  |> cast(attrs, [:title, :tag])
  ```

  with

  ```elixir
  |> cast(attrs, [:title, :description, :tag])
  ```

  Also update the `@doc` on `changeset/2` to name the new field:

  ```elixir
  @doc """
  Changeset for user-supplied card attributes (`:title`, `:description`,
  `:tag`). `board_id`, `stage_id`, `position`, and `ref_number` must
  already be set on the struct and are never cast.
  """
  ```

- [x] Add the context functions. In `lib/relay/cards.ex`, insert after the `ref/2`
  function (before the private `allocate_ref_number/1`):

  ```elixir
  @doc """
  Updates a card's user-editable attributes (`:title`, `:description`,
  `:tag`), returning `{:ok, card}` or `{:error, changeset}`. The
  programmatic fields (`board_id`, `stage_id`, `position`, `ref_number`)
  are never cast and cannot be changed here.
  """
  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
  end

  @doc """
  Fetches the card a human-facing ref (e.g. `"RLY-12"`) points at on
  `board`, or `nil` when the ref does not parse against the board's key
  or no such card exists on that board. Scoping by `board_id` means a
  ref can never resolve to another board's card — this is the card
  drawer's authorization check.
  """
  def get_card_by_ref(%Board{} = board, ref) when is_binary(ref) do
    case parse_ref_number(board, ref) do
      {:ok, ref_number} -> Repo.get_by(Card, board_id: board.id, ref_number: ref_number)
      :error -> nil
    end
  end

  defp parse_ref_number(%Board{key: key}, ref) do
    prefix = key <> "-"

    with true <- String.starts_with?(ref, prefix),
         {ref_number, ""} <- Integer.parse(String.replace_prefix(ref, prefix, "")),
         true <- ref_number > 0 do
      {:ok, ref_number}
    else
      _ -> :error
    end
  end
  ```

- [x] Migrate the dev database (the `mix test` alias migrates the test DB itself):

  ```bash
  mise exec -- mix ecto.migrate
  ```

- [x] Run the tests and confirm they ALL PASS:

  ```bash
  mise exec -- mix test test/relay/cards_test.exs
  ```

- [x] Run the full gate and fix anything it flags:

  ```bash
  mise exec -- mix precommit
  ```

- [x] Commit:

  ```bash
  git add -A && git commit -m "Add card description, Cards.update_card/2, and Cards.get_card_by_ref/2"
  ```

**Deliverable:** `cards.description` exists in the DB; `Cards.update_card/2` mutates only
user-editable fields; `Cards.get_card_by_ref/2` resolves refs strictly scoped to one
board. All context tests green; `mix precommit` green.
**Commit:** `Add card description, Cards.update_card/2, and Cards.get_card_by_ref/2`

---

### Task 2 — Drawer opens/closes: `card_drawer/1` component, URL-driven `@selected_card`, deep link + authorization

**Files**

- `lib/relay.ex` (edit: add `Cards.Card` to `Relay`'s top-level Boundary `exports`,
  alongside the existing `Accounts.Scope` precedent — required because `BoardLive`
  pattern-matches `%Card{}`; see the Global Constraints Boundary-rules note)
- `lib/relay_web/components/core_components.ex` (edit: new `card_drawer/1`; `board_card/1`
  gains a click affordance)
- `lib/relay_web/live/board_live.ex` (edit: `handle_params/3`, `select_card` event, render
  the drawer)
- `storybook/core_components/card_drawer.story.exs` (new)
- `test/relay_web/live/board_live_test.exs` (edit: new `describe "card drawer"`)

**Interfaces**

- Consumes: `Cards.get_card_by_ref/2` and `Card.description` (Task 1); `Cards.ref/2`;
  `Cards.create_card/2`; `Boards.get_or_create_default_board/1`; BoardLive's private
  `stream_name/1` and `find_stage/2`; `icon/1`, `input/1`, `button/1`.
- Produces (Tasks 3–4 rely on these EXACT names):
  - `RelayWeb.CoreComponents.card_drawer/1` with attrs: `id :: :string (required)`,
    `ref :: :string (required)`, `card :: :any (required — needs .title / .description /
    .tag / .inserted_at / .updated_at)`, `stage_name :: :string (required)`,
    `stage_owner :: :human | :ai (required)`, `close_patch :: :string (required)`,
    `title_form :: Phoenix.HTML.Form (required)`,
    `editing_description :: :boolean (default false)`,
    `description_form :: Phoenix.HTML.Form | nil (default nil)`.
  - Events the component emits for the parent LiveView: `"save_card_title"` (form params
    `%{"card" => %{"title" => _}}`), `"edit_description"`, `"cancel_description"`,
    `"save_card_description"` (form params `%{"card" => %{"description" => _}}`).
  - `board_card/1` emits `"select_card"` with `phx-value-ref={@ref}` on click (attrs
    unchanged, so the existing `board_card` story keeps working).
  - BoardLive assigns set by `handle_params`: `@selected_card :: %Card{} | nil`,
    `@selected_stage :: %Stage{} | nil`, `@title_form`, `@editing_description :: boolean`,
    `@description_form`.
  - DOM ids (all derived from `id="card-drawer"`): `#card-drawer`, `#card-drawer-toggle`,
    `#card-drawer-scrim`, `#card-drawer-close`, `#card-drawer-title-form`,
    `#card-drawer-title-input`, `#card-drawer-description-edit`,
    `#card-drawer-description-view`, `#card-drawer-description-form`,
    `#card-drawer-description-input`, `#card-drawer-description-cancel`,
    `#card-drawer-rail`; classes `.drawer-stage-chip`, `.drawer-card-ref`, `.rail-stage`,
    `.rail-tags`, `.rail-dates`.

**Steps**

- [x] Write the failing tests. In `test/relay_web/live/board_live_test.exs`, first extend
  the alias block at the top of the module so it reads (Styler keeps it alphabetized):

  ```elixir
  alias Relay.Boards
  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards
  alias Relay.Cards.Card
  alias Relay.Repo
  ```

  then add this `describe` block after the existing `describe "cards"` block:

  ```elixir
  describe "card drawer" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec", tag: "spec"})
      %{board: board, backlog: backlog, card: card}
    end

    test "no drawer renders without a card param", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#card-drawer")
    end

    test "clicking a board card patches to its ref and opens the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-cards .board-card") |> render_click()

      assert_patch(view, ~p"/board?card=RLY-1")
      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer-title-input[value='Draft the spec']")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the drawer header shows the stage chip in the owner color", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer .drawer-stage-chip.badge-primary", "Backlog")
    end

    test "the properties rail shows stage, tags, and dates", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-stage", "Backlog")
      assert has_element?(view, "#card-drawer-rail .rail-tags", "spec")

      assert has_element?(
               view,
               "#card-drawer-rail .rail-dates",
               Calendar.strftime(card.inserted_at, "%b %d, %Y")
             )
    end

    test "visiting the deep link opens the drawer directly", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer")
      assert has_element?(view, "#card-drawer .drawer-card-ref", "RLY-1")
    end

    test "the close button clears the param and closes the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-close") |> render_click()

      assert_patch(view, ~p"/board")
      refute has_element?(view, "#card-drawer")
    end

    test "clicking the scrim clears the param and closes the drawer", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-scrim") |> render_click()

      assert_patch(view, ~p"/board")
      refute has_element?(view, "#card-drawer")
    end

    test "an unknown or malformed ref renders no drawer", %{conn: conn} do
      for ref <- ["RLY-999", "banana", "RLY-abc"] do
        {:ok, view, _html} = live(conn, ~p"/board?card=#{ref}")

        refute has_element?(view, "#card-drawer")
        assert has_element?(view, "#board")
      end
    end

    test "a ref for another user's card does not open the drawer", %{conn: conn} do
      other_stage = insert(:stage)
      insert(:card, stage: other_stage, title: "Theirs", ref_number: 2, position: 1)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-2")

      refute has_element?(view, "#card-drawer")
      assert has_element?(view, "#board")
    end
  end
  ```

  (In the foreign-card test, ref number 2 exists ONLY on the other user's board — the
  current user's board only has RLY-1 — so an open drawer would prove a scoping hole.
  `insert(:stage)` creates a fresh board whose key is also `"RLY"`.)

- [x] Run the LiveView tests and confirm the new ones FAIL (no `#card-drawer` in the DOM;
  the card click finds no `phx-click`):

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [x] Make `board_card/1` clickable. In `lib/relay_web/components/core_components.ex`,
  replace the opening tag of `board_card/1`'s template:

  ```heex
  <article id={@id} class="board-card card bg-base-100 shadow-sm">
  ```

  with:

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

  and append to its `@doc`:

  ```text
  Clicking the card emits a `"select_card"` event (with `phx-value-ref`)
  for the parent LiveView — `RelayWeb.BoardLive` answers with a patch to
  `?card=<ref>`, opening the card drawer.
  ```

- [x] Add the `card_drawer/1` component. In the same file, insert this after the whole
  `stage_column/1` function (before the `icon/1` `@doc`):

  ```elixir
  @doc """
  Renders the card detail drawer (daisyUI `drawer drawer-end`): a scrim
  plus a right-side panel with the card's stage chip (stage name in the
  Human/AI owner color), its ref, an editable title, the plain-text
  description (whitespace-preserved view or a textarea editor), and a
  properties rail (stage, tags, dates).

  Render it only while a card is selected. The ✕ button and the scrim
  are `patch` links to `close_patch`, so closing is a URL change the
  parent LiveView handles in `handle_params/3`.

  Events emitted (handled by the parent LiveView): `"save_card_title"`
  (form params `card[title]`) on title submit, `"edit_description"` when
  the description view is clicked, `"cancel_description"` on Cancel, and
  `"save_card_description"` (form params `card[description]`) on save.

  ## Examples

      <.card_drawer
        id="card-drawer"
        ref="RLY-3"
        card={@selected_card}
        stage_name="Spec"
        stage_owner={:human}
        close_patch={~p"/board"}
        title_form={@title_form}
      />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"

  attr :card, :any,
    required: true,
    doc: "a card exposing title, description, tag, inserted_at, and updated_at"

  attr :stage_name, :string, required: true
  attr :stage_owner, :atom, values: [:human, :ai], required: true
  attr :close_patch, :string, required: true, doc: "the patch target that closes the drawer"
  attr :title_form, :any, required: true, doc: "a Phoenix.HTML.Form for card[title]"
  attr :editing_description, :boolean, default: false

  attr :description_form, :any,
    default: nil,
    doc: "a Phoenix.HTML.Form for card[description]; required when editing_description"

  def card_drawer(assigns) do
    ~H"""
    <div id={@id} class="drawer drawer-end">
      <input
        id={"#{@id}-toggle"}
        type="checkbox"
        class="drawer-toggle"
        checked
        tabindex="-1"
        aria-hidden="true"
      />
      <div class="drawer-side z-40">
        <.link id={"#{@id}-scrim"} patch={@close_patch} class="drawer-overlay">
          <span class="sr-only">Close</span>
        </.link>
        <aside class="flex min-h-full w-full max-w-md flex-col gap-6 bg-base-100 p-5 shadow-xl">
          <header class="space-y-3">
            <div class="flex items-center justify-between gap-2">
              <div class="flex items-center gap-2">
                <span class={[
                  "drawer-stage-chip badge badge-sm font-medium",
                  if(@stage_owner == :human, do: "badge-primary", else: "badge-secondary")
                ]}>
                  {@stage_name}
                </span>
                <span class="drawer-card-ref font-mono text-xs text-base-content/60">{@ref}</span>
              </div>
              <.link
                id={"#{@id}-close"}
                patch={@close_patch}
                class="btn btn-ghost btn-sm btn-square"
                aria-label="Close card drawer"
              >
                <.icon name="hero-x-mark" class="size-5" />
              </.link>
            </div>
            <.form for={@title_form} id={"#{@id}-title-form"} phx-submit="save_card_title">
              <.input
                field={@title_form[:title]}
                type="text"
                id={"#{@id}-title-input"}
                class="input input-ghost w-full px-1 text-lg font-semibold"
                autocomplete="off"
              />
            </.form>
          </header>
          <section class="space-y-2">
            <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Description
            </h4>
            <div
              :if={!@editing_description}
              id={"#{@id}-description-edit"}
              role="button"
              tabindex="0"
              phx-click="edit_description"
              class="min-h-16 cursor-text rounded-lg p-1 hover:bg-base-200"
            >
              <p
                :if={@card.description}
                id={"#{@id}-description-view"}
                class="whitespace-pre-wrap text-sm leading-relaxed"
                phx-no-format
              >{@card.description}</p>
              <p :if={!@card.description} class="text-sm italic text-base-content/50">
                Add a description…
              </p>
            </div>
            <.form
              :if={@editing_description}
              for={@description_form}
              id={"#{@id}-description-form"}
              phx-submit="save_card_description"
            >
              <.input
                field={@description_form[:description]}
                type="textarea"
                id={"#{@id}-description-input"}
                rows="6"
                autofocus
              />
              <div class="flex items-center gap-2">
                <.button variant="primary" class="btn btn-primary btn-sm">Save</.button>
                <button
                  type="button"
                  id={"#{@id}-description-cancel"}
                  class="btn btn-ghost btn-sm"
                  phx-click="cancel_description"
                >
                  Cancel
                </button>
              </div>
            </.form>
          </section>
          <dl
            id={"#{@id}-rail"}
            class="grid grid-cols-[auto_1fr] gap-x-6 gap-y-3 border-t border-base-300 pt-4 text-sm"
          >
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Stage
            </dt>
            <dd class="rail-stage">{@stage_name}</dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Tags
            </dt>
            <dd class="rail-tags">
              <span :if={@card.tag} class="badge badge-ghost badge-sm">#{@card.tag}</span>
              <span :if={!@card.tag} class="text-base-content/50">None</span>
            </dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Dates
            </dt>
            <dd class="rail-dates space-y-0.5">
              <div>Created {Calendar.strftime(@card.inserted_at, "%b %d, %Y")}</div>
              <div>Updated {Calendar.strftime(@card.updated_at, "%b %d, %Y")}</div>
            </dd>
          </dl>
        </aside>
      </div>
    </div>
    """
  end
  ```

  Notes for the implementer: the always-`checked` hidden toggle drives daisyUI's
  `.drawer-toggle:checked ~ .drawer-side` open state — the whole component only exists in
  the DOM while a card is selected, so it renders open and is removed on close. The scrim
  is the `.drawer-overlay` `<.link patch>`. `phx-no-format` on the description `<p>` keeps
  the HEEx formatter from injecting whitespace inside the `whitespace-pre-wrap` block.

- [x] Wire up `RelayWeb.BoardLive` (`lib/relay_web/live/board_live.ex`):

  1. Extend the alias block to:

     ```elixir
     alias Relay.Boards
     alias Relay.Cards
     alias Relay.Cards.Card
     ```

  2. In `render/1`, insert the drawer right after the closing `</div>` of
     `<div id="board" ...>`, still inside `<Layouts.app ...>`:

     ```heex
     <.card_drawer
       :if={@selected_card}
       id="card-drawer"
       ref={Cards.ref(@board, @selected_card)}
       card={@selected_card}
       stage_name={@selected_stage.name}
       stage_owner={@selected_stage.owner}
       close_patch={~p"/board"}
       title_form={@title_form}
       editing_description={@editing_description}
       description_form={@description_form}
     />
     ```

  3. Add `handle_params/3` right after `mount/3` (it runs after mount on first render and
     on every patch, so the drawer assigns are always set before render):

     ```elixir
     @impl true
     def handle_params(params, _uri, socket) do
       {:noreply, assign_selected_card(socket, params["card"])}
     end
     ```

  4. Add the click→patch event as a new clause AFTER the existing `"create_card"` clause
     (all `handle_event` clauses must stay adjacent):

     ```elixir
     def handle_event("select_card", %{"ref" => ref}, socket) do
       {:noreply, push_patch(socket, to: ~p"/board?card=#{ref}")}
     end
     ```

  5. Replace the existing private `find_stage/2` with a shared-id version and add
     `assign_selected_card/2` next to the other private helpers:

     ```elixir
     # Only stages of the user's own board are addressable from events.
     defp find_stage(socket, stage_id) do
       find_stage_by_id(socket, String.to_integer(stage_id))
     end

     defp find_stage_by_id(socket, stage_id) do
       Enum.find(socket.assigns.board.stages, &(&1.id == stage_id))
     end

     # The drawer is URL-driven: ?card=<ref> selects a card; no param — or a
     # ref that doesn't resolve on this user's board (unknown, malformed, or
     # another board's card) — means no drawer. Authorization is the board
     # scoping inside Cards.get_card_by_ref/2.
     defp assign_selected_card(socket, ref) do
       card = if ref, do: Cards.get_card_by_ref(socket.assigns.board, ref)

       case card do
         %Card{} = card ->
           socket
           |> assign(:selected_card, card)
           |> assign(:selected_stage, find_stage_by_id(socket, card.stage_id))
           |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
           |> assign(:editing_description, false)
           |> assign(:description_form, nil)

         nil ->
           assign(socket,
             selected_card: nil,
             selected_stage: nil,
             title_form: nil,
             editing_description: false,
             description_form: nil
           )
       end
     end
     ```

  6. Append one line to the `@moduledoc`: `MMF 04 adds the URL-driven card detail drawer
     ("?card=<ref>", handled in handle_params/3) rendered via
     RelayWeb.CoreComponents.card_drawer/1.`

- [x] Run the LiveView tests and confirm ALL pass — the new drawer tests AND the existing
  board/card tests (the new `phx-click` on `board_card` must not break them):

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [x] Add the Storybook story. Create `storybook/core_components/card_drawer.story.exs`:

  ```elixir
  defmodule Storybook.Components.CoreComponents.CardDrawer do
    @moduledoc false
    use PhoenixStorybook.Story, :component

    def function, do: &RelayWeb.CoreComponents.card_drawer/1
    def render_source, do: :function

    # The drawer overlays its whole viewport (fixed-position daisyUI
    # drawer-side), so each variation renders inside its own iframe.
    def container, do: {:iframe, style: "height: 720px;"}

    def variations do
      [
        %Variation{
          id: :viewing,
          attributes: %{
            id: "story-drawer-1",
            ref: "RLY-7",
            card: story_card(),
            stage_name: "Spec",
            stage_owner: :human,
            close_patch: "/storybook/core_components/card_drawer",
            title_form:
              Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card)
          }
        },
        %Variation{
          id: :editing_description,
          attributes: %{
            id: "story-drawer-2",
            ref: "RLY-8",
            card: %{story_card() | description: nil, tag: nil},
            stage_name: "Code",
            stage_owner: :ai,
            close_patch: "/storybook/core_components/card_drawer",
            title_form: Phoenix.Component.to_form(%{"title" => "Wire the drawer"}, as: :card),
            editing_description: true,
            description_form: Phoenix.Component.to_form(%{"description" => ""}, as: :card)
          }
        }
      ]
    end

    defp story_card do
      %{
        title: "Draft the onboarding spec",
        description: "Cover the Google sign-in flow.\n\nList open questions for review.",
        tag: "spec",
        inserted_at: ~U[2026-07-01 09:00:00Z],
        updated_at: ~U[2026-07-06 15:30:00Z]
      }
    end
  end
  ```

  (If the installed phoenix_storybook rejects `{:iframe, style: ...}`, fall back to
  `def container, do: :iframe`.)

- [x] Smoke-check the story renders: boot the server, open
  `http://localhost:4000/storybook/core_components/card_drawer`, confirm both variations
  render (viewing + editing), then stop the server:

  ```bash
  mise exec -- mix phx.server
  ```

- [x] Run the full gate and fix anything it flags:

  ```bash
  mise exec -- mix precommit
  ```

- [x] Commit:

  ```bash
  git add -A && git commit -m "Open a URL-driven card detail drawer from the board (MMF 04)"
  ```

**Deliverable:** clicking a board card patches to `/board?card=<ref>` and opens the drawer
(stage chip in owner color, ref, title input pre-filled, description empty state, rail with
stage / tags / dates); ✕ and scrim patch back to `/board` and close it; the deep link opens
it directly; unknown, malformed, and foreign refs render no drawer. Storybook story live at
`/storybook/core_components/card_drawer`. `mix precommit` green.
**Commit:** `Open a URL-driven card detail drawer from the board (MMF 04)`

---

### Task 3 — Editable title: persists via `Cards.update_card/2` and reflects on the board card

**Files**

- `lib/relay_web/live/board_live.ex` (edit: `save_card_title` event)
- `test/relay_web/live/board_live_test.exs` (edit: extend `describe "card drawer"`)

**Interfaces**

- Consumes: `Cards.update_card/2` (Task 1); `#card-drawer-title-form` /
  `#card-drawer-title-input` and the `"save_card_title"` event contract with params
  `%{"card" => %{"title" => _}}` (Task 2); `@selected_card` (Task 2); BoardLive's private
  `stream_name/1` + LiveView `stream_insert/3`.
- Produces: `handle_event("save_card_title", %{"card" => card_params}, socket)` — on
  success reassigns `@selected_card` / `@title_form` and re-streams the card into
  `stream_name(card.stage_id)`; on error assigns the error changeset as `@title_form`.

**Steps**

- [x] Write the failing tests. Append inside the `describe "card drawer"` block of
  `test/relay_web/live/board_live_test.exs`:

  ```elixir
  test "saving the title persists and reflects on drawer and board card",
       %{conn: conn, card: card} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> form("#card-drawer-title-form", card: %{title: "Sharper title"}) |> render_submit()

    assert Repo.get!(Card, card.id).title == "Sharper title"
    assert has_element?(view, "#card-drawer-title-input[value='Sharper title']")
    assert has_element?(view, "#stage-col-1-cards .board-card .card-title", "Sharper title")
    refute has_element?(view, "#stage-col-1-cards .board-card .card-title", "Draft the spec")
  end

  test "a blank title is rejected with an error and nothing changes", %{conn: conn, card: card} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> form("#card-drawer-title-form", card: %{title: ""}) |> render_submit()

    assert has_element?(view, "#card-drawer-title-form", "can't be blank")
    assert Repo.get!(Card, card.id).title == "Draft the spec"
    assert has_element?(view, "#stage-col-1-cards .board-card .card-title", "Draft the spec")
  end
  ```

- [x] Run and confirm the two new tests FAIL (no `save_card_title` handler yet, so the
  submit crashes the LiveView):

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [x] Implement the handler. In `lib/relay_web/live/board_live.ex`, add after the
  `"select_card"` clause (all `handle_event` clauses stay adjacent):

  ```elixir
  def handle_event(
        "save_card_title",
        %{"card" => card_params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:title_form, to_form(%{"title" => card.title}, as: :card))
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :title_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_title", _params, socket), do: {:noreply, socket}
  ```

  (The fallback clause ignores a stale submit arriving after the drawer closed. On error,
  `to_form(changeset)` derives `as: :card` from the `%Card{}` source and carries the
  `:update` action from `Repo.update`, so "can't be blank" renders under the same
  `card[title]` input.)

- [x] Run and confirm ALL LiveView tests PASS:

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [x] Run the full gate and fix anything it flags:

  ```bash
  mise exec -- mix precommit
  ```

- [x] Commit:

  ```bash
  git add -A && git commit -m "Edit card titles inline in the drawer"
  ```

**Deliverable:** submitting the drawer's title form persists through
`Cards.update_card/2`, updates the drawer input, and updates the board card in its stage
column in place (stream re-insert, no reload); a blank title shows a validation error and
changes nothing. `mix precommit` green.
**Commit:** `Edit card titles inline in the drawer`

---

### Task 4 — Description: whitespace-preserved view ⇄ textarea edit, save, cancel

**Files**

- `lib/relay_web/live/board_live.ex` (edit: `edit_description`, `cancel_description`,
  `save_card_description` events)
- `test/relay_web/live/board_live_test.exs` (edit: extend `describe "card drawer"`)

**Interfaces**

- Consumes: `Cards.update_card/2` (Task 1); `#card-drawer-description-edit` /
  `#card-drawer-description-view` / `#card-drawer-description-form` /
  `#card-drawer-description-input` / `#card-drawer-description-cancel` and the
  `"edit_description"` / `"cancel_description"` / `"save_card_description"` event
  contracts (Task 2); `@selected_card`, `@editing_description`, `@description_form`
  assigns (Task 2); `stream_name/1` + `stream_insert/3`.
- Produces: the three `handle_event` clauses; after a successful save `@selected_card`
  refreshes (so the rail's Updated date updates) and the card is re-streamed.

**Steps**

- [ ] Write the failing tests. Append inside the `describe "card drawer"` block of
  `test/relay_web/live/board_live_test.exs`:

  ```elixir
  test "clicking the description area opens the textarea editor", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#card-drawer-description-edit", "Add a description")
    refute has_element?(view, "#card-drawer-description-form")

    view |> element("#card-drawer-description-edit") |> render_click()

    assert has_element?(
             view,
             "#card-drawer-description-form textarea#card-drawer-description-input"
           )
  end

  test "saving the description persists and renders it whitespace-preserved",
       %{conn: conn, card: card} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#card-drawer-description-edit") |> render_click()

    view
    |> form("#card-drawer-description-form", card: %{description: "Line one\n\nLine two"})
    |> render_submit()

    refute has_element?(view, "#card-drawer-description-form")
    assert has_element?(view, "#card-drawer-description-view.whitespace-pre-wrap")
    assert view |> element("#card-drawer-description-view") |> render() =~ "Line one\n\nLine two"
    assert Repo.get!(Card, card.id).description == "Line one\n\nLine two"
  end

  test "cancel closes the editor without saving", %{conn: conn, card: card} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#card-drawer-description-edit") |> render_click()
    view |> element("#card-drawer-description-cancel") |> render_click()

    refute has_element?(view, "#card-drawer-description-form")
    assert has_element?(view, "#card-drawer-description-edit", "Add a description")
    assert Repo.get!(Card, card.id).description == nil
  end

  test "a saved description survives a fresh deep-link visit", %{conn: conn, card: card} do
    {:ok, _card} = Cards.update_card(card, %{description: "Persisted\ntext"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    assert has_element?(view, "#card-drawer-description-view")
    assert view |> element("#card-drawer-description-view") |> render() =~ "Persisted\ntext"
  end

  test "editing pre-fills the textarea with the current description", %{conn: conn, card: card} do
    {:ok, _card} = Cards.update_card(card, %{description: "Current text"})

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")
    view |> element("#card-drawer-description-edit") |> render_click()

    assert view |> element("#card-drawer-description-input") |> render() =~ "Current text"
  end
  ```

- [ ] Run and confirm the new tests FAIL (no `edit_description` handler yet):

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [ ] Implement the handlers. In `lib/relay_web/live/board_live.ex`, add after the
  `save_card_title` clauses (all `handle_event` clauses stay adjacent):

  ```elixir
  def handle_event(
        "edit_description",
        _params,
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    {:noreply,
     socket
     |> assign(:editing_description, true)
     |> assign(:description_form, to_form(%{"description" => card.description || ""}, as: :card))}
  end

  def handle_event("edit_description", _params, socket), do: {:noreply, socket}

  def handle_event("cancel_description", _params, socket) do
    {:noreply, assign(socket, editing_description: false, description_form: nil)}
  end

  def handle_event(
        "save_card_description",
        %{"card" => card_params},
        %{assigns: %{selected_card: %Card{} = card}} = socket
      ) do
    case Cards.update_card(card, card_params) do
      {:ok, card} ->
        {:noreply,
         socket
         |> assign(:selected_card, card)
         |> assign(:editing_description, false)
         |> assign(:description_form, nil)
         |> stream_insert(stream_name(card.stage_id), card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :description_form, to_form(changeset))}
    end
  end

  def handle_event("save_card_description", _params, socket), do: {:noreply, socket}
  ```

- [ ] Run and confirm ALL LiveView tests PASS:

  ```bash
  mise exec -- mix test test/relay_web/live/board_live_test.exs
  ```

- [ ] Run the full gate and fix anything it flags:

  ```bash
  mise exec -- mix precommit
  ```

- [ ] Commit:

  ```bash
  git add -A && git commit -m "Edit card descriptions in the drawer"
  ```

**Deliverable:** the description section toggles between a whitespace-preserved plain-text
view (with an "Add a description…" empty state) and a `textarea` editor pre-filled with the
current text; Save persists via `Cards.update_card/2`, closes the editor, updates the view,
and re-streams the board card; Cancel discards; saved text survives a fresh deep-link
visit. `mix precommit` green.
**Commit:** `Edit card descriptions in the drawer`

---

### Task 5 — Whole-feature verification sweep

**Files:** none expected (fixes only if something surfaces).

**Interfaces:** none new — verifies everything above against the spec's acceptance
criteria.

**Steps**

- [ ] Run the entire gate one final time from a clean state and fix anything it flags:

  ```bash
  mise exec -- mix precommit
  ```

- [ ] Confirm each spec acceptance criterion maps to green tests
  (`test/relay_web/live/board_live_test.exs` `describe "card drawer"`, and
  `test/relay/cards_test.exs`):

  1. *Clicking a card opens the drawer for that card; ✕ or scrim closes it* → "clicking a
     board card patches to its ref and opens the drawer", "the close button clears the
     param and closes the drawer", "clicking the scrim clears the param and closes the
     drawer".
  2. *Editing and saving the title/description persists and reflects on the board card* →
     "saving the title persists and reflects on drawer and board card", "saving the
     description persists and renders it whitespace-preserved", plus the
     `update_card/2` context tests.
  3. *The rail shows stage, tags, and created/updated dates* → "the properties rail shows
     stage, tags, and dates".
  4. *Visiting the deep-link URL opens the drawer directly* → "visiting the deep link opens
     the drawer directly"; plus authorization: "a ref for another user's card does not open
     the drawer", "an unknown or malformed ref renders no drawer", and the
     `get_card_by_ref/2` context tests.

- [ ] Boot the app and eyeball the drawer once end-to-end (sign in, open a card, edit the
  title and description, confirm the board card updated, close via scrim, reload the
  `?card=` deep link), then stop the server:

  ```bash
  mise exec -- mix phx.server
  ```

- [ ] If any fix was needed, re-run `mise exec -- mix precommit` and commit as
  `Fix card drawer issues found in verification`; otherwise there is nothing to commit.

**Deliverable:** all four MMF 04 acceptance criteria demonstrably green, full
`mix precommit` pass on branch `mmf-04-card-drawer`. The final report to the user MUST
include the new Storybook page link `/storybook/core_components/card_drawer` (AGENTS.md
requirement for new reusable components).
