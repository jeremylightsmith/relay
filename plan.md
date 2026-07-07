# Plan — MMF 06: The baton (card ownership + status) on a shared `Schemas` boundary

**Spec:** `docs/superpowers/specs/2026-07-07-baton-ownership-status-design.md`
**Development:** trunk-based on `main`. One commit per task, message given at the end of each task.

## Goal

Make **who holds each card** (human vs AI) and **what state it's in** first-class and visible:

1. **Part A (foundational refactor, no behaviour change):** extract the 5 existing Ecto
   schemas into a new top-level **`Schemas`** boundary (ADR 0002) — a peer depended on by
   both the domain (`Relay.*` contexts) and the web layer (`RelayWeb`).
2. **Part B (the baton):** cards gain a `status` enum + nullable `progress`, and a settable
   **list of owner actors** (`card_owners` join — a user or the single Relay AI agent). The
   **active owner is derived** (AI active if the agent is among the owners, else the humans;
   the others render paused). The board renders the colour system (violet AI / blue human
   left border + owner pill, amber NEEDS INPUT, status badge, red stage-mismatch warning in
   both directions), and the drawer's properties rail shows ACTIVE WORKER + owners and lets
   the user set status and add/remove owners (including claiming/releasing the AI).

**Nothing changes automatically:** moving a card (MMF 05) must NOT touch its owners or
status. `Stage.owner` is retained purely as the "meant for" designation.

**Out of scope:** interactive needs-input Q&A (MMF 14), review-gate actions (MMF 15),
progress automation, comments/activity (MMF 07), API (MMF 09).

## Architecture

- **`Schemas` boundary** (`lib/schemas.ex`, modules in `lib/schemas/*.ex`): plain
  `use Ecto.Schema` modules holding data shape + changesets only. `use Boundary, deps: [],
  exports: [Board, Card, CardOwner, Scope, Stage, User]`. Both `Relay.*` contexts and
  `RelayWeb` declare `Schemas` in their boundary `deps`. Business logic stays in contexts.
- **`Relay.Cards`** owns all card business logic: status setter (`set_status/2`), owner
  management (`set_owners/2`, `add_owner/2`, `remove_owner/2`), active-owner derivation
  (`active_owner_type/1`), and owner preloading on every card-returning function.
- **Actor representation** (one concept app-wide): an actor is `:agent` (the single Relay
  AI) or `{:user, user_id}`. Stored in `card_owners` as `actor_type` (`:user | :agent`) +
  nullable `user_id` (required iff `:user`).
- **Web layer:** `RelayWeb.CoreComponents.board_card/1` renders the colour system from
  passed-in `active_owner` / `stage_owner` / `status` / `progress`; `card_drawer/1` renders
  the baton rail; `RelayWeb.BoardLive` handles the `set_card_status` / `add_owner` /
  `remove_owner` events and keeps streams + drawer in sync. Every card struct that enters a
  LiveView stream has `owners` (with `:user`) preloaded.

## Tech

Elixir / Phoenix 1.8 / LiveView (streams), Ecto + Postgres, `boundary` (compiler-enforced),
Tailwind v4 + daisyUI (theme tokens: primary = Human blue, secondary = AI violet,
warning = amber, success = green, error = red), ExMachina factories, Phoenix Storybook.

## Global Constraints (project rules — copied verbatim, apply to every task)

- Running `mix precommit` is REQUIRED on every development cycle and must pass before work
  is considered done. It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings
  as errors). Fix any failure before finishing — never commit work with a failing
  `mix precommit`.
- **Context boundaries are enforced by `boundary`** (wired into the compiler). The web layer
  (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may
  not reach into the web layer. A boundary violation fails compilation.
- Elixir lists **do not support index based access via the access syntax** — always use
  `Enum.at`, pattern matching, or `List`.
- Predicate function names should not start with `is_` and should end in a question mark.
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast`
  calls or similar for security purposes. Instead they must be explicitly set when creating
  the struct.
- **Always** use LiveView streams for collections. When updating an assign that should
  change content inside any streamed item(s), you MUST re-stream (`stream_insert`) the
  items. To filter/reorder, refetch and re-stream with `reset: true`. Streams are not
  enumerable and cannot be counted — counts live in separate assigns.
- **Always** use the imported `<.input>` component for form inputs and the `<.icon>`
  component for icons (never `Heroicons` modules).
- **daisyUI is adopted** — prefer daisyUI components (`btn`, `card`, `badge`, `select`,
  `input`, …) themed via the `light` / `dark` tokens in `assets/css/app.css`.
- **Never** use `<% Enum.each %>` in templates; use `<%= for ... do %>` / `:for`. HEEx class
  attrs with multiple values **always** use list `[...]` syntax; wrap `if`s in parens.
- **Avoid LiveComponents.** LiveViews are named with a `Live` suffix.
- **Storybook is the home for every reusable component** — when a reusable component is
  added or changed, add/refresh its story under `storybook/` and tell the user, including a
  link to that component's storybook page.
- **Always** preload Ecto associations in queries when they'll be accessed in templates.
- `Ecto.Changeset.validate_number/2` does not support `:allow_nil` (validations already
  skip nil changes). Use `Ecto.Changeset.get_field/2` to read changeset fields.
- **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` when
  generating migration files.
- **Always** use `to_form/2` + `<.form for={@form}>` + `@form[:field]` — never access a
  changeset in the template.
- **Always** add unique DOM IDs to key elements and reference those IDs in tests
  (`element/2`, `has_element?/2`); never assert against raw HTML when an element selector
  works.
- Tests: **avoid** `Process.sleep/1`; use `start_supervised!/1` for processes.
- TDD every task: write the failing test first, watch it fail, implement minimally, watch
  it pass.

---

### Task 1: Extract the shared `Schemas` boundary (ADR 0002) — pure refactor, no behaviour change

Move the 5 existing schema modules to a new top-level `Schemas.*` namespace and boundary.
The full test suite must be green before AND after — no test semantics change, only module
names, file locations, aliases, and boundary declarations.

**Files**

- Create: `docs/adr/0002-module-boundaries-and-schemas-peer.md`
- Create: `lib/schemas.ex`
- Move (git mv + rename module): `lib/relay/boards/board.ex` → `lib/schemas/board.ex`,
  `lib/relay/boards/stage.ex` → `lib/schemas/stage.ex`,
  `lib/relay/cards/card.ex` → `lib/schemas/card.ex`,
  `lib/relay/accounts/user.ex` → `lib/schemas/user.ex`,
  `lib/relay/accounts/scope.ex` → `lib/schemas/scope.ex`
- Move (git mv + rename module): `test/relay/boards/board_test.exs` → `test/schemas/board_test.exs`,
  `test/relay/boards/stage_test.exs` → `test/schemas/stage_test.exs`,
  `test/relay/cards/card_test.exs` → `test/schemas/card_test.exs`
- Modify: `lib/relay.ex`, `lib/relay/accounts.ex`, `lib/relay/boards.ex`,
  `lib/relay/cards.ex`, `lib/relay_web.ex`, `lib/relay_web/auth.ex`,
  `lib/relay_web/live/board_live.ex`, `lib/relay_web/components/layouts.ex` (comment only),
  `test/support/factory.ex`, `test/relay/cards_test.exs`, `test/relay/accounts_test.exs`,
  `test/relay/boards_test.exs`, `test/relay_web/auth_test.exs`,
  `test/relay_web/live/board_live_test.exs`,
  `test/relay_web/controllers/dev_login_controller_test.exs`,
  `test/relay_web/controllers/auth_controller_test.exs`, `docs/adr/README.md`

**Interfaces**

- Consumes: nothing from earlier tasks.
- Produces (later tasks build on these exact names):
  - `Schemas.Board`, `Schemas.Stage`, `Schemas.Card`, `Schemas.User`, `Schemas.Scope` —
    same fields/functions as today (`changeset/2` on Board/Stage/Card/User;
    `Schemas.Scope.for_user/1`).
  - `Schemas` boundary: `use Boundary, deps: [], exports: [Board, Card, Scope, Stage, User]`.
  - Boundary shape: `Relay.Accounts` deps `[Relay.Repo, Schemas]`; `Relay.Boards` deps
    `[Relay.Repo, Schemas]`; `Relay.Cards` deps `[Relay.Repo, Schemas]`; `Relay` root
    exports `[Repo, Mailer, Accounts, Boards, Cards]`; `RelayWeb` deps `[Relay, Schemas]`.

**Steps**

- [x] Baseline: run `mix precommit` and confirm it passes on a clean tree (if it fails here, stop — the tree is broken before this plan).
- [x] Create `lib/schemas.ex`:

```elixir
defmodule Schemas do
  @moduledoc """
  Shared Ecto schemas (ADR 0002) — a top-level peer boundary depended on by
  both the domain (`Relay.*` contexts) and the web layer (`RelayWeb`).
  Schemas hold data shape and changesets; business logic stays in the
  contexts. Schemas may reference each other freely within this boundary.
  """

  use Boundary, deps: [], exports: [Board, Card, Scope, Stage, User]
end
```

- [x] `git mv lib/relay/boards/board.ex lib/schemas/board.ex` and replace its entire content with (only the module name and association module names change):

```elixir
defmodule Schemas.Board do
  @moduledoc """
  A user's kanban board. One board per user for now (MMF 19 adds more).
  `slug` is stored for future slug-routing (MMF 19); `key` is the short
  card-ref prefix (e.g. "RLY-12", used from MMF 03). `owner_id` is set
  programmatically, never cast from input. `card_seq` is the per-board
  card-ref counter (MMF 03), bumped under a row lock by
  `Relay.Cards.create_card/2` and never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "boards" do
    field :name, :string, default: "My board"
    field :slug, :string
    field :key, :string, default: "RLY"
    field :card_seq, :integer, default: 0

    belongs_to :owner, Schemas.User
    has_many :stages, Schemas.Stage

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

- [x] `git mv lib/relay/boards/stage.ex lib/schemas/stage.ex` and replace its content with:

```elixir
defmodule Schemas.Stage do
  @moduledoc """
  A column on a board. `category` groups stages under the board's category
  band (unstarted → in_progress → complete); `owner` says who work in this
  stage is **meant for** — human (blue) or ai (violet). It is NOT the
  card's owner (cards carry their own owner list from MMF 06). `board_id`
  is set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "stages" do
    field :name, :string
    field :position, :integer
    field :category, Ecto.Enum, values: [:unstarted, :in_progress, :complete]
    field :owner, Ecto.Enum, values: [:human, :ai]

    belongs_to :board, Schemas.Board

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

- [x] `git mv lib/relay/cards/card.ex lib/schemas/card.ex` and replace its content with:

```elixir
defmodule Schemas.Card do
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
    field :description, :string
    field :position, :integer
    field :tag, :string
    field :ref_number, :integer

    belongs_to :board, Schemas.Board
    belongs_to :stage, Schemas.Stage

    timestamps(type: :utc_datetime)
  end

  @doc """
  Changeset for user-supplied card attributes (`:title`, `:description`,
  `:tag`). `board_id`, `stage_id`, `position`, and `ref_number` must
  already be set on the struct and are never cast.
  """
  def changeset(card, attrs) do
    card
    |> cast(attrs, [:title, :description, :tag])
    |> validate_required([:title])
    |> unique_constraint([:board_id, :ref_number], name: :cards_board_id_ref_number_index)
  end
end
```

- [x] `git mv lib/relay/accounts/user.ex lib/schemas/user.ex` and replace its content with:

```elixir
defmodule Schemas.User do
  @moduledoc """
  A person who signed in. Identity is keyed on `provider_uid`
  (Google's stable `sub` claim); `provider` and `provider_uid` are set
  programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "users" do
    field :email, :string
    field :name, :string
    field :avatar_url, :string
    field :provider, :string
    field :provider_uid, :string

    timestamps(type: :utc_datetime)
  end

  @doc "Changeset for profile fields coming from the OAuth provider."
  def changeset(user, attrs) do
    user
    |> cast(attrs, [:email, :name, :avatar_url])
    |> validate_required([:email])
    |> unique_constraint(:email)
    |> unique_constraint(:provider_uid)
  end
end
```

- [x] `git mv lib/relay/accounts/scope.ex lib/schemas/scope.ex` and replace its content with:

```elixir
defmodule Schemas.Scope do
  @moduledoc """
  The current-user scope handed to LiveViews and controllers as
  `current_scope` (Phoenix 1.8 convention; `<Layouts.app>` expects it).
  `nil` means "not signed in".
  """

  alias Schemas.User

  defstruct user: nil

  @doc "Builds a scope for a signed-in user; returns nil for nil."
  def for_user(%User{} = user), do: %__MODULE__{user: user}
  def for_user(nil), do: nil
end
```

- [x] Remove the now-empty dirs: `rmdir lib/relay/boards lib/relay/cards lib/relay/accounts 2>/dev/null || true` (only the sub-dirs are empty — `lib/relay/boards.ex` etc. remain).
- [x] Update `lib/relay.ex` — the exports line. Old:

```elixir
    exports: [Repo, Mailer, Accounts, Accounts.Scope, Boards, Boards.Stage, Cards, Cards.Card]
```

New:

```elixir
    exports: [Repo, Mailer, Accounts, Boards, Cards]
```

- [x] Update `lib/relay/accounts.ex`. Old lines:

```elixir
  use Boundary, deps: [Relay.Repo], exports: [User, Scope]
```
```elixir
  alias Relay.Accounts.User
```

New lines:

```elixir
  use Boundary, deps: [Relay.Repo, Schemas]
```
```elixir
  alias Schemas.User
```

- [x] Update `lib/relay/boards.ex`. Old lines:

```elixir
  use Boundary, deps: [Relay.Accounts, Relay.Repo], exports: [Board, Stage]
```
```elixir
  alias Relay.Accounts.User
  alias Relay.Boards.Board
  alias Relay.Boards.Stage
```

New lines (Boards no longer calls any `Relay.Accounts` function — its only Accounts
reference was the `User` schema, which now lives in `Schemas`):

```elixir
  use Boundary, deps: [Relay.Repo, Schemas]
```
```elixir
  alias Schemas.Board
  alias Schemas.Stage
  alias Schemas.User
```

- [x] Update `lib/relay/cards.ex`. Old lines:

```elixir
  use Boundary, deps: [Relay.Boards, Relay.Repo], exports: [Card]
```
```elixir
  alias Relay.Boards.Board
  alias Relay.Boards.Stage
  alias Relay.Cards.Card
```

New lines (Cards referenced only Boards *schemas*, no Boards functions):

```elixir
  use Boundary, deps: [Relay.Repo, Schemas]
```
```elixir
  alias Schemas.Board
  alias Schemas.Card
  alias Schemas.Stage
```

- [x] Update `lib/relay_web.ex`. Old: `use Boundary, deps: [Relay], exports: [Endpoint, Telemetry]` → New: `use Boundary, deps: [Relay, Schemas], exports: [Endpoint, Telemetry]`.
- [x] Update `lib/relay_web/auth.ex`. Old: `alias Relay.Accounts.Scope` → New: `alias Schemas.Scope` (keep `alias Relay.Accounts`).
- [x] Update `lib/relay_web/live/board_live.ex`. Old:

```elixir
  alias Relay.Boards
  alias Relay.Boards.Stage
  alias Relay.Cards
  alias Relay.Cards.Card
```

New:

```elixir
  alias Relay.Boards
  alias Relay.Cards
  alias Schemas.Card
  alias Schemas.Stage
```

- [x] Update the comment in `lib/relay_web/components/layouts.ex` (lines 98–100). Old:

```elixir
  # Initials for the avatar fallback, from the user's name (or email
  # when the name is missing). Plain dot access on purpose: Accounts.User
  # is not exported through the Relay boundary to the web layer.
```

New:

```elixir
  # Initials for the avatar fallback, from the user's name (or email
  # when the name is missing). Works on any user-shaped map or the
  # Schemas.User struct.
```

- [x] Update `test/support/factory.ex` — replace the four struct names: `%Relay.Accounts.User{` → `%Schemas.User{`, `%Relay.Boards.Board{` → `%Schemas.Board{`, `%Relay.Boards.Stage{` → `%Schemas.Stage{`, `%Relay.Cards.Card{` → `%Schemas.Card{` (4 occurrences total, one each).
- [x] Update test aliases (exact replacements, keep context aliases like `Relay.Cards` / `Relay.Boards` / `Relay.Accounts` untouched):
  - `test/relay/cards_test.exs`: `alias Relay.Boards.Board` → `alias Schemas.Board`; `alias Relay.Cards.Card` → `alias Schemas.Card`
  - `test/relay/accounts_test.exs`: `alias Relay.Accounts.Scope` → `alias Schemas.Scope`; `alias Relay.Accounts.User` → `alias Schemas.User`
  - `test/relay/boards_test.exs`: `alias Relay.Boards.Board` → `alias Schemas.Board`; `alias Relay.Boards.Stage` → `alias Schemas.Stage`
  - `test/relay_web/auth_test.exs`: `alias Relay.Accounts.Scope` → `alias Schemas.Scope`
  - `test/relay_web/live/board_live_test.exs`: `alias Relay.Boards.Board` → `alias Schemas.Board`; `alias Relay.Boards.Stage` → `alias Schemas.Stage`; `alias Relay.Cards.Card` → `alias Schemas.Card`
  - `test/relay_web/controllers/dev_login_controller_test.exs`: `alias Relay.Accounts.User` → `alias Schemas.User`
  - `test/relay_web/controllers/auth_controller_test.exs`: `alias Relay.Accounts.User` → `alias Schemas.User`
- [x] Move the three schema test files and rename their modules + aliases:
  - `git mv test/relay/boards/board_test.exs test/schemas/board_test.exs`; change `defmodule Relay.Boards.BoardTest do` → `defmodule Schemas.BoardTest do` and `alias Relay.Boards.Board` → `alias Schemas.Board`.
  - `git mv test/relay/boards/stage_test.exs test/schemas/stage_test.exs`; change `defmodule Relay.Boards.StageTest do` → `defmodule Schemas.StageTest do` and `alias Relay.Boards.Stage` → `alias Schemas.Stage`.
  - `git mv test/relay/cards/card_test.exs test/schemas/card_test.exs`; change `defmodule Relay.Cards.CardTest do` → `defmodule Schemas.CardTest do`, `alias Relay.Boards.Board` → `alias Schemas.Board`, `alias Relay.Boards.Stage` → `alias Schemas.Stage`, `alias Relay.Cards.Card` → `alias Schemas.Card` (keep `alias Relay.Cards`).
  - `rmdir test/relay/boards test/relay/cards`
- [x] Run `mix compile --warnings-as-errors` — expect success (this is the boundary check). If boundary reports a violation, the missed alias it names is the fix — do NOT weaken any boundary declaration.
- [x] Run `mix test` — the full suite must pass with zero failures.
- [x] Write `docs/adr/0002-module-boundaries-and-schemas-peer.md`:

```markdown
# ADR 0002 — Module boundaries (`boundary`) + a `Schemas` peer

## Status
Accepted (2026-07-07)

## Context

The domain (`Relay.*` contexts) and web (`RelayWeb.*`) layers already use
[`boundary`](https://hexdocs.pm/boundary) as a compiler (wired in `mix.exs` via
`compilers: [:boundary, ...]`), with each context a sub-boundary of `Relay`. But the Ecto
schemas lived *inside* the contexts (`Relay.Cards.Card`, `Relay.Boards.Stage`, …), which
forces schema-only coupling to masquerade as context coupling: `Relay.Cards` depended on
`Relay.Boards` solely to reference the `Board`/`Stage` structs, and `Relay.Boards` depended
on `Relay.Accounts` solely for the `User` struct. As MMF 06+ add cross-cutting schemas
(`CardOwner`, later `Comment`, `Activity`, `ApiKey`), that pattern breeds artificial
dependencies and, eventually, cycles. The reference is the sibling project `throughway`
(its ADR 0004), where a peer `Schemas` namespace dissolved the same problem.

## Decision

- **`Schemas` is a top-level peer boundary** at `lib/schemas/` (modules `Schemas.*`),
  holding plain `use Ecto.Schema` modules + their changesets, with
  `use Boundary, deps: [], exports: [Board, Card, CardOwner, Scope, Stage, User]`.
  Schemas may reference each other freely inside the boundary. Schemas hold data, not
  business logic — logic stays in the contexts.
- `Schemas.Scope` (the `current_scope` struct) lives here too: it is a plain struct shared
  by web and domain, exactly the kind of type the peer exists for.
- **Boundary shape** (deps are minimal and compiler-enforced):

  | Boundary | `deps:` |
  | --- | --- |
  | `Relay.Repo`, `Relay.Mailer` | `[]` (leaves) |
  | `Relay.Accounts` | `[Relay.Repo, Schemas]` |
  | `Relay.Boards` | `[Relay.Repo, Schemas]` |
  | `Relay.Cards` | `[Relay.Repo, Schemas]` |
  | `Relay` (root) | `[]`, exports `[Repo, Mailer, Accounts, Boards, Cards]` |
  | `RelayWeb` | `[Relay, Schemas]`, exports `[Endpoint, Telemetry]` |
  | `Relay.Application` | `top_level?: true, deps: [Relay, RelayWeb]` |

  Note the context-to-context deps disappeared: they were schema references all along.
- **All new schemas** (MMF 06's `CardOwner`; later `Comment`, `Activity`, `ApiKey`) are
  born in `Schemas.*`.

## Consequences

- Cross-layer coupling is explicit and compiler-checked; a boundary violation fails
  `mix compile` (and therefore `mix precommit`).
- The one-time mechanical cost: 5 schema modules moved/renamed and every alias updated
  (done in MMF 06, no behaviour change).
- Contexts stay the only place with business logic; the web layer reads schema structs and
  calls exported context functions — same rule as before, now with the struct types in a
  shared, dependency-free home.
```

- [x] Add the ADR to the `docs/adr/README.md` table (a new row after the 0001 row):

```markdown
| [0002](0002-module-boundaries-and-schemas-peer.md) | Module boundaries (`boundary`) + a `Schemas` peer | Accepted |
```

- [x] Run `mix precommit` — must pass (compile + boundary, format, credo, sobelow, deps.audit, full suite).
- [x] Commit everything.

**Deliverable:** identical app behaviour with all five schemas living at `Schemas.*`,
boundary graph per ADR 0002, ADR published, suite green.
**Commit message:** `refactor: extract shared Schemas boundary (ADR 0002)`

---

### Task 2: `card_owners` join — `Schemas.CardOwner` + migration + factory

The owner list storage: one row per (card, actor). An actor is a user (`actor_type: :user`
+ `user_id`) or the single Relay AI agent (`actor_type: :agent`, `user_id` nil).

**Files**

- Create: `lib/schemas/card_owner.ex`
- Create: migration via `mix ecto.gen.migration create_card_owners`
  (→ `priv/repo/migrations/<timestamp>_create_card_owners.exs`)
- Create: `test/schemas/card_owner_test.exs`
- Modify: `lib/schemas.ex` (add `CardOwner` to exports), `lib/schemas/card.ex`
  (add `has_many :owners`), `test/support/factory.ex` (add `card_owner_factory/1`)

**Interfaces**

- Consumes (Task 1): `Schemas.Card`, `Schemas.User`, `Relay.Factory` patterns
  (`insert(:card)`, `insert(:user)`).
- Produces:
  - `Schemas.CardOwner` — fields `card_id :: integer`, `actor_type :: :user | :agent`
    (Ecto.Enum), `user_id :: integer | nil`; `belongs_to :card, Schemas.Card`;
    `belongs_to :user, Schemas.User`.
  - `Schemas.CardOwner.changeset(card_owner :: %Schemas.CardOwner{}) :: Ecto.Changeset.t()`
    — arity 1; all fields are programmatic (set on the struct, never cast).
  - `Schemas.Card` gains `has_many :owners, Schemas.CardOwner`.
  - Factory: `insert(:card_owner)` (agent owner of a fresh card),
    `insert(:card_owner, card: card)` (agent owner of `card`),
    `insert(:card_owner, card: card, user: user)` (human owner).
  - DB: partial unique indexes `card_owners_user_owner_index` on
    `(card_id, actor_type, user_id) WHERE user_id IS NOT NULL` and
    `card_owners_agent_owner_index` on `(card_id, actor_type) WHERE user_id IS NULL`.

**Steps**

- [ ] Write the failing test `test/schemas/card_owner_test.exs`:

```elixir
defmodule Schemas.CardOwnerTest do
  use Relay.DataCase, async: true

  alias Schemas.Card
  alias Schemas.CardOwner

  describe "changeset/1" do
    test "is valid for an agent owner (no user_id)" do
      card = insert(:card)

      changeset = CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :agent})

      assert changeset.valid?
    end

    test "is valid for a user owner with a user_id" do
      card = insert(:card)
      user = insert(:user)

      changeset =
        CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user, user_id: user.id})

      assert changeset.valid?
    end

    test "requires card_id and actor_type" do
      changeset = CardOwner.changeset(%CardOwner{})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).card_id
      assert "can't be blank" in errors_on(changeset).actor_type
    end

    test "a user owner requires a user_id" do
      card = insert(:card)

      changeset = CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user})

      refute changeset.valid?
      assert "can't be blank" in errors_on(changeset).user_id
    end

    test "an agent owner must not carry a user_id" do
      card = insert(:card)
      user = insert(:user)

      changeset =
        CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :agent, user_id: user.id})

      refute changeset.valid?
      assert "must be empty for the AI agent" in errors_on(changeset).user_id
    end
  end

  describe "persistence" do
    test "rejects a duplicate user owner on the same card" do
      card = insert(:card)
      user = insert(:user)
      owner = %CardOwner{card_id: card.id, actor_type: :user, user_id: user.id}

      assert {:ok, _} = Repo.insert(CardOwner.changeset(owner))
      assert {:error, changeset} = Repo.insert(CardOwner.changeset(owner))
      refute changeset.valid?
    end

    test "rejects a duplicate agent owner on the same card" do
      card = insert(:card)
      owner = %CardOwner{card_id: card.id, actor_type: :agent}

      assert {:ok, _} = Repo.insert(CardOwner.changeset(owner))
      assert {:error, changeset} = Repo.insert(CardOwner.changeset(owner))
      refute changeset.valid?
    end

    test "rejects an unknown user_id with a changeset error" do
      card = insert(:card)

      assert {:error, changeset} =
               Repo.insert(
                 CardOwner.changeset(%CardOwner{card_id: card.id, actor_type: :user, user_id: -1})
               )

      refute changeset.valid?
    end

    test "insert(:card_owner) builds an agent owner; passing user builds a human owner" do
      agent_owner = insert(:card_owner)
      user = insert(:user)
      card = insert(:card)
      human_owner = insert(:card_owner, card: card, user: user)

      assert agent_owner.actor_type == :agent
      assert agent_owner.user_id == nil
      assert human_owner.actor_type == :user
      assert human_owner.user_id == user.id
      assert human_owner.card_id == card.id
    end

    test "deleting a card deletes its owner rows" do
      card = insert(:card)
      owner = insert(:card_owner, card: card)

      Repo.delete!(Repo.get!(Card, card.id))

      assert Repo.get(CardOwner, owner.id) == nil
    end

    test "a card preloads its owners" do
      card = insert(:card)
      insert(:card_owner, card: card)

      assert [%CardOwner{actor_type: :agent}] =
               Repo.preload(Repo.get!(Card, card.id), :owners).owners
    end
  end
end
```

- [ ] Run `mix test test/schemas/card_owner_test.exs` — expect failure (module and table don't exist).
- [ ] Run `mix ecto.gen.migration create_card_owners` and fill the generated file:

```elixir
defmodule Relay.Repo.Migrations.CreateCardOwners do
  use Ecto.Migration

  def change do
    create table(:card_owners) do
      add :card_id, references(:cards, on_delete: :delete_all), null: false
      add :actor_type, :string, null: false
      add :user_id, references(:users, on_delete: :delete_all)

      timestamps(type: :utc_datetime)
    end

    # Two partial unique indexes because Postgres treats NULLs as distinct:
    # one guards duplicate (card, user) owners, the other duplicate agent rows.
    create unique_index(:card_owners, [:card_id, :actor_type, :user_id],
             where: "user_id IS NOT NULL",
             name: :card_owners_user_owner_index
           )

    create unique_index(:card_owners, [:card_id, :actor_type],
             where: "user_id IS NULL",
             name: :card_owners_agent_owner_index
           )

    create index(:card_owners, [:user_id])
  end
end
```

- [ ] Create `lib/schemas/card_owner.ex`:

```elixir
defmodule Schemas.CardOwner do
  @moduledoc """
  One owner of a card — the "actor" concept: either a user
  (`actor_type: :user` + `user_id`) or the single Relay AI agent
  (`actor_type: :agent`, no `user_id`). A card has many owners; the active
  owner is derived by `Relay.Cards.active_owner_type/1`, never stored.
  All fields are set programmatically, never cast from input.
  """

  use Ecto.Schema

  import Ecto.Changeset

  schema "card_owners" do
    field :actor_type, Ecto.Enum, values: [:user, :agent]

    belongs_to :card, Schemas.Card
    belongs_to :user, Schemas.User

    timestamps(type: :utc_datetime)
  end

  @doc """
  Validates a programmatically-built owner row: `card_id` and `actor_type`
  are required; `user_id` is required iff the actor is a `:user` and must
  be absent for the `:agent`.
  """
  def changeset(card_owner) do
    card_owner
    |> change()
    |> validate_required([:card_id, :actor_type])
    |> validate_actor_user()
    |> foreign_key_constraint(:card_id)
    |> foreign_key_constraint(:user_id)
    |> unique_constraint([:card_id, :actor_type, :user_id], name: :card_owners_user_owner_index)
    |> unique_constraint([:card_id, :actor_type], name: :card_owners_agent_owner_index)
  end

  defp validate_actor_user(changeset) do
    case {get_field(changeset, :actor_type), get_field(changeset, :user_id)} do
      {:user, nil} -> add_error(changeset, :user_id, "can't be blank")
      {:agent, user_id} when not is_nil(user_id) -> add_error(changeset, :user_id, "must be empty for the AI agent")
      _other -> changeset
    end
  end
end
```

- [ ] Add `has_many :owners, Schemas.CardOwner` to the `schema "cards"` block in `lib/schemas/card.ex` (directly after the two `belongs_to` lines).
- [ ] Update `lib/schemas.ex` exports to `[Board, Card, CardOwner, Scope, Stage, User]`.
- [ ] Add the factory to `test/support/factory.ex` (after `card_factory/1`):

```elixir
  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, builds a human owner; without, the single AI agent owner.
  def card_owner_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    owner = %Schemas.CardOwner{
      card_id: card.id,
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id
    }

    owner |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end
```

- [ ] Run `mix ecto.migrate`, then `mix test test/schemas/card_owner_test.exs` — expect pass.
- [ ] Run `mix precommit` — must pass. Commit.

**Deliverable:** the `card_owners` table + `Schemas.CardOwner` with validated
programmatic changesets, duplicate-proof at the DB level, factory support.
**Commit message:** `feat(cards): card_owners join schema (Schemas.CardOwner)`

---

### Task 3: Card `status` + `progress` and `Relay.Cards.set_status/2`

**Files**

- Create: migration via `mix ecto.gen.migration add_status_and_progress_to_cards`
- Modify: `lib/schemas/card.ex` (fields + `status_changeset/2`),
  `lib/relay/cards.ex` (`set_status/2` + preload helpers),
  `test/schemas/card_test.exs`, `test/relay/cards_test.exs`

**Interfaces**

- Consumes (Tasks 1–2): `Schemas.Card` (now with `has_many :owners`), `Relay.Cards`,
  factory `insert(:card)`.
- Produces:
  - `Schemas.Card` fields: `status :: :queued | :working | :needs_input | :in_review | :done`
    (Ecto.Enum, default `:queued`), `progress :: integer | nil`.
  - `Schemas.Card.status_changeset(card :: %Schemas.Card{}, attrs :: map()) :: Ecto.Changeset.t()`
    — casts `:status` + `:progress`, validates progress in 0..100.
  - `Relay.Cards.set_status(card :: %Schemas.Card{}, attrs :: map()) ::
    {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}` — returned card has
    `owners: :user` preloaded.
  - Private helpers in `Relay.Cards` reused by Task 4: `preload_owners/1`
    (nil-safe, preloads `owners: :user`) and `preload_owners_result/1`
    (maps `{:ok, card}` through `preload_owners/1`, passes errors through).

**Steps**

- [ ] Add failing schema tests to `test/schemas/card_test.exs` (new describe blocks at the end of the module):

```elixir
  describe "status and progress" do
    test "a new card defaults to :queued with nil progress" do
      card = insert(:card)

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.status == :queued
      assert reloaded.progress == nil
    end

    test "changeset/2 does not cast status or progress" do
      changeset = Card.changeset(%Card{}, %{title: "T", status: "done", progress: 90})

      assert get_field(changeset, :status) == :queued
      assert get_field(changeset, :progress) == nil
    end
  end

  describe "status_changeset/2" do
    test "casts status and progress" do
      changeset = Card.status_changeset(%Card{}, %{status: "working", progress: 40})

      assert changeset.valid?
      assert get_field(changeset, :status) == :working
      assert get_field(changeset, :progress) == 40
    end

    test "rejects an unknown status" do
      changeset = Card.status_changeset(%Card{}, %{status: "sleeping"})

      refute changeset.valid?
      assert "is invalid" in errors_on(changeset).status
    end

    test "rejects progress outside 0..100" do
      for bad <- [-1, 101] do
        changeset = Card.status_changeset(%Card{}, %{status: "working", progress: bad})

        refute changeset.valid?
        assert Map.has_key?(errors_on(changeset), :progress)
      end
    end

    test "allows nil progress" do
      changeset = Card.status_changeset(%Card{}, %{status: "working"})

      assert changeset.valid?
    end
  end
```

- [ ] Run `mix test test/schemas/card_test.exs` — expect failure (no such fields/function).
- [ ] Run `mix ecto.gen.migration add_status_and_progress_to_cards` and fill it:

```elixir
defmodule Relay.Repo.Migrations.AddStatusAndProgressToCards do
  use Ecto.Migration

  def change do
    alter table(:cards) do
      add :status, :string, null: false, default: "queued"
      add :progress, :integer
    end
  end
end
```

- [ ] In `lib/schemas/card.ex`, add to the `schema "cards"` block (after `field :ref_number`):

```elixir
    field :status, Ecto.Enum,
      values: [:queued, :working, :needs_input, :in_review, :done],
      default: :queued

    field :progress, :integer
```

  and add below `changeset/2`:

```elixir
  @doc """
  Changeset for the card's baton state: `:status` (enum) and `:progress`
  (0–100, nullable — just stored and displayed; MMF 06 has no automation).
  Kept separate from `changeset/2` so title/description edits can never
  touch the baton and vice versa.
  """
  def status_changeset(card, attrs) do
    card
    |> cast(attrs, [:status, :progress])
    |> validate_required([:status])
    |> validate_number(:progress, greater_than_or_equal_to: 0, less_than_or_equal_to: 100)
  end
```

- [ ] Run `mix ecto.migrate`, then `mix test test/schemas/card_test.exs` — expect pass.
- [ ] Add failing context tests to `test/relay/cards_test.exs` (new describe block):

```elixir
  describe "set_status/2" do
    test "sets status and progress and preloads owners", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:ok, %Card{} = updated} =
               Cards.set_status(card, %{"status" => "working", "progress" => "40"})

      assert updated.status == :working
      assert updated.progress == 40
      assert updated.owners == []
      assert Repo.get!(Card, card.id).status == :working
    end

    test "returns an error changeset and persists nothing on invalid input", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert {:error, %Ecto.Changeset{}} = Cards.set_status(card, %{"status" => "banana"})

      assert {:error, %Ecto.Changeset{}} =
               Cards.set_status(card, %{"status" => "working", "progress" => "250"})

      reloaded = Repo.get!(Card, card.id)
      assert reloaded.status == :queued
      assert reloaded.progress == nil
    end
  end
```

- [ ] Run `mix test test/relay/cards_test.exs` — expect failure (`set_status/2` undefined).
- [ ] Implement in `lib/relay/cards.ex` — public function after `update_card/2`:

```elixir
  @doc """
  Sets the card's baton status (`:queued | :working | :needs_input |
  :in_review | :done`) and optional `progress` (0–100) from `attrs`,
  returning `{:ok, card}` (owners preloaded) or `{:error, changeset}`.
  Status only ever changes through this explicit call — never as a side
  effect of moving a card.
  """
  def set_status(%Card{} = card, attrs) do
    card
    |> Card.status_changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
  end
```

  and private helpers at the bottom with the other defps:

```elixir
  defp preload_owners_result({:ok, card}), do: {:ok, preload_owners(card)}
  defp preload_owners_result({:error, changeset}), do: {:error, changeset}

  defp preload_owners(nil), do: nil
  defp preload_owners(card_or_cards), do: Repo.preload(card_or_cards, owners: :user)
```

- [ ] Run `mix test test/relay/cards_test.exs test/schemas/card_test.exs` — expect pass.
- [ ] Run `mix precommit` — must pass. Commit.

**Deliverable:** cards carry a persisted status (default `:queued`) and nullable progress,
settable only through `Cards.set_status/2`.
**Commit message:** `feat(cards): card status + progress with set_status/2`

---

### Task 4: Owner management + active-owner derivation + owner preloading everywhere

**Files**

- Modify: `lib/relay/cards.ex`, `test/relay/cards_test.exs`

**Interfaces**

- Consumes: `Schemas.CardOwner` + `CardOwner.changeset/1` (Task 2),
  `Schemas.Card.owners` assoc (Task 2), `preload_owners/1` + `preload_owners_result/1`
  (Task 3, same module), `Cards.set_status/2` (Task 3, already preloads).
- Produces (the web tasks call exactly these):
  - Actor type (documented in the `@moduledoc`): `actor :: :agent | {:user, user_id :: integer}`.
  - `Relay.Cards.set_owners(card :: %Schemas.Card{}, actors :: [actor]) ::
    {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}` — replaces the whole list
    atomically (rolls back on any invalid actor).
  - `Relay.Cards.add_owner(card :: %Schemas.Card{}, actor) ::
    {:ok, %Schemas.Card{}} | {:error, Ecto.Changeset.t()}` — idempotent (adding an
    existing owner is an ok no-op).
  - `Relay.Cards.remove_owner(card :: %Schemas.Card{}, actor) :: {:ok, %Schemas.Card{}}`
    — idempotent.
  - `Relay.Cards.active_owner_type(card_or_map :: %{owners: list()}) :: :ai | :human | nil`
    — `:ai` if the agent is among the owners, `:human` if only humans, `nil` if unowned.
    Accepts any map with a loaded `owners` list (raises FunctionClauseError on a
    not-preloaded struct — loud on purpose). Owner entries expose `actor_type`
    (`:user | :agent`), `user_id`, and (for `:user`) a preloaded `user`.
  - All card-returning `Cards` functions (`create_card/2`, `list_cards/1`,
    `get_card_by_ref/2`, `update_card/2`, `move_card/3`, `set_status/2`, and the three
    owner functions) return cards with `owners: :user` preloaded.

**Steps**

- [ ] Add failing tests to `test/relay/cards_test.exs` (new describe blocks):

```elixir
  describe "owner management" do
    setup %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Owned"})
      %{card: card, user: insert(:user)}
    end

    test "add_owner/2 with {:user, id} adds a human owner with the user preloaded",
         %{card: card, user: user} do
      assert {:ok, %Card{} = updated} = Cards.add_owner(card, {:user, user.id})

      assert [owner] = updated.owners
      assert owner.actor_type == :user
      assert owner.user_id == user.id
      assert owner.user.id == user.id
    end

    test "add_owner/2 with :agent adds the AI owner", %{card: card} do
      assert {:ok, %Card{} = updated} = Cards.add_owner(card, :agent)

      assert [owner] = updated.owners
      assert owner.actor_type == :agent
      assert owner.user_id == nil
    end

    test "add_owner/2 is idempotent", %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, updated} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, :agent)
      {:ok, updated_again} = Cards.add_owner(card, :agent)

      assert length(updated.owners) == 1
      assert length(updated_again.owners) == 2
    end

    test "add_owner/2 returns an error changeset for an unknown user id", %{card: card} do
      assert {:error, %Ecto.Changeset{}} = Cards.add_owner(card, {:user, -1})
      assert {:ok, %Card{owners: []}} = Cards.set_owners(card, [])
    end

    test "remove_owner/2 removes only the matching actor and is idempotent",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, %Card{} = updated} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = updated.owners

      assert {:ok, %Card{} = again} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = again.owners

      assert {:ok, %Card{owners: []}} = Cards.remove_owner(card, {:user, user.id})
    end

    test "set_owners/2 replaces the owner list atomically", %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      assert {:ok, %Card{} = updated} = Cards.set_owners(card, [{:user, user.id}])

      assert [owner] = updated.owners
      assert owner.actor_type == :user
      assert owner.user_id == user.id
    end

    test "set_owners/2 rolls back on an invalid actor, keeping existing owners",
         %{card: card, user: user} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      assert {:error, %Ecto.Changeset{}} = Cards.set_owners(card, [:agent, {:user, -1}])

      assert {:ok, %Card{} = reloaded} = Cards.remove_owner(card, :agent)
      assert [%{actor_type: :user}] = reloaded.owners
    end
  end

  describe "active_owner_type/1" do
    setup %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "Baton"})
      %{card: card, user: insert(:user)}
    end

    test "returns nil for an unowned card", %{card: card} do
      assert Cards.active_owner_type(card) == nil
    end

    test "returns :human when only user owners", %{card: card, user: user} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})

      assert Cards.active_owner_type(card) == :human
    end

    test "returns :ai when the agent is among the owners, even with humans",
         %{card: card, user: user} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})
      {:ok, card} = Cards.add_owner(card, :agent)

      assert Cards.active_owner_type(card) == :ai
    end
  end

  describe "owner preloading" do
    test "every card-returning function preloads owners", %{board: board, stage: stage} do
      {:ok, created} = Cards.create_card(stage, %{title: "Preloaded"})
      assert created.owners == []

      assert [%Card{owners: []}] = Cards.list_cards(board)
      assert %Card{owners: []} = Cards.get_card_by_ref(board, "RLY-1")

      {:ok, updated} = Cards.update_card(created, %{title: "Still preloaded"})
      assert updated.owners == []

      target = insert(:stage, board: board, position: 2)
      {:ok, moved} = Cards.move_card(created, target, 0)
      assert moved.owners == []
    end
  end
```

- [ ] Run `mix test test/relay/cards_test.exs` — expect failures (functions undefined; preload assertions fail with `%Ecto.Association.NotLoaded{}`).
- [ ] Implement in `lib/relay/cards.ex`. Add `alias Schemas.CardOwner` to the alias block. Extend the `@moduledoc` with a sentence: `An "actor" is either the single Relay AI agent (:agent) or a user ({:user, user_id}) — the same concept later reused for comments (MMF 07) and API attribution (MMF 09).` Add the public functions (after `set_status/2`):

```elixir
  @doc """
  Replaces the card's whole owner list with `actors`
  (`:agent | {:user, user_id}`) atomically, returning `{:ok, card}` with
  owners preloaded or `{:error, changeset}` (nothing changes on error).
  """
  def set_owners(%Card{} = card, actors) when is_list(actors) do
    Repo.transaction(fn ->
      Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id)

      Enum.each(actors, fn actor ->
        case insert_owner(card, actor) do
          {:ok, _owner} -> :ok
          {:error, changeset} -> Repo.rollback(changeset)
        end
      end)

      reload_with_owners(card)
    end)
  end

  @doc """
  Adds one owner actor to the card, returning `{:ok, card}` with owners
  preloaded. Adding an actor that is already an owner is an ok no-op.
  """
  def add_owner(%Card{} = card, actor) do
    case insert_owner(card, actor) do
      {:ok, _owner} -> {:ok, reload_with_owners(card)}
      {:error, changeset} -> {:error, changeset}
    end
  end

  @doc """
  Removes one owner actor from the card, returning `{:ok, card}` with
  owners preloaded. Removing an actor that is not an owner is an ok no-op.
  """
  def remove_owner(%Card{} = card, actor) do
    Repo.delete_all(owner_query(card, actor))
    {:ok, reload_with_owners(card)}
  end

  @doc """
  Derives who holds the baton from the (preloaded) owner list: `:ai` when
  the agent is among the owners (human owners render paused), `:human`
  when only humans own it, `nil` when unowned. Never stored — always
  derived. Accepts any map with a loaded `owners` list so components can
  use it on plain maps too.
  """
  def active_owner_type(%{owners: owners}) when is_list(owners) do
    cond do
      Enum.any?(owners, &(&1.actor_type == :agent)) -> :ai
      owners != [] -> :human
      true -> nil
    end
  end
```

  and the private helpers (near the other defps):

```elixir
  defp insert_owner(%Card{} = card, :agent) do
    %CardOwner{card_id: card.id, actor_type: :agent}
    |> CardOwner.changeset()
    |> Repo.insert(on_conflict: :nothing)
  end

  defp insert_owner(%Card{} = card, {:user, user_id}) when is_integer(user_id) do
    %CardOwner{card_id: card.id, actor_type: :user, user_id: user_id}
    |> CardOwner.changeset()
    |> Repo.insert(on_conflict: :nothing)
  end

  defp owner_query(%Card{} = card, :agent) do
    from o in CardOwner, where: o.card_id == ^card.id and o.actor_type == ^:agent
  end

  defp owner_query(%Card{} = card, {:user, user_id}) do
    from o in CardOwner,
      where: o.card_id == ^card.id and o.actor_type == ^:user and o.user_id == ^user_id
  end

  defp reload_with_owners(%Card{} = card) do
    Card |> Repo.get!(card.id) |> Repo.preload(owners: :user)
  end
```

- [ ] Thread the preload through the existing functions in `lib/relay/cards.ex`:
  - `create_card/2`: inside the transaction fun, change `{:ok, card} -> card` to `{:ok, card} -> preload_owners(card)`.
  - `list_cards/1`: add the preload to the query:

```elixir
  def list_cards(%Board{id: board_id}) do
    Repo.all(
      from c in Card,
        where: c.board_id == ^board_id,
        order_by: [asc: c.stage_id, asc: c.position, asc: c.id],
        preload: [owners: :user]
    )
  end
```

  - `get_card_by_ref/2`: pipe the fetched card through `preload_owners/1` (it is nil-safe):

```elixir
      {:ok, ref_number} ->
        Card
        |> Repo.get_by(board_id: board.id, ref_number: ref_number)
        |> preload_owners()
```

  - `update_card/2`: append `|> preload_owners_result()` after `|> Repo.update()`.
  - `move_card/3`: change `moved = place_at(card, target_stage, index)` to `moved = preload_owners(place_at(card, target_stage, index))`.
- [ ] Run `mix test test/relay/cards_test.exs` — expect pass.
- [ ] Run `mix precommit` — must pass (full suite: existing LiveView tests must be unaffected). Commit.

**Deliverable:** complete owner lifecycle in `Relay.Cards` — settable owner list,
derived active owner, owners always preloaded — with the move path untouched (moving never
changes owners/status).
**Commit message:** `feat(cards): owner management + active-owner derivation`

---

### Task 5: Components — `status_badge/1` + the `board_card/1` colour system

Pure component work with component tests and storybook stories. No LiveView wiring yet
(that's Task 6), so nothing on the live board changes appearance except the new neutral
`border-l-4 border-l-transparent` base on every card.

**Files**

- Modify: `lib/relay_web/components/core_components.ex`,
  `test/relay_web/components/core_components_test.exs`,
  `storybook/core_components/board_card.story.exs`
- Create: `storybook/core_components/status_badge.story.exs`

**Interfaces**

- Consumes: theme tokens (primary/secondary/warning/success/error) from
  `assets/css/app.css`; existing `owner_pill/1` (values `:human | :ai`, accepts `class`).
- Produces:
  - `RelayWeb.CoreComponents.status_badge/1` — attrs: `status :: :queued | :working |
    :needs_input | :in_review | :done` (required), `progress :: integer | nil`
    (default nil), `class :: any` (default nil). Renders
    `span.status-badge[data-status=<status>]` with labels/classes:
    queued → "queued"/`badge-ghost`, working → "working" or "working·N%"/`badge-secondary`,
    needs_input → "NEEDS INPUT"/`badge-warning`, in_review → "in review"/`badge-primary`,
    done → "done"/`badge-success`.
  - `board_card/1` new optional attrs (all default nil, so existing call sites keep
    working): `active_owner :: :human | :ai | nil`, `stage_owner :: :human | :ai | nil`,
    `status`, `progress`. Renders: left border (`border-l-4` + `border-l-primary` human /
    `border-l-secondary` AI / `border-l-error` mismatch / `border-l-transparent` neutral),
    a `data-active-owner` attr, `.card-owner-pill` (an `owner_pill`), the `status_badge`,
    and `.card-mismatch` red warning text — "This stage is meant to be used by agents"
    (human-active in AI stage) / "This stage is meant for humans" (AI-active in human
    stage). Mismatch is display-only and only when BOTH `active_owner` and `stage_owner`
    are non-nil and conflict.

**Steps**

- [ ] Add failing tests to `test/relay_web/components/core_components_test.exs` (new describe blocks before the final `end`):

```elixir
  describe "status_badge/1" do
    test "renders each status with its colour token and label" do
      for {status, class, label} <- [
            {:queued, "badge-ghost", "queued"},
            {:working, "badge-secondary", "working"},
            {:needs_input, "badge-warning", "NEEDS INPUT"},
            {:in_review, "badge-primary", "in review"},
            {:done, "badge-success", "done"}
          ] do
        html = render_component(&CoreComponents.status_badge/1, status: status)

        assert html =~ class
        assert html =~ label
        assert html =~ ~s(data-status="#{status}")
      end
    end

    test "working includes the progress percentage when present" do
      html = render_component(&CoreComponents.status_badge/1, status: :working, progress: 61)

      assert html =~ "working·61%"
    end

    test "working without progress shows no percentage" do
      html = render_component(&CoreComponents.status_badge/1, status: :working)

      refute html =~ "%"
    end
  end

  describe "board_card/1 baton treatments" do
    test "renders neutral without active owner or status" do
      html = render_component(&CoreComponents.board_card/1, id: "c1", ref: "RLY-1", title: "T")

      assert html =~ "border-l-transparent"
      refute html =~ "card-owner-pill"
      refute html =~ "status-badge"
      refute html =~ "card-mismatch"
    end

    test "human active renders the blue border and Human pill" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c2",
          ref: "RLY-2",
          title: "T",
          active_owner: :human,
          stage_owner: :human,
          status: :queued
        )

      assert html =~ "border-l-primary"
      assert html =~ ~s(data-active-owner="human")
      assert html =~ "card-owner-pill"
      assert html =~ "badge-primary"
      refute html =~ "card-mismatch"
    end

    test "AI active renders the violet border, AI pill, and working progress" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c3",
          ref: "RLY-3",
          title: "T",
          active_owner: :ai,
          stage_owner: :ai,
          status: :working,
          progress: 61
        )

      assert html =~ "border-l-secondary"
      assert html =~ ~s(data-active-owner="ai")
      assert html =~ "badge-secondary"
      assert html =~ "working·61%"
      refute html =~ "card-mismatch"
    end

    test "a human-active card in an AI stage warns it is meant for agents" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c4",
          ref: "RLY-4",
          title: "T",
          active_owner: :human,
          stage_owner: :ai,
          status: :queued
        )

      assert html =~ "border-l-error"
      assert html =~ "card-mismatch"
      assert html =~ "This stage is meant to be used by agents"
    end

    test "an AI-active card in a human stage warns it is meant for humans" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c5",
          ref: "RLY-5",
          title: "T",
          active_owner: :ai,
          stage_owner: :human,
          status: :queued
        )

      assert html =~ "border-l-error"
      assert html =~ "This stage is meant for humans"
    end

    test "no mismatch without an active owner, even in an AI stage" do
      html =
        render_component(&CoreComponents.board_card/1,
          id: "c6",
          ref: "RLY-6",
          title: "T",
          stage_owner: :ai
        )

      refute html =~ "card-mismatch"
      assert html =~ "border-l-transparent"
    end
  end
```

- [ ] Run `mix test test/relay_web/components/core_components_test.exs` — expect failure.
- [ ] In `lib/relay_web/components/core_components.ex`, add `status_badge/1` right after `owner_pill/1`:

```elixir
  @doc """
  Renders a card's status badge — the baton state at a glance.

  `working` appends the stored progress percentage when present
  (`working·61%`); `needs_input` renders the amber NEEDS INPUT treatment;
  `done` is green; `in_review` blue; `queued` neutral.

  ## Examples

      <.status_badge status={:working} progress={61} />
      <.status_badge status={:needs_input} />
  """
  attr :status, :atom,
    values: [:queued, :working, :needs_input, :in_review, :done],
    required: true

  attr :progress, :integer, default: nil
  attr :class, :any, default: nil

  def status_badge(assigns) do
    ~H"""
    <span
      class={["status-badge badge badge-sm font-medium", status_badge_class(@status), @class]}
      data-status={@status}
    >
      {status_badge_label(@status, @progress)}
    </span>
    """
  end

  defp status_badge_class(:queued), do: "badge-ghost"
  defp status_badge_class(:working), do: "badge-secondary"
  defp status_badge_class(:needs_input), do: "badge-warning"
  defp status_badge_class(:in_review), do: "badge-primary"
  defp status_badge_class(:done), do: "badge-success"

  defp status_badge_label(:working, progress) when is_integer(progress), do: "working·#{progress}%"
  defp status_badge_label(:queued, _progress), do: "queued"
  defp status_badge_label(:working, _progress), do: "working"
  defp status_badge_label(:needs_input, _progress), do: "NEEDS INPUT"
  defp status_badge_label(:in_review, _progress), do: "in review"
  defp status_badge_label(:done, _progress), do: "done"
```

- [ ] Replace `board_card/1` (its `@doc`, attrs, and function) with:

```elixir
  @doc """
  Renders a single kanban card: its title, optional #tag, its board-scoped
  ref (e.g. RLY-3), and — the heart of Relay — its baton state: the
  active-owner colour (blue human / violet AI left border + owner pill),
  the status badge (`working·61%`, amber NEEDS INPUT, green done, …), and
  the red mismatch warning when the card's active-owner type conflicts
  with the stage it sits in (`stage_owner`, the stage's "meant for"
  designation). Mismatch is display-only — it never mutates the card.

  Clicking the card emits a `"select_card"` event (with `phx-value-ref`)
  for the parent LiveView — `RelayWeb.BoardLive` answers with a patch to
  `?card=<ref>`, opening the card drawer.

  The card is natively draggable (draggable="true" + data-ref) — the
  board-level BoardDnD hook turns drops into "move_card" events.

  ## Examples

      <.board_card id="cards-1" ref="RLY-3" title="Ship MMF 03" tag="infra" />
      <.board_card
        id="cards-2"
        ref="RLY-4"
        title="Migrate the posts"
        active_owner={:ai}
        stage_owner={:ai}
        status={:working}
        progress={61}
      />
  """
  attr :id, :string, required: true
  attr :ref, :string, required: true, doc: "the human-facing ref, e.g. RLY-3"
  attr :title, :string, required: true
  attr :tag, :string, default: nil

  attr :active_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "who holds the baton, derived from the owner list; nil when unowned"

  attr :stage_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "the stage's \"meant for\" designation, for the mismatch warning"

  attr :status, :atom,
    values: [:queued, :working, :needs_input, :in_review, :done, nil],
    default: nil

  attr :progress, :integer, default: nil

  def board_card(assigns) do
    assigns = assign(assigns, :mismatch, mismatch(assigns.active_owner, assigns.stage_owner))

    ~H"""
    <article
      id={@id}
      class={[
        "board-card card cursor-pointer bg-base-100 shadow-sm transition-shadow hover:shadow-md",
        "border-l-4",
        card_border_class(@mismatch, @active_owner)
      ]}
      role="button"
      tabindex="0"
      draggable="true"
      data-ref={@ref}
      data-active-owner={@active_owner}
      phx-click="select_card"
      phx-value-ref={@ref}
    >
      <div class="card-body gap-2 p-3">
        <p class="card-title text-sm font-medium leading-snug">{@title}</p>
        <p :if={@mismatch} class="card-mismatch text-xs font-medium text-error">
          {mismatch_message(@mismatch)}
        </p>
        <div class="flex flex-wrap items-center gap-2">
          <.status_badge :if={@status} status={@status} progress={@progress} />
          <.owner_pill :if={@active_owner} owner={@active_owner} class="card-owner-pill" />
          <span :if={@tag} class="card-tag badge badge-ghost badge-sm">#{@tag}</span>
          <span class="card-ref ml-auto font-mono text-xs text-base-content/60">{@ref}</span>
        </div>
      </div>
    </article>
    """
  end

  defp mismatch(nil, _stage_owner), do: nil
  defp mismatch(_active_owner, nil), do: nil
  defp mismatch(:human, :ai), do: :meant_for_agents
  defp mismatch(:ai, :human), do: :meant_for_humans
  defp mismatch(_active_owner, _stage_owner), do: nil

  defp mismatch_message(:meant_for_agents), do: "This stage is meant to be used by agents"
  defp mismatch_message(:meant_for_humans), do: "This stage is meant for humans"

  defp card_border_class(mismatch, _active_owner) when not is_nil(mismatch), do: "border-l-error"
  defp card_border_class(nil, :ai), do: "border-l-secondary"
  defp card_border_class(nil, :human), do: "border-l-primary"
  defp card_border_class(nil, nil), do: "border-l-transparent"
```

- [ ] Run `mix test test/relay_web/components/core_components_test.exs` — expect pass.
- [ ] Refresh `storybook/core_components/board_card.story.exs` — replace the `variations/0` list with:

```elixir
  def variations do
    [
      %Variation{
        id: :unowned,
        attributes: %{id: "story-card-1", ref: "RLY-1", title: "Wire up Google sign-in"}
      },
      %Variation{
        id: :human_active,
        attributes: %{
          id: "story-card-2",
          ref: "RLY-2",
          title: "Draft the onboarding spec",
          tag: "spec",
          active_owner: :human,
          stage_owner: :human,
          status: :queued
        }
      },
      %Variation{
        id: :ai_working,
        attributes: %{
          id: "story-card-3",
          ref: "RLY-3",
          title: "Migrate 40 blog posts",
          active_owner: :ai,
          stage_owner: :ai,
          status: :working,
          progress: 61
        }
      },
      %Variation{
        id: :needs_input,
        attributes: %{
          id: "story-card-4",
          ref: "RLY-4",
          title: "Pick the target locale list",
          active_owner: :ai,
          stage_owner: :ai,
          status: :needs_input
        }
      },
      %Variation{
        id: :mismatch_meant_for_agents,
        attributes: %{
          id: "story-card-5",
          ref: "RLY-5",
          title: "Human card parked in Code",
          active_owner: :human,
          stage_owner: :ai,
          status: :queued
        }
      },
      %Variation{
        id: :mismatch_meant_for_humans,
        attributes: %{
          id: "story-card-6",
          ref: "RLY-6",
          title: "AI card parked in Review",
          active_owner: :ai,
          stage_owner: :human,
          status: :working,
          progress: 20
        }
      },
      %Variation{
        id: :done,
        attributes: %{
          id: "story-card-7",
          ref: "RLY-7",
          title: "Ship the landing page",
          active_owner: :human,
          stage_owner: :human,
          status: :done
        }
      }
    ]
  end
```

- [ ] Create `storybook/core_components/status_badge.story.exs`:

```elixir
defmodule Storybook.Components.CoreComponents.StatusBadge do
  @moduledoc false
  use PhoenixStorybook.Story, :component

  def function, do: &RelayWeb.CoreComponents.status_badge/1
  def render_source, do: :function

  def variations do
    [
      %Variation{id: :queued, attributes: %{status: :queued}},
      %Variation{id: :working, attributes: %{status: :working}},
      %Variation{id: :working_with_progress, attributes: %{status: :working, progress: 61}},
      %Variation{id: :needs_input, attributes: %{status: :needs_input}},
      %Variation{id: :in_review, attributes: %{status: :in_review}},
      %Variation{id: :done, attributes: %{status: :done}}
    ]
  end
end
```

- [ ] Run `mix precommit` — must pass. Commit.

**Deliverable:** the full card colour system as pure, tested components, browsable at
`/storybook/core_components/board_card` and `/storybook/core_components/status_badge`
(mention both links when reporting this task).
**Commit message:** `feat(ui): board card baton colour system + status badge`

---

### Task 6: Board integration — stage columns feed the baton into every card

Wire `stage_column` to derive each card's active owner and pass status/stage-owner through
to `board_card`. After this task the live board shows the whole colour system.

**Files**

- Modify: `lib/relay_web/components/core_components.ex` (stage_column only),
  `test/relay_web/components/core_components_test.exs` (stage_column card maps),
  `storybook/core_components/stage_column.story.exs`,
  `test/relay_web/live/board_live_test.exs` (new describe block)

**Interfaces**

- Consumes: `Relay.Cards.active_owner_type/1` (Task 4 — accepts any map with a loaded
  `owners` list), `board_card/1` attrs `active_owner` / `stage_owner` / `status` /
  `progress` (Task 5), `Cards.add_owner/2`, `Cards.set_status/2`, `Cards.move_card/3`,
  `Cards.get_card_by_ref/2` (Tasks 3–4). Cards in streams already arrive with owners
  preloaded (Task 4) — no `BoardLive` module changes are needed in this task.
- Produces: `stage_column/1`'s `cards` entries must now expose `status`, `progress`, and a
  loaded `owners` list in addition to `title`, `tag`, `ref_number` (documented in the
  component `@doc`). Task 7 relies on the board card selectors:
  `.board-card[data-active-owner=...]`, `.status-badge[data-status=...]`, `.card-mismatch`.

**Steps**

- [ ] Add a failing LiveView test block to `test/relay_web/live/board_live_test.exs` (new describe after "drag-and-drop wiring"):

```elixir
  describe "baton rendering on the board" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, _spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton card"})
      %{board: board, backlog: backlog, plan: plan, card: card}
    end

    test "an unowned card renders neutral: queued badge, no pill, no mismatch", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .status-badge[data-status='queued']",
               "queued"
             )

      refute has_element?(view, "#stage-col-1-cards .board-card .card-owner-pill")
      refute has_element?(view, "#stage-col-1-cards .board-card .card-mismatch")
    end

    test "an unowned card in an AI stage shows no mismatch", %{conn: conn, plan: plan} do
      {:ok, _card} = Cards.create_card(plan, %{title: "Unowned in Plan"})

      {:ok, view, _html} = live(conn, ~p"/board")

      refute has_element?(view, "#stage-col-3-cards .board-card .card-mismatch")
    end

    test "a human-owned card renders blue with the Human pill",
         %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card[data-active-owner='human'].border-l-primary"
             )

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .card-owner-pill.badge-primary",
               "Human"
             )
    end

    test "adding the agent as an owner flips the card to violet AI",
         %{conn: conn, user: user, card: card} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _card} = Cards.add_owner(card, :agent)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card[data-active-owner='ai'].border-l-secondary"
             )

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .card-owner-pill.badge-secondary",
               "AI"
             )
    end

    test "a needs_input card shows the amber NEEDS INPUT badge", %{conn: conn, card: card} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "needs_input"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .status-badge.badge-warning[data-status='needs_input']",
               "NEEDS INPUT"
             )
    end

    test "a working card shows its progress on the badge", %{conn: conn, card: card} do
      {:ok, _card} = Cards.set_status(card, %{"status" => "working", "progress" => "61"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .status-badge[data-status='working']",
               "working·61%"
             )
    end

    test "a human-active card in an AI stage shows the red meant-for-agents warning",
         %{conn: conn, user: user, card: card, plan: plan} do
      {:ok, card} = Cards.add_owner(card, {:user, user.id})
      {:ok, _moved} = Cards.move_card(card, plan, 0)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card.border-l-error .card-mismatch",
               "meant to be used by agents"
             )
    end

    test "an AI-active card in a human stage shows the red meant-for-humans warning",
         %{conn: conn, card: card} do
      {:ok, _card} = Cards.add_owner(card, :agent)

      {:ok, view, _html} = live(conn, ~p"/board")

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card.border-l-error .card-mismatch",
               "meant for humans"
             )
    end

    test "moving a card changes neither its owners nor its status",
         %{conn: conn, board: board, user: user, card: card, plan: plan} do
      {:ok, _card} = Cards.add_owner(card, {:user, user.id})

      {:ok, view, _html} = live(conn, ~p"/board")

      render_hook(view, "move_card", %{"ref" => "RLY-1", "stage_id" => plan.id, "index" => 0})

      moved = Cards.get_card_by_ref(board, "RLY-1")
      assert moved.stage_id == plan.id
      assert moved.status == :queued
      assert [%{actor_type: :user}] = moved.owners

      assert has_element?(
               view,
               "#stage-col-3-cards .board-card.border-l-error .card-mismatch",
               "meant to be used by agents"
             )
    end
  end
```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect failures (board cards render no baton markup yet).
- [ ] In `lib/relay_web/components/core_components.ex`: add `alias Relay.Cards` to the alias block at the top, update the `stage_column/1` `@doc` sentence about cards to say each card needs `title`, `tag`, `ref_number`, `status`, `progress`, and a loaded `owners` list, and change the `<.board_card ...>` call inside `stage_column/1` to:

```heex
        <.board_card
          :for={{dom_id, card} <- @cards}
          id={dom_id}
          title={card.title}
          tag={card.tag}
          ref={"#{@board_key}-#{card.ref_number}"}
          status={card.status}
          progress={card.progress}
          active_owner={Cards.active_owner_type(card)}
          stage_owner={@owner}
        />
```

- [ ] Update the two card maps in the "renders its cards with refs derived from the board key" test in `test/relay_web/components/core_components_test.exs`:

```elixir
          cards: [
            {"cards-1",
             %{title: "First card", tag: "infra", ref_number: 1, status: :queued, progress: nil, owners: []}},
            {"cards-2",
             %{title: "Second card", tag: nil, ref_number: 2, status: :working, progress: 40, owners: [%{actor_type: :agent}]}}
          ]
```

  and extend that test's assertions with:

```elixir
      assert html =~ ~s(data-active-owner="ai")
      assert html =~ "working·40%"
```

- [ ] Update the `:with_cards` variation in `storybook/core_components/stage_column.story.exs`:

```elixir
          cards: [
            {"story-card-1",
             %{
               title: "Wire up Google sign-in",
               tag: "auth",
               ref_number: 1,
               status: :working,
               progress: 61,
               owners: [%{actor_type: :agent}]
             }},
            {"story-card-2",
             %{
               title: "Render the stage columns",
               tag: nil,
               ref_number: 2,
               status: :queued,
               progress: nil,
               owners: []
             }}
          ]
```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs test/relay_web/components/core_components_test.exs` — expect pass.
- [ ] Run `mix precommit` — must pass. Commit.

**Deliverable:** the live board shows each card's active-owner colour + pill, status badge
(amber NEEDS INPUT, `working·N%`, green done), and the red mismatch warning in both
directions — and a move changes neither owners nor status. Stage column story refreshed at
`/storybook/core_components/stage_column` (mention the link when reporting this task).
**Commit message:** `feat(board): render active owner, status, and mismatch on board cards`

---

### Task 7: Drawer baton rail — ACTIVE WORKER, owners (paused), status + owner controls

**Files**

- Modify: `lib/relay_web/components/core_components.ex` (card_drawer),
  `lib/relay_web/live/board_live.ex`,
  `test/relay_web/live/board_live_test.exs` (new describe block + one alias),
  `storybook/core_components/card_drawer.story.exs`

**Interfaces**

- Consumes: `Cards.set_status/2`, `Cards.add_owner/2`, `Cards.remove_owner/2`,
  `Cards.active_owner_type/1` (Tasks 3–4); `owner_pill/1`; board selectors from Task 6;
  `BoardLive`'s existing `parse_int/1` and `stream_name/1` helpers.
- Produces:
  - `card_drawer/1` new attrs: `active_owner :: :human | :ai | nil` (default nil),
    `status_form` (required, a `to_form/2` form for `card[status]` + `card[progress]`),
    `current_user_id :: integer | nil` (default nil). The `card` attr must now also expose
    `status`, `progress`, and a loaded `owners` list (each owner exposing `id`,
    `actor_type`, `user_id`, and for `:user` a loaded `user` with `name`/`email`).
  - Drawer DOM contract (used by tests): `#card-drawer-rail .rail-active-worker`,
    `.rail-owners`, `.rail-owner[data-actor-type=...]`, `.rail-owner-paused`,
    `#card-drawer-assign-ai`, `#card-drawer-add-me`, `#card-drawer-remove-owner-agent`,
    `#card-drawer-remove-owner-user-<user_id>`, `#card-drawer-status-form` with inputs
    `card[status]` (select) and `card[progress]` (number, rendered only while the card's
    status is `:working`).
  - LiveView events handled by `BoardLive`: `"set_card_status"` (form params
    `%{"card" => %{"status" => ..., "progress" => ...}}`), `"add_owner"` and
    `"remove_owner"` (params `%{"actor_type" => "agent"}` or
    `%{"actor_type" => "user", "user_id" => id}`). Adding a `:user` owner is restricted to
    the current user (MVP boards are single-human; members arrive in MMF 17); anything
    unresolvable is a silent no-op.

**Steps**

- [ ] Add `alias Schemas.CardOwner` to the alias block of `test/relay_web/live/board_live_test.exs`, then add the failing describe block (after "drawer move menu"):

```elixir
  describe "drawer baton rail" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton"})
      %{board: board, backlog: backlog, card: card}
    end

    test "an unowned card shows None for active worker and owners, with both add controls",
         %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
      assert has_element?(view, "#card-drawer-rail .rail-owners", "None")
      assert has_element?(view, "#card-drawer-assign-ai")
      assert has_element?(view, "#card-drawer-add-me")
    end

    test "Add me makes the current user the active worker and reflects on the board card",
         %{conn: conn, user: user, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-primary",
               "Human"
             )

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "Test User")

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user']",
               "Test User"
             )

      refute has_element?(view, "#card-drawer-add-me")

      assert [owner] = Repo.all(CardOwner)
      assert owner.card_id == card.id
      assert owner.user_id == user.id

      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='human']")
    end

    test "Assign AI flips the active worker to AI and pauses the human", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-assign-ai") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-secondary",
               "AI"
             )

      assert has_element?(
               view,
               "#card-drawer-rail .rail-owner[data-actor-type='user'] .rail-owner-paused",
               "paused"
             )

      refute has_element?(view, "#card-drawer-assign-ai")
      assert has_element?(view, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "releasing the AI returns the baton to the human", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-assign-ai") |> render_click()
      view |> element("#card-drawer-remove-owner-agent") |> render_click()

      assert has_element?(
               view,
               "#card-drawer-rail .rail-active-worker .owner-pill.badge-primary",
               "Human"
             )

      refute has_element?(view, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      assert has_element?(view, "#card-drawer-assign-ai")
      refute has_element?(view, "#card-drawer-rail .rail-owner-paused")
    end

    test "removing the human owner leaves the card unowned", %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-remove-owner-user-#{user.id}") |> render_click()

      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
      assert Repo.all(CardOwner) == []
      refute has_element?(view, "#stage-col-1-cards .board-card[data-active-owner]")
    end

    test "setting status from the drawer persists and updates the board card",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view |> form("#card-drawer-status-form", card: %{status: "needs_input"}) |> render_change()

      assert Repo.get!(Card, card.id).status == :needs_input

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .status-badge[data-status='needs_input']",
               "NEEDS INPUT"
             )
    end

    test "working reveals the progress input; progress shows on the board badge",
         %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      refute has_element?(view, "#card-drawer-status-form input[name='card[progress]']")

      view |> form("#card-drawer-status-form", card: %{status: "working"}) |> render_change()

      assert has_element?(view, "#card-drawer-status-form input[name='card[progress]']")

      view
      |> form("#card-drawer-status-form", card: %{status: "working", progress: "61"})
      |> render_change()

      assert Repo.get!(Card, card.id).progress == 61

      assert has_element?(
               view,
               "#stage-col-1-cards .board-card .status-badge[data-status='working']",
               "working·61%"
             )
    end

    test "an invalid status payload changes nothing", %{conn: conn, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> element("#card-drawer-status-form")
      |> render_change(%{"card" => %{"status" => "banana"}})

      assert Repo.get!(Card, card.id).status == :queued
    end

    test "adding another user's id as owner is ignored", %{conn: conn} do
      other = insert(:user)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      render_click(view, "add_owner", %{"actor_type" => "user", "user_id" => other.id})

      assert Repo.all(CardOwner) == []
      assert has_element?(view, "#card-drawer-rail .rail-active-worker", "None")
    end
  end
```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect failure (no rail markup, no events, no `status_form` assign).
- [ ] Extend `card_drawer/1` in `lib/relay_web/components/core_components.ex`. Add the new attrs after `attr :stage_owner ...`:

```elixir
  attr :active_owner, :atom,
    values: [:human, :ai, nil],
    default: nil,
    doc: "who holds the baton, derived from the card's owner list"

  attr :status_form, :any,
    required: true,
    doc: "a Phoenix.HTML.Form for card[status] + card[progress]"

  attr :current_user_id, :integer,
    default: nil,
    doc: "the signed-in user's id, for the Add me owner control"
```

  update the `card` attr doc to `"a card exposing title, description, tag, status, progress, a loaded owners list, inserted_at, and updated_at"`, extend the `@doc`'s events paragraph with the three new events (`"set_card_status"` form params `card[status]`/`card[progress]`; `"add_owner"` / `"remove_owner"` with phx-value `actor_type` + `user_id`), and insert the baton rail rows into the `<dl id={"#{@id}-rail"} ...>` block BEFORE the existing `Stage` `<dt>`:

```heex
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Active worker
            </dt>
            <dd class="rail-active-worker flex items-center gap-2">
              <%= if @active_owner do %>
                <.owner_pill owner={@active_owner} />
                <span class="rail-active-worker-name text-sm">
                  {active_worker_names(@card, @active_owner)}
                </span>
              <% else %>
                <span class="text-base-content/50">None</span>
              <% end %>
            </dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Owners
            </dt>
            <dd class="rail-owners space-y-2">
              <div
                :for={owner <- @card.owners}
                class="rail-owner flex items-center gap-2"
                data-actor-type={owner.actor_type}
              >
                <span class="text-sm">{owner_name(owner)}</span>
                <span
                  :if={paused_owner?(owner, @active_owner)}
                  class="rail-owner-paused badge badge-ghost badge-xs"
                >
                  paused
                </span>
                <button
                  type="button"
                  id={"#{@id}-remove-owner-#{owner_dom_suffix(owner)}"}
                  class="btn btn-ghost btn-xs btn-square"
                  phx-click="remove_owner"
                  phx-value-actor_type={owner.actor_type}
                  phx-value-user_id={owner.user_id}
                  aria-label={"Remove #{owner_name(owner)} as owner"}
                >
                  <.icon name="hero-x-mark" class="size-3" />
                </button>
              </div>
              <span :if={@card.owners == []} class="text-base-content/50">None</span>
              <div class="flex flex-wrap gap-2">
                <button
                  :if={!agent_owner?(@card)}
                  type="button"
                  id={"#{@id}-assign-ai"}
                  class="btn btn-ghost btn-xs"
                  phx-click="add_owner"
                  phx-value-actor_type="agent"
                >
                  Assign AI
                </button>
                <button
                  :if={@current_user_id && !user_owner?(@card, @current_user_id)}
                  type="button"
                  id={"#{@id}-add-me"}
                  class="btn btn-ghost btn-xs"
                  phx-click="add_owner"
                  phx-value-actor_type="user"
                  phx-value-user_id={@current_user_id}
                >
                  Add me
                </button>
              </div>
            </dd>
            <dt class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
              Status
            </dt>
            <dd class="rail-status">
              <.form for={@status_form} id={"#{@id}-status-form"} phx-change="set_card_status">
                <.input
                  field={@status_form[:status]}
                  type="select"
                  options={status_options()}
                  class="select select-sm w-full"
                />
                <.input
                  :if={@card.status == :working}
                  field={@status_form[:progress]}
                  type="number"
                  min="0"
                  max="100"
                  placeholder="Progress %"
                  class="input input-sm w-full"
                />
              </.form>
            </dd>
```

  and add the private helpers near the module's other defps:

```elixir
  defp status_options do
    [
      {"Queued", "queued"},
      {"Working", "working"},
      {"Needs input", "needs_input"},
      {"In review", "in_review"},
      {"Done", "done"}
    ]
  end

  defp owner_name(%{actor_type: :agent}), do: "AI Agent"
  defp owner_name(%{actor_type: :user, user: user}), do: user.name || user.email

  defp active_worker_names(_card, :ai), do: "AI Agent"

  defp active_worker_names(card, :human) do
    card.owners
    |> Enum.filter(&(&1.actor_type == :user))
    |> Enum.map_join(", ", &owner_name/1)
  end

  defp paused_owner?(owner, active_owner), do: active_owner == :ai and owner.actor_type == :user

  defp agent_owner?(card), do: Enum.any?(card.owners, &(&1.actor_type == :agent))

  defp user_owner?(card, user_id) do
    Enum.any?(card.owners, &(&1.actor_type == :user and &1.user_id == user_id))
  end

  defp owner_dom_suffix(%{actor_type: :agent}), do: "agent"
  defp owner_dom_suffix(%{actor_type: :user, user_id: user_id}), do: "user-#{user_id}"
```

- [ ] Wire `RelayWeb.BoardLive` (`lib/relay_web/live/board_live.ex`):
  1. In `render/1`, add to the `<.card_drawer ...>` call (alongside the existing attrs):

```heex
        active_owner={Cards.active_owner_type(@selected_card)}
        status_form={@status_form}
        current_user_id={@current_scope.user.id}
```

  2. In `assign_selected_card/2`, add `|> assign(:status_form, status_form(card))` to the `%Card{}` branch and `status_form: nil` to the nil-branch keyword list.
  3. Add the event handlers (after the `"save_card_description"` clauses):

```elixir
  def handle_event("set_card_status", %{"card" => card_params}, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case Cards.set_status(card, card_params) do
      {:ok, card} ->
        {:noreply, refresh_card(socket, card)}

      {:error, changeset} ->
        {:noreply, assign(socket, :status_form, to_form(changeset))}
    end
  end

  def handle_event("set_card_status", _params, socket), do: {:noreply, socket}

  # Owner changes are explicit drawer actions. Adding a :user owner is
  # restricted to the signed-in user (MVP boards are single-human; members
  # arrive in MMF 17); anything unresolvable is a silent no-op.
  def handle_event("add_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    current_user_id = socket.assigns.current_scope.user.id

    case resolve_actor(params) do
      :agent -> apply_owner_change(socket, Cards.add_owner(card, :agent))
      {:user, ^current_user_id} = actor -> apply_owner_change(socket, Cards.add_owner(card, actor))
      _other -> {:noreply, socket}
    end
  end

  def handle_event("add_owner", _params, socket), do: {:noreply, socket}

  def handle_event("remove_owner", params, %{assigns: %{selected_card: %Card{} = card}} = socket) do
    case resolve_actor(params) do
      nil -> {:noreply, socket}
      actor -> apply_owner_change(socket, Cards.remove_owner(card, actor))
    end
  end

  def handle_event("remove_owner", _params, socket), do: {:noreply, socket}
```

  4. Add the private helpers (near the other defps; `parse_int/1` already exists in this module):

```elixir
  defp resolve_actor(%{"actor_type" => "agent"}), do: :agent

  defp resolve_actor(%{"actor_type" => "user", "user_id" => user_id}) do
    case parse_int(user_id) do
      nil -> nil
      id -> {:user, id}
    end
  end

  defp resolve_actor(_params), do: nil

  defp apply_owner_change(socket, {:ok, %Card{} = card}), do: {:noreply, refresh_card(socket, card)}
  defp apply_owner_change(socket, {:error, _changeset}), do: {:noreply, socket}

  # A persisted baton change: sync the drawer assigns and re-stream the
  # card so the board card re-renders its colour/badge.
  defp refresh_card(socket, %Card{} = card) do
    socket
    |> assign(:selected_card, card)
    |> assign(:status_form, status_form(card))
    |> stream_insert(stream_name(card.stage_id), card)
  end

  defp status_form(%Card{} = card) do
    to_form(%{"status" => Atom.to_string(card.status), "progress" => card.progress}, as: :card)
  end
```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — expect pass.
- [ ] Refresh `storybook/core_components/card_drawer.story.exs` — the drawer now requires `status_form` and reads `card.status` / `card.owners`. Replace `variations/0` and `story_card/0` with:

```elixir
  def variations do
    [
      %Variation{
        id: :viewing,
        attributes: %{
          id: "story-drawer-1",
          ref: "RLY-7",
          card: story_card(),
          stage_name: "Code",
          stage_owner: :ai,
          active_owner: :ai,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Draft the onboarding spec"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "working", "progress" => 61}, as: :card),
          stages: [%{id: 3, name: "Plan"}, %{id: 4, name: "Code"}, %{id: 7, name: "Done"}]
        }
      },
      %Variation{
        id: :editing_description,
        attributes: %{
          id: "story-drawer-2",
          ref: "RLY-8",
          card: %{story_card() | description: nil, tag: nil, status: :queued, progress: nil, owners: []},
          stage_name: "Spec",
          stage_owner: :human,
          active_owner: nil,
          current_user_id: 1,
          close_patch: "/storybook/core_components/card_drawer",
          title_form: Phoenix.Component.to_form(%{"title" => "Wire the drawer"}, as: :card),
          status_form: Phoenix.Component.to_form(%{"status" => "queued", "progress" => nil}, as: :card),
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
      status: :working,
      progress: 61,
      owners: [
        %{id: 1, actor_type: :user, user_id: 1, user: %{name: "Ada Lovelace", email: "ada@example.com"}},
        %{id: 2, actor_type: :agent, user_id: nil, user: nil}
      ],
      inserted_at: ~U[2026-07-01 09:00:00Z],
      updated_at: ~U[2026-07-06 15:30:00Z]
    }
  end
```

- [ ] Run `mix precommit` — must pass (the whole suite, including all pre-existing drawer tests). Commit.

**Deliverable:** the drawer's properties rail shows ACTIVE WORKER (pill + name), the full
owner list with paused markers and per-owner remove, Assign AI / Add me controls, and a
status control (with a progress input while working) — every change persists via
`Relay.Cards` and immediately re-renders the board card. Drawer story refreshed at
`/storybook/core_components/card_drawer` (mention the link when reporting this task).
**Commit message:** `feat(drawer): baton rail — active worker, owners, status controls`

---

## Spec coverage map (self-check)

| Spec requirement | Task |
| --- | --- |
| ADR 0002 + `Schemas` peer boundary | 1 |
| 5 schemas migrated, every reference updated, precommit/boundary green | 1 |
| `card_owners` join, uniqueness on `(card_id, actor_type, user_id)`, `user_id` iff `:user` | 2 |
| `status` enum (default `:queued`) + nullable `progress`, migrations via `mix ecto.gen.migration` | 3 (and 2) |
| Status setter; changesets in the schema, logic in the context | 3 |
| `set_owners/2` / `add_owner/2` / `remove_owner/2`; owners preloaded in list/get | 4 |
| Active-owner derivation (AI active if agent among owners; others paused) | 4 (derivation), 7 (paused UI) |
| Nothing auto-changes on move; `Stage.owner` = "meant for" only | 4 & 6 (tested), 1 (docs) |
| Card active-owner colour + pill; status badge (`working·N%`, in_review, done) | 5, 6 |
| Amber NEEDS INPUT on the board | 5, 6 |
| Red mismatch, both directions, display-only | 5, 6 |
| Drawer rail: ACTIVE WORKER + paused owners + set status + add/remove owners (claim/release AI) | 7 |
| Acceptance: drawer changes persist and reflect on the board card | 7 |
