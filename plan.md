# Plan: MMF 03 — Create & title cards

Spec: `docs/superpowers/specs/2026-07-07-create-cards-design.md`. Builds directly on MMF 01 (auth) and MMF 02 (board + stages), both already on `main`.

## Goal

Let users add work to the board: each stage column gets a "+ New card" compose control that reveals an inline title input; submitting creates a card in that stage (persisted, appended to the bottom) and clears the input. Cards render inside their stage column in `position` order showing title, optional `#tag`, and a per-board sequential ref (`RLY-1`, `RLY-2`, …). Ref allocation is serialized (board-row lock + `card_seq` counter) so refs are gap-free under concurrency.

## Architecture

- **New context `Relay.Cards`** (`lib/relay/cards.ex`) with `use Boundary, deps: [Relay.Boards, Relay.Repo], exports: [Card]`; `Cards` is added to `Relay`'s `exports` in `lib/relay.ex` so `RelayWeb` may call it.
- **`Relay.Cards.Card`** schema (`cards` table): `board_id` + `stage_id` (required FKs), `title` (required), `position` (order within stage), `tag` (nullable), `ref_number` (per board). Only `title` and `tag` are in `cast`; `board_id`, `stage_id`, `position`, `ref_number` are set programmatically on the struct (per AGENTS.md Ecto rules).
- **`Relay.Boards.Board` gains `card_seq :integer` (default 0)** via a migration that also creates `cards`. `Cards.create_card(stage, attrs)` allocates the next ref inside a `Repo.transaction`: `SELECT … FOR UPDATE` on the board row, bump `card_seq`, compute `position` = (max position in stage) + 1, insert. A failed insert rolls the bump back, so refs stay sequential and gap-free.
- **Ref formatting**: `Relay.Cards.ref(board, card) :: String.t()` → `"KEY-n"` (e.g. `"RLY-3"`). This is the spec's derived `Card.ref/1` refined to two args so callers that already hold the board (BoardLive does) never need `card.board` preloaded.
- **UI**: `RelayWeb.CoreComponents.stage_column/1` is extended with `stage_id`, `board_key`, `cards`, `composing`, `compose_form` attrs (its old `inner_block` slot is removed). It renders a per-stage card container (`phx-update="stream"` when given a LiveView stream), a new presentational `board_card/1` component per card, the dashed empty-state placeholder CSS-hidden via Tailwind `only:block` whenever cards exist (the documented LiveView stream empty-state pattern), and the compose control. `RelayWeb.BoardLive` holds **one LiveView stream per stage** (`:stage_cards_<id>`, per AGENTS.md "streams for collections") plus `composing_stage_id` / `compose_form` assigns, and handles the `"compose"`, `"create_card"`, `"cancel_compose"` events. The per-stage stream-name atoms are built from the user's own board rows (a bounded, trusted set) and annotated with `# sobelow_skip ["DOS.BinToAtom"]` so `mix sobelow --config` (which runs with `skip: true`) stays green.
- **Storybook**: `stage_column` story refreshed and a new `board_card` story added (AGENTS.md requires stories for reusable components; the final report must link `/storybook/core_components/board_card` and `/storybook/core_components/stage_column`).

## Tech

Elixir / Phoenix 1.8 / LiveView 1.1, Ecto + Postgres, Boundary (compiler-enforced), ExMachina factories, ExUnit + `Phoenix.LiveViewTest` + LazyHTML, daisyUI + Tailwind v4, phoenix_storybook. Toolchain via `mise`.

## Global Constraints

- `mix precommit` must pass on every development cycle and before any task is considered done. It runs compile (warnings as errors), `mix format` (with Styler), `mix credo --strict`, `mix sobelow --config`, `mix deps.audit`, and the full test suite (warnings as errors). Never commit with a failing `mix precommit`.
- Boundary rules: the web layer (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may not reach into the web layer. Every new context gets `use Boundary` and is added to `Relay`'s `exports` in `lib/relay.ex`. A boundary violation fails compilation.
- Toolchain runs through `mise` — prefix mix commands with `mise exec --` (bare `mix` also works).
- Warnings-as-errors: both compilation and the test run treat warnings as errors — never introduce a warning.

Run all commands from the repo root `/Users/jeremy/src/relay`. Before Task 1, create the working branch (we are on `main`):

```
git checkout -b mmf-03-create-cards
```

(The spec mentions a shared `mmf-02-04-board` branch; in this repo MMF 02 is already merged to `main`, so branch fresh from `main`.)

---

### Task 1 — Data layer: `cards` table, `Card` schema, `Board.card_seq`, `Cards` boundary, factory

**Files**

- Create `priv/repo/migrations/<timestamp>_add_card_seq_and_create_cards.exs` (generated)
- Edit `lib/relay/boards/board.ex`
- Create `lib/relay/cards.ex`
- Create `lib/relay/cards/card.ex`
- Edit `lib/relay.ex`
- Edit `test/support/factory.ex`
- Create `test/relay/cards/card_test.exs`

**Interfaces**

Consumes (from MMF 01/02, already on `main`):
- `Relay.Boards.Board` — Ecto schema `"boards"`, fields `id`, `name` (default `"My board"`), `slug`, `key` (default `"RLY"`), `owner_id`; `has_many :stages`
- `Relay.Boards.Stage` — Ecto schema `"stages"`, fields `id`, `board_id`, `name`, `position`, `category`, `owner`
- Factories: `insert(:board, opts)`, `insert(:stage, board: board, position: n)` (ExMachina, `Relay.Factory`, imported by `Relay.DataCase`)
- `Relay.DataCase` (`errors_on/1`, `Repo` alias, `import Ecto.Changeset`)

Produces (later tasks rely on these exact names):
- `Relay.Cards` — Boundary: `use Boundary, deps: [Relay.Boards], exports: [Card]` (Task 2 adds `Relay.Repo` to deps when it starts using Repo)
- `Relay.Cards.ref(%Relay.Boards.Board{}, %Relay.Cards.Card{}) :: String.t()` — `"KEY-n"`, e.g. `"RLY-12"`
- `Relay.Cards.Card` — Ecto schema `"cards"`: `title :string`, `position :integer`, `tag :string`, `ref_number :integer`, `belongs_to :board`, `belongs_to :stage`, utc timestamps
- `Relay.Cards.Card.changeset(card :: %Card{}, attrs :: map) :: Ecto.Changeset.t()` — casts only `[:title, :tag]`, requires `:title`, unique constraint on `[:board_id, :ref_number]`
- `Relay.Boards.Board.card_seq :: integer` (default 0, not cast)
- Factory `card_factory/1`: `insert(:card, stage: persisted_stage, title: ..., position: ..., ref_number: ...)` — derives `stage_id`/`board_id` from the (persisted) stage; inserts a stage itself when none is given
- `Relay` exports now include `Cards`

**Steps**

- [x] Create the failing test file `test/relay/cards/card_test.exs` with exactly:

```elixir
defmodule Relay.Cards.CardTest do
  use Relay.DataCase, async: true

  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards
  alias Relay.Cards.Card

  describe "changeset/2" do
    test "requires a title" do
      changeset = Card.changeset(%Card{}, %{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).title
    end

    test "casts title and tag" do
      changeset = Card.changeset(%Card{}, %{title: "Ship it", tag: "infra"})

      assert changeset.valid?
      assert get_field(changeset, :title) == "Ship it"
      assert get_field(changeset, :tag) == "infra"
    end

    test "does not cast programmatically-set fields" do
      changeset = Card.changeset(%Card{}, %{board_id: 99, stage_id: 99, position: 5, ref_number: 7})

      assert get_field(changeset, :board_id) == nil
      assert get_field(changeset, :stage_id) == nil
      assert get_field(changeset, :position) == nil
      assert get_field(changeset, :ref_number) == nil
    end
  end

  describe "persistence" do
    test "insert(:card) persists a card whose stage belongs to the card's board" do
      card = insert(:card)

      assert card.id
      stage = Repo.get!(Stage, card.stage_id)
      assert stage.board_id == card.board_id
    end

    test "boards start with card_seq 0" do
      board = insert(:board)

      assert Repo.get!(Board, board.id).card_seq == 0
    end
  end

  describe "Cards.ref/2" do
    test "formats the human-facing ref from the board key and ref_number" do
      assert Cards.ref(%Board{key: "RLY"}, %Card{ref_number: 12}) == "RLY-12"
    end
  end
end
```

- [x] Run it and confirm it fails (compile error: `Relay.Cards.Card` undefined): `mise exec -- mix test test/relay/cards/card_test.exs`
- [x] Generate the migration: `mise exec -- mix ecto.gen.migration add_card_seq_and_create_cards`, then replace the generated module body so the file (keep its generated timestamp/filename) reads:

```elixir
defmodule Relay.Repo.Migrations.AddCardSeqAndCreateCards do
  use Ecto.Migration

  def change do
    alter table(:boards) do
      add :card_seq, :integer, null: false, default: 0
    end

    create table(:cards) do
      add :board_id, references(:boards, on_delete: :delete_all), null: false
      add :stage_id, references(:stages, on_delete: :delete_all), null: false
      add :title, :string, null: false
      add :position, :integer, null: false
      add :tag, :string
      add :ref_number, :integer, null: false

      timestamps(type: :utc_datetime)
    end

    create unique_index(:cards, [:board_id, :ref_number])
    create index(:cards, [:stage_id, :position])
  end
end
```

- [x] Migrate the dev database: `mise exec -- mix ecto.migrate` (the `mix test` alias migrates the test DB automatically)
- [x] In `lib/relay/boards/board.ex`, add the counter field (do NOT add it to `cast` — it is set programmatically). Insert directly below the `:key` field:

```elixir
    field :key, :string, default: "RLY"
    field :card_seq, :integer, default: 0
```

  and append this sentence to the existing `@moduledoc`: `` `card_seq` is the per-board card-ref counter (MMF 03), bumped under a row lock by `Relay.Cards.create_card/2` and never cast from input. ``
- [x] Create `lib/relay/cards/card.ex`:

```elixir
defmodule Relay.Cards.Card do
  @moduledoc """
  A card on a board: a titled unit of work living in one stage. `position`
  orders cards within their stage; `ref_number` is the per-board sequence
  behind the human-facing ref (board key + number, e.g. RLY-12 — see
  `Relay.Cards.ref/2`). `board_id`, `stage_id`, `position`, and
  `ref_number` are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "cards" do
    field :title, :string
    field :position, :integer
    field :tag, :string
    field :ref_number, :integer

    belongs_to :board, Relay.Boards.Board
    belongs_to :stage, Relay.Boards.Stage

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user-supplied card attributes (`:title`, `:tag`).
  `board_id`, `stage_id`, `position`, and `ref_number` must already be
  set on the struct.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :tag])
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end
end
```

- [x] Create `lib/relay/cards.ex` (context skeleton with the boundary and `ref/2`; `create_card/2` and `list_cards/1` arrive in Task 2):

```elixir
defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board and per-board ref allocation
  (RLY-1, RLY-2, ...).
  """

  use Boundary, deps: [Relay.Boards], exports: [Card]

  alias Relay.Boards.Board
  alias Relay.Cards.Card

  @doc """
  The human-facing card ref: the board's key plus the card's per-board
  ref number, e.g. `"RLY-12"`.

  Takes the board explicitly (a refinement of the spec's sketched
  `Card.ref/1`) so callers that already hold the board don't need
  `card.board` preloaded.
  """
  def ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"
end
```

- [x] In `lib/relay.ex`, add `Cards` to the exports (only change on that line):

```elixir
  use Boundary, deps: [], exports: [Repo, Mailer, Accounts, Accounts.Scope, Boards, Cards]
```

- [x] In `test/support/factory.ex`, add the card factory after `stage_factory/0`:

```elixir
  # Full-control factory: `stage` (when overridden) must be a *persisted*
  # stage — the card's `stage_id`/`board_id` are derived from it so card and
  # stage always share a board. When no stage is given one is inserted, so
  # even `build(:card)` touches the database.
  def card_factory(attrs) do
    {stage, attrs} = Map.pop_lazy(attrs, :stage, fn -> insert(:stage) end)

    card = %Relay.Cards.Card{
      title: sequence(:card_title, &"Card #{&1}"),
      tag: nil,
      position: sequence(:card_position, &(&1 + 1)),
      ref_number: sequence(:card_ref_number, &(&1 + 1)),
      stage_id: stage.id,
      board_id: stage.board_id
    }

    card |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end
```

- [x] Run the test again and confirm it passes: `mise exec -- mix test test/relay/cards/card_test.exs`
- [x] Run the full gate: `mise exec -- mix precommit` — fix anything it flags (Styler may reorder aliases). Note: the `Relay.Boards` boundary dep IS used (the schema's `belongs_to` targets), so any boundary warning points elsewhere — read it before changing deps
- [x] Commit

**Deliverable:** `mise exec -- mix test test/relay/cards/card_test.exs` and `mise exec -- mix precommit` pass; `cards` table + `boards.card_seq` exist; `Relay.Cards.ref/2` formats refs; `insert(:card)` works and keeps card/stage on the same board.

**Commit message:** `Add Cards data layer: cards table, Card schema, Board.card_seq`

---

### Task 2 — `Cards.create_card/2` (serialized ref allocation) and `Cards.list_cards/1`

**Files**

- Edit `lib/relay/cards.ex`
- Create `test/relay/cards_test.exs`

**Interfaces**

Consumes (Task 1): `Relay.Cards.Card`, `Relay.Cards.Card.changeset/2`, `Relay.Cards.ref/2`, `Board.card_seq`, factories `insert(:board, key: "RLY")` / `insert(:stage, board: board, position: n)` / `insert(:card, stage: stage, ...)`.

Produces:
- `Relay.Cards.create_card(stage :: %Relay.Boards.Stage{}, attrs :: map) :: {:ok, %Relay.Cards.Card{}} | {:error, Ecto.Changeset.t()}` — attrs accepts atom or string keys (`%{title: ...}` or `%{"title" => ...}`); allocates the next per-board `ref_number` under a `FOR UPDATE` board-row lock inside a transaction; appends at `position` = max(stage positions) + 1; rolls the `card_seq` bump back on invalid attrs (gap-free). This is the documented signature choice: the stage alone identifies the board via `stage.board_id`, so no separate `board` argument is needed
- `Relay.Cards.list_cards(board :: %Relay.Boards.Board{}) :: [%Relay.Cards.Card{}]` — all the board's cards ordered by `stage_id`, then `position`, then `id` (the render order per stage column; BoardLive groups by `stage_id`)
- `Relay.Cards` boundary deps become `[Relay.Boards, Relay.Repo]`

**Steps**

- [x] Create the failing test file `test/relay/cards_test.exs` with exactly:

```elixir
defmodule Relay.CardsTest do
  use Relay.DataCase, async: true

  alias Relay.Boards.Board
  alias Relay.Cards
  alias Relay.Cards.Card

  setup do
    board = insert(:board, key: "RLY")
    stage = insert(:stage, board: board, position: 1)
    %{board: board, stage: stage}
  end

  describe "create_card/2" do
    test "creates a card in the stage with the given title", %{board: board, stage: stage} do
      assert {:ok, %Card{} = card} = Cards.create_card(stage, %{title: "Ship MMF 03"})

      assert card.title == "Ship MMF 03"
      assert card.stage_id == stage.id
      assert card.board_id == board.id
      assert card.tag == nil
      assert card.ref_number == 1
      assert card.position == 1
    end

    test "assigns sequential per-board refs and persists the bumped card_seq",
         %{board: board, stage: stage} do
      {:ok, card1} = Cards.create_card(stage, %{title: "First"})
      {:ok, card2} = Cards.create_card(stage, %{title: "Second"})
      {:ok, card3} = Cards.create_card(stage, %{title: "Third"})

      assert Enum.map([card1, card2, card3], & &1.ref_number) == [1, 2, 3]
      assert Cards.ref(board, card3) == "RLY-3"
      assert Repo.get!(Board, board.id).card_seq == 3
    end

    test "ref sequences are independent across boards", %{stage: stage} do
      other_board = insert(:board, key: "OPS")
      other_stage = insert(:stage, board: other_board, position: 1)

      {:ok, _a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})
      {:ok, b1} = Cards.create_card(other_stage, %{title: "B1"})

      assert a2.ref_number == 2
      assert b1.ref_number == 1
      assert Cards.ref(other_board, b1) == "OPS-1"
    end

    test "appends each new card at the bottom of its stage", %{board: board, stage: stage} do
      other_stage = insert(:stage, board: board, position: 2)

      {:ok, c1} = Cards.create_card(stage, %{title: "A"})
      {:ok, c2} = Cards.create_card(stage, %{title: "B"})
      {:ok, c3} = Cards.create_card(other_stage, %{title: "C"})

      assert c1.position == 1
      assert c2.position == 2
      assert c3.position == 1
      assert c3.ref_number == 3
    end

    test "returns an error changeset and leaves no ref gap on a blank title",
         %{board: board, stage: stage} do
      assert {:error, changeset} = Cards.create_card(stage, %{title: ""})

      assert "can't be blank" in errors_on(changeset).title
      assert Repo.aggregate(Card, :count) == 0
      assert Repo.get!(Board, board.id).card_seq == 0

      {:ok, card} = Cards.create_card(stage, %{title: "After the failure"})
      assert card.ref_number == 1
    end

    # Under the SQL sandbox all tasks funnel through the test's connection,
    # so this exercises interleaved allocation; the FOR UPDATE board-row
    # lock additionally serializes truly concurrent connections in prod.
    test "near-simultaneous creates get distinct, gap-free refs", %{stage: stage} do
      refs =
        1..8
        |> Task.async_stream(
          fn i ->
            {:ok, card} = Cards.create_card(stage, %{title: "Card #{i}"})
            card.ref_number
          end,
          max_concurrency: 8,
          timeout: :infinity
        )
        |> Enum.map(fn {:ok, ref_number} -> ref_number end)

      assert Enum.sort(refs) == Enum.to_list(1..8)
    end
  end

  describe "list_cards/1" do
    test "returns the board's cards ordered by stage then position", %{board: board, stage: stage} do
      stage2 = insert(:stage, board: board, position: 2)

      {:ok, a1} = Cards.create_card(stage, %{title: "A1"})
      {:ok, b1} = Cards.create_card(stage2, %{title: "B1"})
      {:ok, a2} = Cards.create_card(stage, %{title: "A2"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [a1.id, a2.id, b1.id]
    end

    test "orders within a stage by position, not insertion order", %{board: board, stage: stage} do
      second = insert(:card, stage: stage, title: "Second", position: 2, ref_number: 2)
      first = insert(:card, stage: stage, title: "First", position: 1, ref_number: 1)

      assert Enum.map(Cards.list_cards(board), & &1.id) == [first.id, second.id]
    end

    test "does not include another board's cards", %{board: board, stage: stage} do
      other_stage = insert(:stage)
      {:ok, _theirs} = Cards.create_card(other_stage, %{title: "Elsewhere"})
      {:ok, mine} = Cards.create_card(stage, %{title: "Mine"})

      assert Enum.map(Cards.list_cards(board), & &1.id) == [mine.id]
    end
  end
end
```

- [x] Run it and confirm it fails (undefined `Cards.create_card/2`): `mise exec -- mix test test/relay/cards_test.exs`
- [x] Replace `lib/relay/cards.ex` with the full context:

```elixir
defmodule Relay.Cards do
  @moduledoc """
  The Cards context: cards on a board, per-board ref allocation
  (RLY-1, RLY-2, ...), and per-stage ordering.
  """

  use Boundary, deps: [Relay.Boards, Relay.Repo], exports: [Card]

  import Ecto.Query

  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards.Card
  alias Relay.Repo

  @doc """
  Creates a card in `stage` from user-supplied `attrs` (`:title`, optional
  `:tag`), returning `{:ok, card}` or `{:error, changeset}`.

  The next per-board `ref_number` is allocated by locking the board row
  (`SELECT ... FOR UPDATE`) and bumping `Board.card_seq` inside the
  transaction, so refs are sequential and gap-free even under concurrent
  creates. The card is appended to the bottom of the stage.
  """
  def create_card(%Stage{} = stage, attrs) do
    Repo.transaction(fn ->
      ref_number = allocate_ref_number(stage.board_id)

      case insert_card(stage, ref_number, attrs) do
        {:ok, card} -> card
        {:error, changeset} -> Repo.rollback(changeset)
      end
    end)
  end

  @doc """
  Returns all of `board`'s cards, ordered by stage then `position` — the
  render order within each stage column.
  """
  def list_cards(%Board{id: board_id}) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board_id,
        order_by: [asc: c.stage_id, asc: c.position, asc: c.id]
    )
  end

  @doc """
  The human-facing card ref: the board's key plus the card's per-board
  ref number, e.g. `"RLY-12"`.

  Takes the board explicitly (a refinement of the spec's sketched
  `Card.ref/1`) so callers that already hold the board don't need
  `card.board` preloaded.
  """
  def ref(%Board{key: key}, %Card{ref_number: ref_number}), do: "#{key}-#{ref_number}"

  # Locks the board row so concurrent creates serialize, then bumps
  # `card_seq` and returns the newly allocated ref number. A rollback of
  # the surrounding transaction also reverts the bump, keeping refs
  # gap-free.
  defp allocate_ref_number(board_id) do
    board = Repo.one!(from b in Board, where: b.id == ^board_id, lock: "FOR UPDATE")
    ref_number = board.card_seq + 1

    {1, _} =
      Repo.update_all(from(b in Board, where: b.id == ^board_id), set: [card_seq: ref_number])

    ref_number
  end

  defp insert_card(%Stage{} = stage, ref_number, attrs) do
    %Card{
      board_id: stage.board_id,
      stage_id: stage.id,
      position: next_position(stage),
      ref_number: ref_number
    }
    |> Card.changeset(attrs)
    |> Repo.insert()
  end

  # New cards append to the bottom of the stage. Safe under concurrency
  # because the caller already holds the board-row lock.
  defp next_position(%Stage{id: stage_id}) do
    (Repo.one(from c in Card, where: c.stage_id == ^stage_id, select: max(c.position)) || 0) + 1
  end
end
```

- [x] Run the test again and confirm all pass: `mise exec -- mix test test/relay/cards_test.exs`
- [x] Run `mise exec -- mix precommit` and fix anything it flags
- [x] Commit

**Deliverable:** `mise exec -- mix test test/relay/cards_test.exs` green — sequential refs, cross-board independence, bottom-of-stage positions, gap-free rollback, concurrency, ordered/scoped listing; `mise exec -- mix precommit` green.

**Commit message:** `Add Cards.create_card/2 with serialized per-board ref allocation`

---

### Task 3 — UI components: `board_card/1` + extended `stage_column/1` (+ Storybook)

**Files**

- Edit `lib/relay_web/components/core_components.ex`
- Edit `test/relay_web/components/core_components_test.exs`
- Create `storybook/core_components/board_card.story.exs`
- Edit `storybook/core_components/stage_column.story.exs`
- Edit `storybook/core_components/_core_components.index.exs`

**Interfaces**

Consumes: existing `RelayWeb.CoreComponents.owner_pill/1`, `stage_column/1` (being replaced), `button/1`, `input/1`, `icon/1`. No domain modules — the components stay purely presentational (the ref string is built from `board_key` + `card.ref_number`, mirroring `Relay.Cards.ref/2`).

Produces:
- `RelayWeb.CoreComponents.board_card/1` — attrs: `id :string` (required), `ref :string` (required), `title :string` (required), `tag :string` (default nil). Renders `article.board-card` containing `.card-title` (title), `.card-tag` (`#tag`, only when tag present), `.card-ref` (the ref text)
- `RelayWeb.CoreComponents.stage_column/1` — attrs: `id :string` (required), `name :string` (required), `owner :atom` in `[:human, :ai]` (required), `stage_id :any` (default nil), `board_key :string` (default `"RLY"`), `cards :any` (default `[]`; a LiveView stream or list of `{dom_id, card}` tuples whose cards expose `title`, `tag`, `ref_number`), `composing :boolean` (default false), `compose_form :any` (default nil; a `Phoenix.HTML.Form` for `card[title]`, required when `composing`). The `inner_block` slot is REMOVED. DOM contract Task 4 relies on: card container `#<id>-cards` (`phx-update="stream"` when `cards` is a stream), `.stage-empty` placeholder always in the DOM but CSS-hidden unless it is the only child (`hidden only:block`), compose button `#<id>-new-card` (`phx-click="compose"` + `phx-value-stage-id`), composer wrapper `#<id>-composer` (`phx-click-away="cancel_compose"`), form `#<id>-compose-form` (`phx-submit="create_card"`, hidden input `stage_id`, text input `card[title]` with Escape → `cancel_compose`), Cancel button (`phx-click="cancel_compose"`)

**Steps**

- [x] In `test/relay_web/components/core_components_test.exs`, add a `board_card/1` describe block and REPLACE the entire existing `describe "stage_column/1"` block (its "renders slot content instead of the empty state" test is obsolete — the slot is gone and the empty state is now always in the DOM, CSS-hidden). New content:

```elixir
  describe "board_card/1" do
    test "renders the title and ref" do
      html = render_component(&CoreComponents.board_card/1, id: "card-1", ref: "RLY-3", title: "Ship MMF 03")

      assert html =~ ~s(id="card-1")
      assert html =~ "Ship MMF 03"
      assert html =~ "RLY-3"
      refute html =~ "card-tag"
    end

    test "renders the #tag when present" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "card-2",
          ref: "RLY-4",
          title: "Tagged",
          tag: "infra"
        )

      assert html =~ "card-tag"
      assert html =~ "#infra"
    end
  end

  describe "stage_column/1" do
    test "renders the name, owner pill, empty state, and compose button when empty" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          owner: :human,
          stage_id: 7
        )

      assert html =~ ~s(id="stage-col-1")
      assert html =~ "Backlog"
      assert html =~ "badge-primary"
      assert html =~ "stage-empty"
      assert html =~ "No cards yet"
      assert html =~ ~s(id="stage-col-1-new-card")
      assert html =~ ~s(phx-value-stage-id="7")
      refute html =~ ~s(id="stage-col-1-compose-form")
    end

    test "renders its cards with refs derived from the board key" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-4",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          board_key: "RLY",
          cards: [
            {"cards-1", %{title: "First card", tag: "infra", ref_number: 1}},
            {"cards-2", %{title: "Second card", tag: nil, ref_number: 2}}
          ]
        )

      assert html =~ ~s(id="stage-col-4-cards")
      assert html =~ ~s(id="cards-1")
      assert html =~ "First card"
      assert html =~ "RLY-1"
      assert html =~ "#infra"
      assert html =~ ~s(id="cards-2")
      assert html =~ "RLY-2"
    end

    test "shows the composer form instead of the compose button when composing" do
      html =
        render_component(&CoreComponents.stage_column/1,
          id: "stage-col-1",
          name: "Backlog",
          owner: :human,
          stage_id: 7,
          composing: true,
          compose_form: to_form(%{"title" => ""}, as: :card)
        )

      assert html =~ ~s(id="stage-col-1-compose-form")
      assert html =~ ~s(name="card[title]")
      assert html =~ ~s(name="stage_id")
      assert html =~ "Cancel"
      refute html =~ ~s(id="stage-col-1-new-card")
    end
  end
```

  (`to_form/2` comes from the file's existing `import Phoenix.Component`.)
- [x] Run and confirm failures (`board_card/1` undefined; old `stage_column/1` lacks the new attrs): `mise exec -- mix test test/relay_web/components/core_components_test.exs`
- [x] In `lib/relay_web/components/core_components.ex`, add `board_card/1` immediately after `owner_pill/1`:

```elixir
  @doc """
  Renders a single kanban card: its title, optional #tag, and its
  board-scoped ref (e.g. RLY-3).

  ## Examples

      <.board_card id="cards-1" ref="RLY-3" title="Ship MMF 03" tag="infra" />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"
  attr :title, :string, required: true
  attr :tag, :string, default: nil

  def board_card(assigns) do
    ~H"""
    <article id={@id} class="board-card card bg-base-100 shadow-sm">
      <div class="card-body gap-2 p-3">
        <p class="card-title text-sm font-medium leading-snug">{@title}</p>
        <div class="flex items-center justify-between gap-2">
          <span :if={@tag} class="card-tag badge badge-ghost badge-sm">#{@tag}</span>
          <span class="card-ref ml-auto font-mono text-xs text-base-content/60">{@ref}</span>
        </div>
      </div>
    </article>
    """
  end
```

  (In the tag span, `#` is literal text and `{@tag}` is HEEx interpolation — together they render e.g. `#infra`.)
- [x] In the same file, REPLACE the whole existing `stage_column/1` (its `@doc`, attrs, slot, and function) with:

```elixir
  @doc """
  Renders one stage column of the board: header (stage name + Human/AI
  owner pill), the stage's cards in the order given, and the "+ New card"
  compose control.

  `cards` accepts a LiveView stream (preferred) or a list of
  `{dom_id, card}` tuples; each card needs `title`, `tag`, and
  `ref_number` fields. The dashed empty-state placeholder lives inside
  the card container and is CSS-hidden (`only:block`) as soon as the
  stage has cards.

  The compose control emits events handled by the parent LiveView:
  `"compose"` (with `phx-value-stage-id`) to open the composer,
  `"create_card"` (form params `card[title]` plus hidden `stage_id`) on
  submit, and `"cancel_compose"` on Cancel, Escape, or click-away.

  ## Examples

      <.stage_column id="stage-col-1" name="Backlog" owner={:human} stage_id={1} />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :owner, :atom, values: [:human, :ai], required: true
  attr :stage_id, :any, default: nil, doc: "the stage's database id, echoed back in compose events"
  attr :board_key, :string, default: "RLY", doc: "the board's ref prefix, e.g. RLY in RLY-3"
  attr :cards, :any, default: [], doc: "a LiveView stream or a list of {dom_id, card} tuples"
  attr :composing, :boolean, default: false
  attr :compose_form, :any, default: nil, doc: "a Phoenix.HTML.Form for card[title]; required when composing"

  def stage_column(assigns) do
    ~H"""
    <section
      id={@id}
      class="stage-column flex w-60 shrink-0 flex-col gap-3 rounded-box bg-base-200 p-3"
    >
      <header class="flex items-center justify-between gap-2">
        <h3 class="text-sm font-semibold">{@name}</h3>
        <.owner_pill owner={@owner} />
      </header>
      <div
        id={"#{@id}-cards"}
        phx-update={is_struct(@cards, Phoenix.LiveView.LiveStream) && "stream"}
        class="flex flex-col gap-2"
      >
        <div class="stage-empty hidden only:block rounded-lg border border-dashed border-base-content/20 px-3 py-6 text-center text-xs text-base-content/50">
          No cards yet
        </div>
        <.board_card
          :for={{dom_id, card} <- @cards}
          id={dom_id}
          title={card.title}
          tag={card.tag}
          ref={"#{@board_key}-#{card.ref_number}"}
        />
      </div>
      <div :if={@composing} id={"#{@id}-composer"} phx-click-away="cancel_compose">
        <.form for={@compose_form} id={"#{@id}-compose-form"} phx-submit="create_card">
          <input type="hidden" name="stage_id" value={@stage_id} />
          <.input
            field={@compose_form[:title]}
            type="text"
            placeholder="Card title"
            autofocus
            autocomplete="off"
            phx-keydown="cancel_compose"
            phx-key="escape"
          />
          <div class="flex items-center gap-2">
            <.button variant="primary" class="btn btn-primary btn-sm">Add card</.button>
            <button type="button" class="btn btn-ghost btn-sm" phx-click="cancel_compose">
              Cancel
            </button>
          </div>
        </.form>
      </div>
      <button
        :if={!@composing}
        type="button"
        id={"#{@id}-new-card"}
        class="stage-compose btn btn-ghost btn-sm justify-start text-base-content/60"
        phx-click="compose"
        phx-value-stage-id={@stage_id}
      >
        <.icon name="hero-plus" class="size-4" /> New card
      </button>
    </section>
    """
  end
```

  Notes: the `<.button>` in the form intentionally has no `type` attr — inside a form, buttons default to `type="submit"` (and `type` is not in `button/1`'s `rest` include list). The empty state uses the LiveView-documented `hidden only:block` stream empty-state pattern (works because it is the only non-stream child of the container). `phx-update` is set only when `cards` is a real `Phoenix.LiveView.LiveStream` (same trick as the existing `table/1`), so plain lists (Storybook, tests) render statically. `phx-click-away` (not `phx-blur`) implements "blur closes it" without eating the submit click.
- [x] Run and confirm the component tests pass, and that the MMF 02 LiveView tests still pass (all new `stage_column` attrs have defaults; `.stage-empty` still renders on every empty column): `mise exec -- mix test test/relay_web/components/core_components_test.exs test/relay_web/live/board_live_test.exs`
- [x] Create `storybook/core_components/board_card.story.exs`:

```elixir
defmodule Storybook.Components.CoreComponents.BoardCard do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.board_card/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :title_and_ref,
        attributes: %{id: "story-card-1", ref: "RLY-1", title: "Wire up Google sign-in"}
      },
      %Variation{
        id: :with_tag,
        attributes: %{
          id: "story-card-2",
          ref: "RLY-2",
          title: "Design the card composer",
          tag: "design"
        }
      }
    ]
  end
end
```

- [x] Replace `storybook/core_components/stage_column.story.exs` (the `:with_content` slot variation is obsolete) with:

```elixir
defmodule Storybook.Components.CoreComponents.StageColumn do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.stage_column/1
  def render_source, do: :function

  def variations do
    [
      %Variation{
        id: :empty_human,
        attributes: %{id: "story-stage-backlog", name: "Backlog", owner: :human, stage_id: 1}
      },
      %Variation{
        id: :with_cards,
        attributes: %{
          id: "story-stage-code",
          name: "Code",
          owner: :ai,
          stage_id: 4,
          board_key: "RLY",
          cards: [
            {"story-card-1", %{title: "Wire up Google sign-in", tag: "auth", ref_number: 1}},
            {"story-card-2", %{title: "Render the stage columns", tag: nil, ref_number: 2}}
          ]
        }
      },
      %Variation{
        id: :composing,
        attributes: %{
          id: "story-stage-plan",
          name: "Plan",
          owner: :ai,
          stage_id: 3,
          composing: true,
          compose_form: Phoenix.Component.to_form(%{"title" => ""}, as: :card)
        }
      }
    ]
  end
end
```

- [x] In `storybook/core_components/_core_components.index.exs`, add an entry (keep the list alphabetical, i.e. after `"back"`):

```elixir
  def entry("board_card"), do: [icon: {:fa, "note-sticky", :thin}]
```

- [x] Run `mise exec -- mix precommit` and fix anything it flags
- [x] Commit

**Deliverable:** Component tests green; Storybook has stories at `/storybook/core_components/board_card` (new) and `/storybook/core_components/stage_column` (empty / with-cards / composing states); the board page behavior is unchanged; `mise exec -- mix precommit` green.

**Commit message:** `Add board_card component; extend stage_column with cards and composer`

---

### Task 4 — Wire cards into `BoardLive`: per-stage streams + compose events

**Files**

- Edit `lib/relay_web/live/board_live.ex`
- Edit `test/relay_web/live/board_live_test.exs`

**Interfaces**

Consumes:
- `Relay.Boards.get_or_create_default_board(%Relay.Accounts.User{}) :: %Board{stages: [%Stage{}]}` (stages preloaded in position order — MMF 02)
- `Relay.Cards.create_card(%Stage{}, map) :: {:ok, %Card{}} | {:error, Ecto.Changeset.t()}` and `Relay.Cards.list_cards(%Board{}) :: [%Card{}]` (Task 2)
- `RelayWeb.CoreComponents.stage_column/1` attrs + DOM contract (Task 3): `#stage-col-<pos>-new-card`, `#stage-col-<pos>-compose-form` (params `card[title]` + `stage_id`), `#stage-col-<pos>-composer` Cancel button, `#stage-col-<pos>-cards` container, `.board-card` / `.card-title` / `.card-ref` / `.stage-empty`
- `register_and_log_in_user/1` (ConnCase) providing `%{conn: conn, user: user}`; factories

Produces:
- `RelayWeb.BoardLive` assigns: `:board`, `:stage_groups`, `:composing_stage_id` (`nil | integer`), `:compose_form` (form for `card[title]`); one LiveView stream per stage named `:"stage_cards_<stage_id>"`
- `handle_event/3` clauses: `"compose"` (`%{"stage-id" => id}`), `"cancel_compose"` (any params), `"create_card"` (`%{"stage_id" => id, "card" => %{"title" => _}}`)

**Steps**

- [x] In `test/relay_web/live/board_live_test.exs`, extend the alias block to (alphabetical; Styler enforces this order):

```elixir
  alias Relay.Boards
  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards.Card
  alias Relay.Repo
```

  and add this new describe block after the `describe "when logged in"` block:

```elixir
  describe "cards" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "a stage's compose CTA reveals the composer for that stage only", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-col-1-compose-form")

      view |> element("#stage-col-1-new-card") |> render_click()

      assert has_element?(view, "#stage-col-1-compose-form")
      refute has_element?(view, "#stage-col-2-compose-form")
    end

    test "submitting the composer creates a card in that stage and clears the input",
         %{conn: conn, backlog: backlog} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()

      view
      |> form("#stage-col-1-compose-form", card: %{title: "Ship MMF 03"})
      |> render_submit()

      assert has_element?(view, "#stage-col-1-cards .board-card", "Ship MMF 03")

      assert [card] = Repo.all(Card)
      assert card.stage_id == backlog.id
      assert card.title == "Ship MMF 03"
      assert card.ref_number == 1

      assert has_element?(view, "#stage-col-1-compose-form")

      input_html =
        view
        |> element("#stage-col-1-compose-form input[name='card[title]']")
        |> render()

      refute input_html =~ "Ship MMF 03"
    end

    test "creating cards assigns per-board incrementing refs shown on the cards", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: "First"}) |> render_submit()
      view |> form("#stage-col-1-compose-form", card: %{title: "Second"}) |> render_submit()

      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-1")
      assert has_element?(view, "#stage-col-1-cards .board-card .card-ref", "RLY-2")
    end

    test "cards persist and re-render in position order on reload", %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Second", position: 2, ref_number: 2)
      insert(:card, stage: backlog, title: "First", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      titles =
        view
        |> render()
        |> LazyHTML.from_fragment()
        |> LazyHTML.query("#stage-col-1-cards .board-card .card-title")
        |> Enum.map(&(&1 |> LazyHTML.text() |> String.trim()))

      assert titles == ["First", "Second"]
    end

    test "cards render in their own stage; other stages keep the empty state",
         %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Only here", position: 1, ref_number: 1)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(view, "#stage-col-1-cards .board-card", "Only here")
      refute has_element?(view, "#stage-col-2-cards .board-card")
      assert has_element?(view, "#stage-col-2-cards .stage-empty")
    end

    test "cancel closes the composer without creating a card", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> element("#stage-col-1-composer button", "Cancel") |> render_click()

      refute has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end

    test "submitting a blank title keeps the composer open and creates nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()
      view |> form("#stage-col-1-compose-form", card: %{title: ""}) |> render_submit()

      assert has_element?(view, "#stage-col-1-compose-form")
      assert Repo.all(Card) == []
    end
  end
```

  Leave every pre-existing test in the file untouched (they must all keep passing — including "every stage shows the empty-state placeholder", which counts 7 `.stage-empty` nodes that the new markup still renders).
- [x] Run and confirm the new tests fail (no compose wiring yet): `mise exec -- mix test test/relay_web/live/board_live_test.exs`
- [x] Replace `lib/relay_web/live/board_live.ex` with:

```elixir
defmodule RelayWeb.BoardLive do
  @moduledoc """
  The authenticated home (`/board`): the user's board rendered as stage
  columns grouped under category bands (Unstarted → In progress →
  Complete). Cards live in one LiveView stream per stage; each column's
  composer creates cards via `Relay.Cards` (MMF 03).
  """

  use RelayWeb, :live_view

  alias Relay.Boards
  alias Relay.Cards

  @category_order [:unstarted, :in_progress, :complete]

  @impl true
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash} current_scope={@current_scope} wide>
      <div id="board" class="space-y-4">
        <h1 id="board-title" class="text-xl font-semibold">{@board.name}</h1>
        <div class="flex items-start gap-6 overflow-x-auto pb-4">
          <section
            :for={{category, stages} <- @stage_groups}
            id={"category-#{category}"}
            class="shrink-0 space-y-2"
          >
            <h2 class="category-band px-1 text-xs font-semibold uppercase tracking-wider text-base-content/60">
              {category_label(category)}
            </h2>
            <div class="flex items-start gap-4">
              <.stage_column
                :for={stage <- stages}
                id={"stage-col-#{stage.position}"}
                name={stage.name}
                owner={stage.owner}
                stage_id={stage.id}
                board_key={@board.key}
                cards={Map.fetch!(@streams, stream_name(stage.id))}
                composing={@composing_stage_id == stage.id}
                compose_form={@compose_form}
              />
            </div>
          </section>
        </div>
      </div>
    </Layouts.app>
    """
  end

  @impl true
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:page_title, board.name)
      |> assign(:board, board)
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:composing_stage_id, nil)
      |> assign(:compose_form, empty_compose_form())

    socket =
      Enum.reduce(board.stages, socket, fn stage, acc ->
        stream(acc, stream_name(stage.id), Map.get(cards_by_stage, stage.id, []))
      end)

    {:ok, socket}
  end

  @impl true
  def handle_event("compose", %{"stage-id" => stage_id}, socket) do
    {:noreply,
     socket
     |> assign(:composing_stage_id, String.to_integer(stage_id))
     |> assign(:compose_form, empty_compose_form())}
  end

  def handle_event("cancel_compose", _params, socket) do
    {:noreply, assign(socket, :composing_stage_id, nil)}
  end

  def handle_event("create_card", %{"stage_id" => stage_id, "card" => card_params}, socket) do
    stage = find_stage(socket, stage_id)

    case stage && Cards.create_card(stage, card_params) do
      nil ->
        {:noreply, socket}

      {:ok, card} ->
        {:noreply,
         socket
         |> stream_insert(stream_name(stage.id), card)
         |> assign(:compose_form, empty_compose_form())}

      {:error, changeset} ->
        {:noreply, assign(socket, :compose_form, to_form(changeset))}
    end
  end

  # Groups position-ordered stages under their category, keeping the fixed
  # category order and dropping empty categories (per spec: headers render
  # only for non-empty categories).
  defp group_stages(stages) do
    groups = Enum.group_by(stages, & &1.category)

    @category_order
    |> Enum.map(&{&1, Map.get(groups, &1, [])})
    |> Enum.reject(fn {_category, category_stages} -> category_stages == [] end)
  end

  # Only stages of the user's own board are addressable from events.
  defp find_stage(socket, stage_id) do
    stage_id = String.to_integer(stage_id)
    Enum.find(socket.assigns.board.stages, &(&1.id == stage_id))
  end

  # Streams are keyed per stage so each column gets its own
  # phx-update="stream" container. Stage ids come from this user's board
  # rows (a small, trusted set), not from user input, so building one atom
  # per stage is safe.
  # sobelow_skip ["DOS.BinToAtom"]
  defp stream_name(stage_id), do: :"stage_cards_#{stage_id}"

  defp empty_compose_form, do: to_form(%{"title" => ""}, as: :card)

  defp category_label(:unstarted), do: "Unstarted"
  defp category_label(:in_progress), do: "In progress"
  defp category_label(:complete), do: "Complete"
end
```

  Notes: `stream_insert/3` appends at the end by default, matching "new cards append to the bottom"; after a successful create the composer stays open with a fresh empty form ("clears the input"); on `{:error, changeset}` the form re-renders with the error and nothing is created; the `stream_name/1` sobelow annotation is required — without it `mix sobelow --config` fails precommit on `DOS.BinToAtom`.
- [x] Run and confirm the whole file passes (new "cards" tests plus every pre-existing MMF 01/02 test): `mise exec -- mix test test/relay_web/live/board_live_test.exs`
- [x] Run the full gate: `mise exec -- mix precommit` — everything must be green
- [x] Commit

**Deliverable:** All four MMF acceptance criteria pass via tests — (1) stage compose CTA creates a card in that stage and clears the input ("submitting the composer creates a card in that stage and clears the input"); (2) cards persist and re-render in position order on reload ("cards persist and re-render in position order on reload"); (3) each card shows title and ref, and an empty stage shows its empty state ("creating cards assigns per-board incrementing refs shown on the cards" + "cards render in their own stage; other stages keep the empty state"); (4) per-board incrementing refs, gap-free under concurrency (same tests plus `Relay.CardsTest`, including the concurrency test). `mise exec -- mix precommit` green on branch `mmf-03-create-cards`.

**Commit message:** `Wire card creation and rendering into BoardLive`

---

## Final report requirements (per AGENTS.md)

When summarizing the completed work, include the Storybook links for the reusable components touched: `/storybook/core_components/board_card` (new) and `/storybook/core_components/stage_column` (refreshed).
