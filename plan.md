# Plan: MMF 02 — Board with stages (seeded pipeline)

**Spec:** `docs/superpowers/specs/2026-07-07-board-and-stages-design.md`
**Depends on:** MMF 01 (merged): auth, `current_scope`, `:require_authenticated` live_session,
`RelayWeb.Auth.log_in_user/2`, `test/support/conn_case.ex` login helpers, ExMachina `:user` factory.

## Goal

After signing in, the user lands on `/board` and sees their board: 7 seeded stage columns
(Backlog → Done) grouped under a category band (Unstarted → In progress → Complete), each column
showing its name, a Human/AI owner pill, and an empty-state placeholder. Read-only — no cards yet
(MMF 03). This replaces MMF 01's `/home` stub as the authenticated home.

## Architecture

- **`Relay.Boards`** (new domain context, own Boundary):
  `use Boundary, deps: [Relay.Accounts, Relay.Repo], exports: [Board, Stage]`. Added to `Relay`'s
  `exports` in `lib/relay.ex`.
- **`Relay.Boards.Board`** (`boards` table): `owner_id` → `Relay.Accounts.User` (required, set
  programmatically), `name` (default `"My board"`), `slug` (unique), `key` (default `"RLY"`),
  timestamps. `has_many :stages`. Do **NOT** add `card_seq` — that comes in a later MMF.
- **`Relay.Boards.Stage`** (`stages` table): `board_id` (required, set programmatically), `name`,
  `position` (integer), `category` (`Ecto.Enum`: `:unstarted | :in_progress | :complete`),
  `owner` (`Ecto.Enum`: `:human | :ai`), timestamps. Unique index on `(board_id, position)`.
- **`Relay.Boards.get_or_create_default_board/1`**: idempotent per user; on first call creates the
  board (slug derived from the user's name/email, de-duplicated) and seeds exactly 7 stages:
  Backlog·human·unstarted(1), Spec·human·unstarted(2), Plan·ai·in_progress(3),
  Code·ai·in_progress(4), Review·human·in_progress(5), Deploy·ai·in_progress(6),
  Done·human·complete(7). Returns the board with `stages` preloaded in `position` order.
- **`RelayWeb.BoardLive`** at `live "/board", BoardLive` inside the existing
  `:require_authenticated` live_session. `mount` calls
  `get_or_create_default_board(socket.assigns.current_scope.user)`.
- **Reusable components** (decision: in `core_components.ex`, NOT inlined — MMF 03/04 reuse them,
  and AGENTS.md requires every reusable component to have a Storybook story):
  `owner_pill/1` (Human = `badge-primary`/blue, AI = `badge-secondary`/violet — the daisyUI theme
  in `assets/css/app.css` already maps primary→Human blue, secondary→AI violet) and
  `stage_column/1` (name + owner pill + empty-state placeholder + `inner_block` slot for future
  cards).
- **`RelayWeb.Layouts.app`** gains an opt-in `wide` boolean attr (default `false`) so the board can
  use the full viewport width; the existing `max-w-2xl` container cannot show 7 columns. All other
  pages are unaffected.
- **Post-login destination → `/board`**: the `/home` redirect lives in ONE place —
  `RelayWeb.Auth.log_in_user/2` (both `AuthController` and `DevLoginController` delegate to it) —
  plus the signed-in redirect in `PageController.home/2`. Change both to `~p"/board"`, delete the
  now-unused `RelayWeb.HomeLive` + its route + its test file, and migrate the top-bar/sign-out
  layout tests from `home_live_test.exs` into `board_live_test.exs`.

## Tech

Phoenix 1.8 / LiveView 1.1, Ecto + Postgres, Boundary (compiler-enforced), daisyUI on Tailwind v4,
ExMachina factories, `Phoenix.LiveViewTest` + `LazyHTML` for LiveView tests, Phoenix Storybook for
component stories. Elixir formatting via `mix format` (Styler + HEEx formatter plugins), Credo
strict (line length 120, `AliasUsage` disabled).

## Global Constraints

- **`mix precommit` must pass** before any task is considered done (it runs
  `compile --warnings-as-errors`, `deps.unlock --unused`, `format`, `credo --strict`,
  `sobelow --config`, `deps.audit`, and `test`). Never commit with a failing `mix precommit`.
- **Boundary rules are compiler-enforced**: the web layer (`RelayWeb`) may only call the domain
  through `Relay`'s exported contexts; contexts may not reach into the web layer. `Relay.Boards`
  MUST have `use Boundary, deps: [Relay.Repo, Relay.Accounts], exports: [Board, Stage]`, and
  `Boards` MUST be added to `Relay`'s `exports` in `lib/relay.ex`. A violation fails compilation.
- **Toolchain runs through `mise`** — prefix every mix invocation with `mise exec --`
  (e.g. `mise exec -- mix test`).
- **Warnings-as-errors** everywhere: `mix test` compiles with `--warnings-as-errors` (see the
  `test` alias) and precommit compiles with `--warnings-as-errors`. Leave no unused
  aliases/variables/functions at any commit point.
- Fields set programmatically (`owner_id`, `board_id`) must NOT appear in `cast` calls — set them
  on the struct (AGENTS.md Ecto rule).
- Run `mise exec -- mix format` before every commit.

---

### Task 1: `Relay.Boards` context skeleton — Board + Stage schemas, migration, factories

**Files**
- Create: `lib/relay/boards.ex` (context module with the Boundary declaration; functions arrive in
  Task 2)
- Create: `lib/relay/boards/board.ex`
- Create: `lib/relay/boards/stage.ex`
- Create: `priv/repo/migrations/<timestamp>_create_boards_and_stages.exs` (generate with
  `mise exec -- mix ecto.gen.migration create_boards_and_stages`)
- Modify: `lib/relay.ex` (add `Boards` to `exports`)
- Modify: `test/support/factory.ex` (add `board_factory/0`, `stage_factory/0`)
- Test: `test/relay/boards/board_test.exs` (new)
- Test: `test/relay/boards/stage_test.exs` (new)

**Interfaces**
- Consumes (MMF 01): `Relay.Accounts.User` schema (`users` table with `id`, `name`, `email`);
  `Relay.Repo`; `Relay.Factory.user_factory/0`; `Relay.DataCase` (imports `Relay.Factory`,
  aliases `Relay.Repo`, provides `errors_on/1`).
- Produces:
  - `Relay.Boards.Board` struct — fields `id`, `owner_id`, `name` (default `"My board"`), `slug`,
    `key` (default `"RLY"`), assoc `owner` (`belongs_to`), assoc `stages` (`has_many`),
    `inserted_at`/`updated_at`.
  - `Relay.Boards.Board.changeset(board :: %Board{}, attrs :: map()) :: Ecto.Changeset.t()` —
    casts `[:name, :slug, :key]`, requires all three, `unique_constraint(:slug)`.
  - `Relay.Boards.Stage` struct — fields `id`, `board_id`, `name`, `position`,
    `category :: :unstarted | :in_progress | :complete`, `owner :: :human | :ai`, assoc `board`.
  - `Relay.Boards.Stage.changeset(stage :: %Stage{}, attrs :: map()) :: Ecto.Changeset.t()` —
    casts `[:name, :position, :category, :owner]`, requires all four,
    `unique_constraint(:position, name: :stages_board_id_position_index)`.
  - Factories: `insert(:board)` (builds an owner), `insert(:stage)` (builds a board);
    overridable per-field, e.g. `insert(:stage, board: board, position: 1)`.

**Steps**

- [x] Write the failing schema tests. Create `test/relay/boards/board_test.exs`:

  ```elixir
  defmodule Relay.Boards.BoardTest do
    use Relay.DataCase, async: true

    alias Relay.Boards.Board

    describe "Board.changeset/2 + persistence" do
      test "inserts a board and applies the name/key defaults" do
        user = insert(:user)

        board =
          %Board{owner_id: user.id}
          |> Board.changeset(%{slug: "my-slug"})
          |> Repo.insert!()

        assert board.name == "My board"
        assert board.key == "RLY"
        assert board.slug == "my-slug"
        assert board.owner_id == user.id
      end

      test "requires a slug" do
        changeset = Board.changeset(%Board{owner_id: 1}, %{})

        refute changeset.valid?
        assert "can't be blank" in errors_on(changeset).slug
      end

      test "enforces unique slugs" do
        insert(:board, slug: "taken")
        user = insert(:user)

        assert {:error, changeset} =
                 %Board{owner_id: user.id}
                 |> Board.changeset(%{slug: "taken"})
                 |> Repo.insert()

        assert "has already been taken" in errors_on(changeset).slug
      end
    end
  end
  ```

  Create `test/relay/boards/stage_test.exs`:

  ```elixir
  defmodule Relay.Boards.StageTest do
    use Relay.DataCase, async: true

    alias Relay.Boards.Stage

    describe "Stage.changeset/2 + persistence" do
      test "inserts a stage with enum category and owner" do
        stage = insert(:stage, name: "Backlog", position: 1, category: :unstarted, owner: :human)

        reloaded = Repo.get!(Stage, stage.id)
        assert reloaded.name == "Backlog"
        assert reloaded.position == 1
        assert reloaded.category == :unstarted
        assert reloaded.owner == :human
      end

      test "requires name, position, category, and owner" do
        changeset = Stage.changeset(%Stage{board_id: 1}, %{})

        refute changeset.valid?
        errors = errors_on(changeset)
        assert "can't be blank" in errors.name
        assert "can't be blank" in errors.position
        assert "can't be blank" in errors.category
        assert "can't be blank" in errors.owner
      end

      test "rejects values outside the category and owner enums" do
        changeset =
          Stage.changeset(%Stage{board_id: 1}, %{name: "X", position: 1, category: "bogus", owner: "robot"})

        errors = errors_on(changeset)
        assert "is invalid" in errors.category
        assert "is invalid" in errors.owner
      end

      test "enforces unique position per board" do
        board = insert(:board)
        insert(:stage, board: board, position: 1)

        assert {:error, changeset} =
                 %Stage{board_id: board.id}
                 |> Stage.changeset(%{name: "Dup", position: 1, category: :unstarted, owner: :human})
                 |> Repo.insert()

        assert "has already been taken" in errors_on(changeset).position
      end

      test "allows the same position on different boards" do
        insert(:stage, position: 1)
        stage = insert(:stage, position: 1)

        assert stage.id
      end
    end
  end
  ```

- [x] Run `mise exec -- mix test test/relay/boards/` — expect compilation failure (modules and
  factories don't exist yet).
- [x] Generate the migration: `mise exec -- mix ecto.gen.migration create_boards_and_stages`, then
  replace the generated file's contents (path will be
  `priv/repo/migrations/<timestamp>_create_boards_and_stages.exs`):

  ```elixir
  defmodule Relay.Repo.Migrations.CreateBoardsAndStages do
    use Ecto.Migration

    def change do
      create table(:boards) do
        add :owner_id, references(:users, on_delete: :delete_all), null: false
        add :name, :string, null: false, default: "My board"
        add :slug, :string, null: false
        add :key, :string, null: false, default: "RLY"

        timestamps(type: :utc_datetime)
      end

      create unique_index(:boards, [:slug])
      create index(:boards, [:owner_id])

      create table(:stages) do
        add :board_id, references(:boards, on_delete: :delete_all), null: false
        add :name, :string, null: false
        add :position, :integer, null: false
        add :category, :string, null: false
        add :owner, :string, null: false

        timestamps(type: :utc_datetime)
      end

      create unique_index(:stages, [:board_id, :position])
    end
  end
  ```

- [x] Create `lib/relay/boards.ex` (Boundary declaration only for now — Task 2 adds the functions):

  ```elixir
  defmodule Relay.Boards do
    @moduledoc """
    The Boards context: boards and their stages (the workflow pipeline).
    Cards arrive in MMF 03 (`Relay.Cards`).
    """

    use Boundary, deps: [Relay.Accounts, Relay.Repo], exports: [Board, Stage]
  end
  ```

- [x] Create `lib/relay/boards/board.ex`:

  ```elixir
  defmodule Relay.Boards.Board do
    @moduledoc """
    A user's kanban board. One board per user for now (MMF 19 adds more).
    `slug` is stored for future slug-routing (MMF 19); `key` is the short
    card-ref prefix (e.g. "RLY-12", used from MMF 03). `owner_id` is set
    programmatically, never cast from input.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "boards" do
      field :name, :string, default: "My board"
      field :slug, :string
      field :key, :string, default: "RLY"

      belongs_to :owner, Relay.Accounts.User
      has_many :stages, Relay.Boards.Stage

      timestamps(type: :utc_datetime)
    end

    @doc "Changeset for board attributes. `owner_id` must already be set on the struct."
    def changeset(board, attrs) do
      board
      |> cast(attrs, [:name, :slug, :key])
      |> validate_required([:name, :slug, :key])
      |> unique_constraint(:slug)
    end
  end
  ```

- [x] Create `lib/relay/boards/stage.ex`:

  ```elixir
  defmodule Relay.Boards.Stage do
    @moduledoc """
    A column on a board. `category` groups stages under the board's category
    band (unstarted → in_progress → complete); `owner` says whose turn work
    in this stage is — human (blue) or ai (violet). `board_id` is set
    programmatically, never cast from input.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "stages" do
      field :name, :string
      field :position, :integer
      field :category, Ecto.Enum, values: [:unstarted, :in_progress, :complete]
      field :owner, Ecto.Enum, values: [:human, :ai]

      belongs_to :board, Relay.Boards.Board

      timestamps(type: :utc_datetime)
    end

    @doc "Changeset for stage attributes. `board_id` must already be set on the struct."
    def changeset(stage, attrs) do
      stage
      |> cast(attrs, [:name, :position, :category, :owner])
      |> validate_required([:name, :position, :category, :owner])
      |> unique_constraint(:position, name: :stages_board_id_position_index)
    end
  end
  ```

- [x] Modify `lib/relay.ex` — add `Boards` to the exports list. Change:

  ```elixir
  use Boundary, deps: [], exports: [Repo, Mailer, Accounts, Accounts.Scope]
  ```

  to:

  ```elixir
  use Boundary, deps: [], exports: [Repo, Mailer, Accounts, Accounts.Scope, Boards]
  ```

- [x] Modify `test/support/factory.ex` — add the two factories after `user_factory/0`:

  ```elixir
  def board_factory do
    %Relay.Boards.Board{
      name: "My board",
      slug: sequence(:slug, &"board-#{&1}"),
      key: "RLY",
      owner: build(:user)
    }
  end

  def stage_factory do
    %Relay.Boards.Stage{
      name: sequence(:stage_name, &"Stage #{&1}"),
      position: sequence(:stage_position, & &1),
      category: :unstarted,
      owner: :human,
      board: build(:board)
    }
  end
  ```

- [x] Run `mise exec -- mix test test/relay/boards/` — expect all tests to pass (the `test` alias
  runs pending migrations automatically).
- [x] Run `mise exec -- mix format`, then `mise exec -- mix precommit` — expect green.
- [x] Commit.

**Deliverable:** `Relay.Boards` boundary with `Board`/`Stage` schemas backed by migrated tables
(unique `boards.slug`, unique `stages (board_id, position)`), factories, and passing schema tests.
Independently testable via `mise exec -- mix test test/relay/boards/`.

**Commit message:** `Add Relay.Boards context with Board and Stage schemas (MMF 02)`

---

### Task 2: `Boards.get_or_create_default_board/1` — idempotent provisioning + seeded pipeline

**Files**
- Modify: `lib/relay/boards.ex`
- Test: `test/relay/boards_test.exs` (new)

**Interfaces**
- Consumes (Task 1): `Relay.Boards.Board` / `Relay.Boards.Stage` structs and their `changeset/2`
  functions; `insert(:board)` factory. Consumes (MMF 01): `Relay.Accounts.User` struct with
  `id`, `name`, `email`; `Relay.Repo`.
- Produces: `Relay.Boards.get_or_create_default_board(user :: %Relay.Accounts.User{}) ::
  %Relay.Boards.Board{}` — the returned board always has `stages` preloaded, ordered by
  `position` ascending. Task 4's `BoardLive.mount/3` depends on exactly this contract.

**Steps**

- [ ] Write the failing context test. Create `test/relay/boards_test.exs`:

  ```elixir
  defmodule Relay.BoardsTest do
    use Relay.DataCase, async: true

    alias Relay.Boards
    alias Relay.Boards.Board
    alias Relay.Boards.Stage

    describe "get_or_create_default_board/1" do
      test "creates a board with defaults and the 7 seeded stages, in position order" do
        user = insert(:user, name: "Ada Lovelace")

        board = Boards.get_or_create_default_board(user)

        assert board.owner_id == user.id
        assert board.name == "My board"
        assert board.key == "RLY"
        assert board.slug == "ada-lovelace"

        assert [
                 %Stage{name: "Backlog", position: 1, owner: :human, category: :unstarted},
                 %Stage{name: "Spec", position: 2, owner: :human, category: :unstarted},
                 %Stage{name: "Plan", position: 3, owner: :ai, category: :in_progress},
                 %Stage{name: "Code", position: 4, owner: :ai, category: :in_progress},
                 %Stage{name: "Review", position: 5, owner: :human, category: :in_progress},
                 %Stage{name: "Deploy", position: 6, owner: :ai, category: :in_progress},
                 %Stage{name: "Done", position: 7, owner: :human, category: :complete}
               ] = board.stages
      end

      test "is idempotent — a second call returns the same board with no duplicates" do
        user = insert(:user)

        board1 = Boards.get_or_create_default_board(user)
        board2 = Boards.get_or_create_default_board(user)

        assert board1.id == board2.id
        assert Repo.aggregate(Board, :count) == 1
        assert Repo.aggregate(Stage, :count) == 7
      end

      test "derives the slug from the email local part when the user has no name" do
        user = insert(:user, name: nil, email: "grace.hopper@example.com")

        board = Boards.get_or_create_default_board(user)

        assert board.slug == "grace-hopper"
      end

      test "de-duplicates slugs when two users would produce the same base slug" do
        user1 = insert(:user, name: "Ada Lovelace")
        user2 = insert(:user, name: "Ada Lovelace")

        board1 = Boards.get_or_create_default_board(user1)
        board2 = Boards.get_or_create_default_board(user2)

        assert board1.slug == "ada-lovelace"
        assert board2.slug == "ada-lovelace-2"
        refute board1.id == board2.id
      end

      test "does not return another user's board" do
        other = insert(:user)
        other_board = insert(:board, owner: other)

        user = insert(:user)
        board = Boards.get_or_create_default_board(user)

        refute board.id == other_board.id
        assert board.owner_id == user.id
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay/boards_test.exs` — expect failure
  (`Boards.get_or_create_default_board/1` is undefined).
- [ ] Replace `lib/relay/boards.ex` with the full implementation:

  ```elixir
  defmodule Relay.Boards do
    @moduledoc """
    The Boards context: boards and their stages (the workflow pipeline).
    Cards arrive in MMF 03 (`Relay.Cards`).
    """

    use Boundary, deps: [Relay.Accounts, Relay.Repo], exports: [Board, Stage]

    import Ecto.Query

    alias Relay.Accounts.User
    alias Relay.Boards.Board
    alias Relay.Boards.Stage
    alias Relay.Repo

    @seed_stages [
      {"Backlog", :human, :unstarted},
      {"Spec", :human, :unstarted},
      {"Plan", :ai, :in_progress},
      {"Code", :ai, :in_progress},
      {"Review", :human, :in_progress},
      {"Deploy", :ai, :in_progress},
      {"Done", :human, :complete}
    ]

    @doc """
    Returns the user's board with `stages` preloaded in `position` order,
    creating the board (unique slug derived from the user) and seeding the
    default 7-stage pipeline on first call. Idempotent per user.
    """
    def get_or_create_default_board(%User{} = user) do
      board = Repo.get_by(Board, owner_id: user.id) || create_default_board!(user)
      Repo.preload(board, stages: from(s in Stage, order_by: s.position))
    end

    defp create_default_board!(user) do
      {:ok, board} =
        Repo.transaction(fn ->
          board =
            %Board{owner_id: user.id}
            |> Board.changeset(%{slug: unique_slug(user)})
            |> Repo.insert!()

          @seed_stages
          |> Enum.with_index(1)
          |> Enum.each(fn {{name, owner, category}, position} ->
            %Stage{board_id: board.id}
            |> Stage.changeset(%{name: name, position: position, category: category, owner: owner})
            |> Repo.insert!()
          end)

          board
        end)

      board
    end

    defp unique_slug(user) do
      base = slug_base(user)

      if slug_taken?(base), do: suffixed_slug(base, 2), else: base
    end

    defp suffixed_slug(base, n) do
      candidate = "#{base}-#{n}"

      if slug_taken?(candidate), do: suffixed_slug(base, n + 1), else: candidate
    end

    defp slug_taken?(slug), do: Repo.exists?(from(b in Board, where: b.slug == ^slug))

    defp slug_base(user) do
      source = user.name || (user.email |> String.split("@") |> hd())

      case source |> String.downcase() |> String.replace(~r/[^a-z0-9]+/, "-") |> String.trim("-") do
        "" -> "board"
        base -> base
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay/boards_test.exs` — expect pass.
- [ ] Run `mise exec -- mix format`, then `mise exec -- mix precommit` — expect green.
- [ ] Commit.

**Deliverable:** Idempotent default-board provisioning with the exact 7-stage seeded pipeline and
unique, user-derived slugs (spec acceptance criterion 1 at the domain level). Independently
testable via `mise exec -- mix test test/relay/boards_test.exs`.

**Commit message:** `Add Boards.get_or_create_default_board/1 with seeded 7-stage pipeline (MMF 02)`

---

### Task 3: `owner_pill` + `stage_column` core components with Storybook stories

**Files**
- Modify: `lib/relay_web/components/core_components.ex` (add both components between `list/1` and
  `icon/1`)
- Create: `storybook/core_components/owner_pill.story.exs`
- Create: `storybook/core_components/stage_column.story.exs`
- Modify: `storybook/core_components/_core_components.index.exs` (two `entry/1` clauses)
- Test: `test/relay_web/components/core_components_test.exs` (new — also creates the
  `test/relay_web/components/` directory)

**Interfaces**
- Consumes: nothing new (pure function components; daisyUI theme tokens from
  `assets/css/app.css` — `badge-primary` renders Human blue, `badge-secondary` renders AI violet).
- Produces (Task 4 and MMFs 03/04 consume these exact signatures, auto-imported into every
  LiveView via `RelayWeb.CoreComponents`):
  - `owner_pill/1` — attrs: `owner :: :human | :ai` (required), `class :: any` (default nil).
    Renders a `span.owner-pill.badge` with `badge-primary` + text "Human" or `badge-secondary` +
    text "AI", and `data-owner` set to the owner.
  - `stage_column/1` — attrs: `id :: string` (required), `name :: string` (required),
    `owner :: :human | :ai` (required); slot `inner_block` (optional). Renders a
    `section.stage-column` containing an `h3` with the name, an `owner_pill`, and — only when the
    slot is empty — a `div.stage-empty` placeholder ("No cards yet").

**Steps**

- [ ] Write the failing component tests. Create
  `test/relay_web/components/core_components_test.exs`:

  ```elixir
  defmodule RelayWeb.CoreComponentsTest do
    use ExUnit.Case, async: true

    import Phoenix.Component
    import Phoenix.LiveViewTest

    alias RelayWeb.CoreComponents

    describe "owner_pill/1" do
      test "renders the Human pill with the primary token" do
        html = render_component(&CoreComponents.owner_pill/1, owner: :human)

        assert html =~ "badge-primary"
        assert html =~ "Human"
        assert html =~ ~s(data-owner="human")
        refute html =~ "badge-secondary"
      end

      test "renders the AI pill with the secondary token" do
        html = render_component(&CoreComponents.owner_pill/1, owner: :ai)

        assert html =~ "badge-secondary"
        assert html =~ "AI"
        assert html =~ ~s(data-owner="ai")
        refute html =~ "badge-primary"
      end
    end

    describe "stage_column/1" do
      test "renders the name, owner pill, and empty-state placeholder when empty" do
        html = render_component(&CoreComponents.stage_column/1, id: "stage-col-1", name: "Backlog", owner: :human)

        assert html =~ ~s(id="stage-col-1")
        assert html =~ "Backlog"
        assert html =~ "badge-primary"
        assert html =~ "stage-empty"
        assert html =~ "No cards yet"
      end

      test "renders slot content instead of the empty state" do
        assigns = %{}

        html =
          rendered_to_string(~H"""
          <CoreComponents.stage_column id="stage-col-4" name="Code" owner={:ai}>
            <div id="card-1">A card</div>
          </CoreComponents.stage_column>
          """)

        assert html =~ ~s(id="card-1")
        assert html =~ "badge-secondary"
        refute html =~ "stage-empty"
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/components/core_components_test.exs` — expect
  failure (components don't exist).
- [ ] Add both components to `lib/relay_web/components/core_components.ex`, inserted after the
  `list/1` function and before the `icon/1` doc block:

  ```elixir
  @doc """
  Renders the Human/AI owner pill — who holds the baton for a stage.

  Human maps to the primary (blue) theme token, AI to the secondary
  (violet) one, per the daisyUI theme in `assets/css/app.css`.

  ## Examples

      <.owner_pill owner={:human} />
      <.owner_pill owner={:ai} />
  """
  attr :owner, :atom, values: [:human, :ai], required: true
  attr :class, :any, default: nil

  def owner_pill(assigns) do
    ~H"""
    <span
      class={[
        "owner-pill badge badge-sm font-medium",
        if(@owner == :human, do: "badge-primary", else: "badge-secondary"),
        @class
      ]}
      data-owner={@owner}
    >
      {if @owner == :human, do: "Human", else: "AI"}
    </span>
    """
  end

  @doc """
  Renders one stage column of the board: the stage name, its Human/AI
  owner pill, and the column contents (cards, from MMF 03). Shows a
  dashed empty-state placeholder when no content is given.

  ## Examples

      <.stage_column id="stage-col-1" name="Backlog" owner={:human} />
  """
  attr :id, :string, required: true
  attr :name, :string, required: true
  attr :owner, :atom, values: [:human, :ai], required: true

  slot :inner_block

  def stage_column(assigns) do
    ~H"""
    <section id={@id} class="stage-column flex w-60 shrink-0 flex-col gap-3 rounded-box bg-base-200 p-3">
      <header class="flex items-center justify-between gap-2">
        <h3 class="text-sm font-semibold">{@name}</h3>
        <.owner_pill owner={@owner} />
      </header>
      <div
        :if={@inner_block == []}
        class="stage-empty rounded-lg border border-dashed border-base-content/20 px-3 py-6 text-center text-xs text-base-content/50"
      >
        No cards yet
      </div>
      {render_slot(@inner_block)}
    </section>
    """
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/components/core_components_test.exs` — expect pass.
- [ ] Create `storybook/core_components/owner_pill.story.exs`:

  ```elixir
  defmodule Storybook.Components.CoreComponents.OwnerPill do
    @moduledoc false
    use PhoenixStorybook.Story, :component

    def function, do: &RelayWeb.CoreComponents.owner_pill/1
    def render_source, do: :function

    def variations do
      [
        %Variation{id: :human, attributes: %{owner: :human}},
        %Variation{id: :ai, attributes: %{owner: :ai}}
      ]
    end
  end
  ```

- [ ] Create `storybook/core_components/stage_column.story.exs`:

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
          attributes: %{id: "story-stage-backlog", name: "Backlog", owner: :human}
        },
        %Variation{
          id: :empty_ai,
          attributes: %{id: "story-stage-plan", name: "Plan", owner: :ai}
        },
        %Variation{
          id: :with_content,
          attributes: %{id: "story-stage-code", name: "Code", owner: :ai},
          slots: [
            ~s(<div class="card bg-base-100 p-3 text-sm shadow-sm">A future card</div>)
          ]
        }
      ]
    end
  end
  ```

- [ ] Modify `storybook/core_components/_core_components.index.exs` — add two entries, keeping the
  clauses alphabetical (between `entry("list")` and `entry("table")`):

  ```elixir
  def entry("owner_pill"), do: [icon: {:fa, "tag", :thin}]
  def entry("stage_column"), do: [icon: {:fa, "table-columns", :thin}]
  ```

- [ ] Run `mise exec -- mix format`, then `mise exec -- mix precommit` — expect green.
- [ ] Commit.

**Deliverable:** Reusable `owner_pill` and `stage_column` components (spec acceptance criteria
3 and 4 at the component level) with passing render tests and Storybook stories at
`/storybook/core_components/owner_pill` and `/storybook/core_components/stage_column`.
Independently testable via `mise exec -- mix test test/relay_web/components/core_components_test.exs`.
When reporting completion, mention the two Storybook links (AGENTS.md convention).

**Commit message:** `Add owner_pill and stage_column core components with stories (MMF 02)`

---

### Task 4: `RelayWeb.BoardLive` at `/board` — read-only board with category bands

**Files**
- Create: `lib/relay_web/live/board_live.ex`
- Modify: `lib/relay_web/router.ex` (add `live "/board", BoardLive` inside the existing
  `:require_authenticated` live_session; keep the `/home` route for now — it is removed in Task 5)
- Modify: `lib/relay_web/components/layouts.ex` (add the `wide` attr to `Layouts.app`)
- Test: `test/relay_web/live/board_live_test.exs` (new)

**Interfaces**
- Consumes (Task 2): `Relay.Boards.get_or_create_default_board(user) :: %Board{}` with `stages`
  preloaded in position order. Consumes (Task 3): `<.stage_column id= name= owner= />` (auto-
  imported). Consumes (MMF 01): `socket.assigns.current_scope.user` (set by the
  `{RelayWeb.Auth, :require_authenticated}` on_mount hook); `register_and_log_in_user/1` +
  `log_in_user/2` from `RelayWeb.ConnCase`.
- Produces: route `GET /board` (LiveView `RelayWeb.BoardLive`) — Task 5 redirects sign-in there.
  DOM contract (MMFs 03/04 build on it): `#board` wrapper; per-category `section#category-<category>`
  (`category-unstarted`, `category-in_progress`, `category-complete`) each with an `h2.category-band`;
  stage columns `section#stage-col-<position>.stage-column` (positions 1–7). Also produces
  `Layouts.app`'s new optional attr `wide :: boolean` (default `false`).

**Steps**

- [ ] Write the failing LiveView test. Create `test/relay_web/live/board_live_test.exs`:

  ```elixir
  defmodule RelayWeb.BoardLiveTest do
    use RelayWeb.ConnCase, async: true

    import Phoenix.LiveViewTest

    alias Relay.Boards.Board
    alias Relay.Boards.Stage
    alias Relay.Repo

    describe "when logged out" do
      test "GET /board redirects to the sign-in page", %{conn: conn} do
        assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board")
      end
    end

    describe "when logged in" do
      setup :register_and_log_in_user

      test "provisions the default board with 7 stages on first visit", %{conn: conn, user: user} do
        {:ok, _view, _html} = live(conn, ~p"/board")

        assert [%Board{} = board] = Repo.all(Board)
        assert board.owner_id == user.id
        assert Repo.aggregate(Stage, :count) == 7
      end

      test "revisiting does not create a duplicate board", %{conn: conn} do
        {:ok, _view, _html} = live(conn, ~p"/board")
        {:ok, _view, _html} = live(conn, ~p"/board")

        assert Repo.aggregate(Board, :count) == 1
        assert Repo.aggregate(Stage, :count) == 7
      end

      test "renders the stage columns in position order", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board")

        names =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.filter("#board .stage-column h3")
          |> Enum.map(&LazyHTML.text/1)

        assert names == ["Backlog", "Spec", "Plan", "Code", "Review", "Deploy", "Done"]
      end

      test "groups the stages under their category bands in order", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board")

        assert has_element?(view, "#category-unstarted h2.category-band", "Unstarted")
        assert has_element?(view, "#category-in_progress h2.category-band", "In progress")
        assert has_element?(view, "#category-complete h2.category-band", "Complete")

        assert has_element?(view, "#category-unstarted #stage-col-1", "Backlog")
        assert has_element?(view, "#category-unstarted #stage-col-2", "Spec")
        assert has_element?(view, "#category-in_progress #stage-col-3", "Plan")
        assert has_element?(view, "#category-in_progress #stage-col-4", "Code")
        assert has_element?(view, "#category-in_progress #stage-col-5", "Review")
        assert has_element?(view, "#category-in_progress #stage-col-6", "Deploy")
        assert has_element?(view, "#category-complete #stage-col-7", "Done")

        bands =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.filter("#board .category-band")
          |> Enum.map(&LazyHTML.text/1)

        assert bands == ["Unstarted", "In progress", "Complete"]
      end

      test "shows the right Human/AI owner pill on each stage", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board")

        for position <- [1, 2, 5, 7] do
          assert has_element?(view, "#stage-col-#{position} .owner-pill.badge-primary", "Human")
        end

        for position <- [3, 4, 6] do
          assert has_element?(view, "#stage-col-#{position} .owner-pill.badge-secondary", "AI")
        end
      end

      test "every stage shows the empty-state placeholder", %{conn: conn} do
        {:ok, view, _html} = live(conn, ~p"/board")

        empties =
          view
          |> render()
          |> LazyHTML.from_fragment()
          |> LazyHTML.filter("#board .stage-empty")
          |> Enum.count()

        assert empties == 7
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/live/board_live_test.exs` — expect failure
  (no route / no LiveView).
- [ ] Modify `lib/relay_web/router.ex` — add the board route inside the existing live_session:

  ```elixir
  live_session :require_authenticated, on_mount: [{RelayWeb.Auth, :require_authenticated}] do
    live "/home", HomeLive
    live "/board", BoardLive
  end
  ```

- [ ] Modify `lib/relay_web/components/layouts.ex` — add a `wide` attr to `app/1`. Add after the
  existing `attr :current_scope, ...` declaration:

  ```elixir
  attr :wide, :boolean,
    default: false,
    doc: "when true, use the full-width content container (board pages)"
  ```

  and change the `<main>` inner container from:

  ```heex
  <div class="mx-auto max-w-2xl space-y-4">
  ```

  to:

  ```heex
  <div class={["mx-auto space-y-4", if(@wide, do: "max-w-none", else: "max-w-2xl")]}>
  ```

- [ ] Create `lib/relay_web/live/board_live.ex`:

  ```elixir
  defmodule RelayWeb.BoardLive do
    @moduledoc """
    The authenticated home (`/board`): the user's board rendered as stage
    columns grouped under category bands (Unstarted → In progress →
    Complete). Read-only in MMF 02 — cards arrive in MMF 03.
    """

    use RelayWeb, :live_view

    alias Relay.Boards

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

      {:ok,
       socket
       |> assign(:page_title, board.name)
       |> assign(:board, board)
       |> assign(:stage_groups, group_stages(board.stages))}
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

    defp category_label(:unstarted), do: "Unstarted"
    defp category_label(:in_progress), do: "In progress"
    defp category_label(:complete), do: "Complete"
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/live/board_live_test.exs` — expect pass.
- [ ] Run `mise exec -- mix format`, then `mise exec -- mix precommit` — expect green (the `/home`
  route and its tests still exist and still pass — untouched until Task 5).
- [ ] Commit.

**Deliverable:** Authenticated `/board` renders the seeded board: category band in
Unstarted → In progress → Complete order above 7 stage columns in position order, each with its
name, correct Human/AI pill, and empty-state placeholder; unauthenticated access redirects to `/`.
Covers spec acceptance criteria 1–4 end-to-end. Independently testable via
`mise exec -- mix test test/relay_web/live/board_live_test.exs`.

**Commit message:** `Add BoardLive at /board rendering seeded stages under category bands (MMF 02)`

---

### Task 5: Make `/board` the post-login destination and remove the `/home` stub

**Files**
- Modify: `lib/relay_web/auth.ex` (`log_in_user/2` redirect → `~p"/board"`)
- Modify: `lib/relay_web/controllers/page_controller.ex` (signed-in redirect → `~p"/board"`)
- Modify: `lib/relay_web/router.ex` (remove `live "/home", HomeLive`)
- Delete: `lib/relay_web/live/home_live.ex`
- Delete: `test/relay_web/live/home_live_test.exs` (top-bar + sign-out tests migrate to
  `board_live_test.exs`)
- Modify (tests): `test/relay_web/auth_test.exs`, `test/relay_web/controllers/auth_controller_test.exs`,
  `test/relay_web/controllers/dev_login_controller_test.exs`,
  `test/relay_web/controllers/page_controller_test.exs`, `test/relay_web/live/board_live_test.exs`

**Interfaces**
- Consumes (Task 4): route `GET /board`. Consumes (MMF 01): `RelayWeb.Auth.log_in_user/2` — the
  single redirect point both `AuthController.callback/2` and `DevLoginController.create/2`
  delegate to (neither controller hardcodes `/home`; do not edit them).
- Produces: post-login flow lands on `/board`; `/home` no longer exists (404s via the router).
  `RelayWeb.HomeLive` is fully removed with no dangling references.

**Steps**

- [ ] Update the four MMF 01 test expectations from `/home` to `/board` (failing first):
  - `test/relay_web/auth_test.exs` — in the `log_in_user/2` describe block, rename the test to
    `"renews the session, stores the user id, and redirects to the board"` and change the assert:

    ```elixir
    assert redirected_to(conn) == ~p"/board"
    ```

  - `test/relay_web/controllers/auth_controller_test.exs` — in
    `"with a successful auth upserts the user, starts a session, and redirects home"`, rename the
    test to end in `"and redirects to the board"` and change:

    ```elixir
    assert redirected_to(conn) == ~p"/board"
    ```

  - `test/relay_web/controllers/dev_login_controller_test.exs` — rename the first test to
    `"GET /dev/login signs in the dev user and redirects to the board"` and change:

    ```elixir
    assert redirected_to(conn) == ~p"/board"
    ```

  - `test/relay_web/controllers/page_controller_test.exs` — in the `"GET / when logged in"`
    describe block, rename the test to `"redirects to the board"` and change:

    ```elixir
    assert redirected_to(conn) == ~p"/board"
    ```

- [ ] Run `mise exec -- mix test test/relay_web/auth_test.exs test/relay_web/controllers` —
  expect exactly those four tests to fail (still redirecting to `/home`).
- [ ] Modify `lib/relay_web/auth.ex` — change `log_in_user/2` (and its doc) to:

  ```elixir
  @doc "Renews the session, stores the user id, and redirects to the board."
  def log_in_user(conn, user) do
    conn
    |> renew_session()
    |> put_session(:user_id, user.id)
    |> redirect(to: ~p"/board")
  end
  ```

- [ ] Modify `lib/relay_web/controllers/page_controller.ex`:

  ```elixir
  defmodule RelayWeb.PageController do
    @moduledoc """
    Public sign-in page. Signed-in users are sent straight to the board.
    """

    use RelayWeb, :controller

    def home(conn, _params) do
      if conn.assigns.current_scope do
        redirect(conn, to: ~p"/board")
      else
        render(conn, :home)
      end
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/auth_test.exs test/relay_web/controllers` —
  expect pass.
- [ ] Migrate the layout (top bar / sign-out) tests from `home_live_test.exs` into
  `test/relay_web/live/board_live_test.exs` — append these two describe blocks at the end of the
  module (same assertions as MMF 01, now exercised through `/board`):

  ```elixir
  describe "top bar" do
    test "shows the avatar image and a sign out link", %{conn: conn} do
      user = insert(:user, avatar_url: "https://example.com/me.png")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board")

      assert has_element?(view, "#user-avatar img")
      assert has_element?(view, "#sign-out")
    end

    test "falls back to initials when the user has no avatar image", %{conn: conn} do
      user = insert(:user, avatar_url: nil, name: "Ada Lovelace")
      {:ok, view, _html} = conn |> log_in_user(user) |> live(~p"/board")

      refute has_element?(view, "#user-avatar img")
      assert has_element?(view, "#user-avatar", "AL")
    end
  end

  describe "signing out" do
    test "after sign out, the board route requires signing in again", %{conn: conn} do
      user = insert(:user)
      conn = conn |> log_in_user(user) |> delete(~p"/logout")

      assert {:error, {:redirect, %{to: "/"}}} = live(conn, ~p"/board")
    end
  end
  ```

- [ ] Run `mise exec -- mix test test/relay_web/live/board_live_test.exs` — expect pass (these
  test the shared layout, already in place).
- [ ] Remove the `/home` stub:
  - In `lib/relay_web/router.ex`, delete the line `live "/home", HomeLive` (keep the
    live_session block with `live "/board", BoardLive`).
  - Delete `lib/relay_web/live/home_live.ex`.
  - Delete `test/relay_web/live/home_live_test.exs`.
- [ ] Verify no dangling references: `grep -rn "HomeLive\|/home" lib test` must return no hits
  (a `~p"/home"` left anywhere fails compilation under verified routes; `HomeLive` left in the
  router fails compilation outright).
- [ ] Run the full suite: `mise exec -- mix test` — expect green with warnings-as-errors.
- [ ] Run `mise exec -- mix format`, then `mise exec -- mix precommit` — expect green.
- [ ] Commit.

**Deliverable:** Signing in (Google or `/dev/login`) and visiting `/` while signed in both land on
`/board`; the `/home` stub (LiveView, route, test) is gone with zero dangling references; the
top-bar/sign-out coverage now runs against `/board`. Full suite + precommit green. Independently
testable via `mise exec -- mix test`.

**Commit message:** `Point post-login destination at /board and remove the /home stub (MMF 02)`

---

## Post-plan notes for the executor

- Commit messages above are the subject lines; append the repo/harness standard trailers
  (Co-Authored-By / session link) per convention.
- When reporting completion to the user, include the Storybook links for the new components
  (`/storybook/core_components/owner_pill`, `/storybook/core_components/stage_column`) — AGENTS.md
  requires announcing new component stories.
- Spec coverage map: acceptance criterion 1 (auto-provisioned board + seeded stages) → Tasks 2 & 4;
  criterion 2 (position order under category bands) → Task 4; criterion 3 (name + Human/AI pill)
  → Tasks 3 & 4; criterion 4 (design tokens: Human=primary/blue, AI=secondary/violet) → Task 3.
  Auth gating test (spec Testing section) → Task 4; post-login redirect change → Task 5.
- Deliberately out of scope (per spec): cards, drawer, card movement, WIP limits, stage editing,
  multiple boards, slug routing, `Board.card_seq`, editing `Board.key`.
