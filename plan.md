# Plan — MMF 07: Comments & activity (one interleaved timeline)

**Spec:** `docs/superpowers/specs/2026-07-07-comments-activity-design.md`
**Development:** trunk-based on `main`. One commit per task, message given at the end of each task.

## Goal

A card becomes a conversation and a record. Humans and the AI post comments, and every
meaningful card change (create, move, status change, owner change) is logged automatically —
and the two are shown as **one interleaved timeline** in the card drawer (comments + activity
merged chronologically, GitHub-style), with a composer to post new comments.

1. **Task 1:** a new `Relay.Activity` context (its own boundary) owning two new schemas,
   `Schemas.Comment` and `Schemas.Activity`, with `add_comment/2`, `log/2`, and
   `list_timeline/1` — fully unit-tested in isolation.
2. **Task 2:** `Relay.Cards` emits activity from the domain (not the web layer): card create
   logs `:created`, `move_card` logs `:moved` (replacing the MMF 05 no-op seam), `set_status`
   logs `:status_changed`, and the owner setters log `:owners_changed`. Every mutator gains an
   optional trailing `actor` argument; the LiveView passes the signed-in user.
3. **Task 3:** the drawer renders the interleaved timeline (LiveView stream) with a comment
   composer that appends live.

## Architecture

- **`Relay.Activity` is a new context sub-boundary** (`lib/relay/activity.ex`,
  `use Boundary, deps: [Relay.Repo, Schemas]`), added to `Relay`'s `exports` in `lib/relay.ex`
  so the web layer can reach it. `Relay.Cards` gains a boundary dep on `Relay.Activity`
  (no cycle — Activity never calls Cards).
- **Both schemas live in the shared `Schemas` boundary** (ADR 0002, landed in MMF 06):
  `lib/schemas/comment.ex` and `lib/schemas/activity.ex`, both added to `Schemas`' `exports`
  in `lib/schemas.ex`.
- **Author = actor** (the exact MMF 06 concept from `Schemas.CardOwner` / `Relay.Cards`):
  `actor_type :user` + `user_id`, XOR `actor_type :agent` + `user_id: nil` (renders as
  "Relay AI"). The context API takes `:agent | {:user, user_id}` tuples, same as
  `Cards.add_owner/2` does today.
- **Domain emits, web renders.** The `Activity.log/2` calls live inside `Relay.Cards`
  mutators so the LiveView today and the REST API (MMF 09) produce identical log entries.
  The `Cards` mutators take the acting actor as an optional trailing argument defaulting to
  `:agent` — the API surface (MMF 09) is the agent, while the web layer always passes
  `{:user, current_user_id}` explicitly.
- **`meta` is a jsonb map with string keys.** Callers of `log/2` build meta with string keys
  and string values (e.g. `%{"from_stage" => "Spec", "to_stage" => "Code"}`) so the in-memory
  struct and the DB round-trip are identical — never atom keys.
- **The timeline is a LiveView stream** (`:timeline`) with a custom `dom_id`
  (`timeline-comment-<id>` / `timeline-activity-<id>`) since it mixes two struct types.

## Tech

Phoenix 1.8 + LiveView, Ecto/Postgres, `boundary` (compiler-enforced), ExMachina factories,
daisyUI/Tailwind v4, `Phoenix.LiveViewTest` + LazyHTML. No new dependencies.

## Global Constraints (project rules — verbatim, apply to every task)

- Running `mix precommit` is REQUIRED on every development cycle and must pass before work is
  considered done. It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings as
  errors). Fix any failure before finishing — never commit work with a failing `mix precommit`.
- **Context boundaries are enforced by `boundary`** (wired into the compiler). The web layer
  (`RelayWeb`) may only call the domain through `Relay`'s exported contexts; contexts may not
  reach into the web layer. Each context is its own sub-boundary declared in `lib/relay.ex` —
  when you add a context, give it `use Boundary` and add it to `Relay`'s `exports`. A boundary
  violation fails compilation.
- **Always** use LiveView streams for collections. Streams are *not* enumerable — to filter or
  refresh you **must refetch and re-stream with `reset: true`**. Streams *do not support
  counting or empty states* — track counts in a separate assign; empty states use the
  `hidden only:block` Tailwind pattern as the only HTML block alongside the stream
  comprehension. The template must set `phx-update="stream"` + a DOM id on the parent and use
  the stream id as each child's DOM id.
- Elixir lists **do not support index based access via the access syntax** — use `Enum.at`,
  pattern matching, or `List`.
- Predicate function names should not start with `is_` and should end in a question mark.
- Fields which are set programmatically, such as `user_id`, must not be listed in `cast` calls
  or similar for security purposes. Instead they must be explicitly set when creating the
  struct. (Here: `card_id`, `actor_type`, `user_id`, `type`, and `meta` are all programmatic —
  only a comment's `body` is ever cast.)
- **Always** use the imported `<.icon>` component for icons and the imported `<.input>`
  component for form inputs from `core_components.ex`.
- **Author is a polymorphic actor, `:user` XOR `:agent`:** `actor_type: :user` requires
  `user_id`; `actor_type: :agent` requires `user_id` to be nil (validated in the changeset,
  exactly like `Schemas.CardOwner`).
- **Never** nest multiple modules in one file. Use `Ecto.Changeset.get_field/2` on changesets.
  **Always** invoke `mix ecto.gen.migration migration_name_using_underscores` for migrations.
  **Always** begin LiveView templates with `<Layouts.app flash={@flash} ...>` (already the
  case in `BoardLive`). HEEx: `{...}` in attrs and tag bodies, `<%= ... %>` for block
  constructs; class lists use `[...]` syntax; comments are `<%!-- ... --%>`.
- Tests: **always** reference key element IDs; use `element/2` / `has_element?/2`, never raw
  HTML assertions; **avoid** `Process.sleep/1`.
- Out of scope (do NOT build): rich AI result blocks / sub-tasks (MMF 16),
  @-mentions/notifications, comment edit/delete, the REST API (MMF 09).

---

### Task 1: `Relay.Activity` context + `Schemas.Comment` / `Schemas.Activity` schemas

One vertical slice: migration, both schemas, the `Schemas` boundary export, the new
`Relay.Activity` sub-boundary + `Relay` export, factories, and the three context functions —
fully unit-tested in isolation (no `Cards` involvement yet).

**Files**

- Create: `priv/repo/migrations/<timestamp>_create_comments_and_activities.exs` (via
  `mix ecto.gen.migration create_comments_and_activities`)
- Create: `lib/schemas/comment.ex`
- Create: `lib/schemas/activity.ex`
- Create: `lib/relay/activity.ex`
- Create: `test/relay/activity_test.exs`
- Modify: `lib/schemas.ex` (exports)
- Modify: `lib/relay.ex` (exports)
- Modify: `test/support/factory.ex` (add `comment_factory/1`, `activity_factory/1`)

**Interfaces**

- Consumes (existing code):
  - `Relay.Repo` — standard Ecto repo.
  - `Schemas.Card` (`%Schemas.Card{id: integer}`), `Schemas.User` (has `name`, `email`).
  - Factory pattern from `test/support/factory.ex` (`card_factory/1` full-control style).
  - `Relay.DataCase` (`use Relay.DataCase, async: true`, gives `insert/2`, `Repo`,
    `errors_on/1`, `import Ecto.Query`).
- Produces (later tasks rely on these EXACT names/types):
  - `Schemas.Comment` — schema `"comments"`: `card_id`, `actor_type` (`Ecto.Enum`
    `[:user, :agent]`), `user_id` (nullable), `body :string` (text column),
    `belongs_to :card` / `:user`, `timestamps(type: :utc_datetime)`.
    `Schemas.Comment.changeset(comment, attrs)` — casts ONLY `:body`.
  - `Schemas.Activity` — schema `"activities"`: `card_id`, `type` (`Ecto.Enum`
    `[:created, :moved, :status_changed, :owners_changed, :commented]`), `meta :map`
    (default `%{}`), `actor_type`, `user_id` (nullable), `belongs_to :card` / `:user`,
    `timestamps(type: :utc_datetime)`. `Schemas.Activity.changeset(activity)` — no cast,
    programmatic fields only. (`:commented` is in the enum per the spec for future feeds/API
    use — nothing emits it in MMF 07.)
  - `Relay.Activity.add_comment(%Schemas.Card{}, %{actor: :agent | {:user, integer()}, body: String.t() | nil})`
    → `{:ok, %Schemas.Comment{}}` (with `:user` preloaded) | `{:error, %Ecto.Changeset{}}`
  - `Relay.Activity.log(%Schemas.Card{}, %{type: atom(), actor: :agent | {:user, integer()}, meta: map()})`
    (`:meta` optional, defaults `%{}`, string keys) → `{:ok, %Schemas.Activity{}}` (with
    `:user` preloaded) | `{:error, %Ecto.Changeset{}}`
  - `Relay.Activity.list_timeline(%Schemas.Card{})` →
    `[%Schemas.Comment{} | %Schemas.Activity{}]`, merged, ascending by `inserted_at`
    (stable: comments queried first sort before activities at the same second; within a
    source, ties break by `id`), each with `:user` preloaded.
  - Factories: `insert(:comment, card: card, user: user, body: "...", inserted_at: ~U[...])`
    (no `user` ⇒ agent comment) and
    `insert(:activity, card: card, type: :moved, meta: %{...}, user: user, inserted_at: ~U[...])`
    (no `user` ⇒ agent actor; default `type: :moved` with a sample meta).

**Steps**

- [x] Generate the migration:

  ```bash
  mix ecto.gen.migration create_comments_and_activities
  ```

  Fill the generated file with exactly:

  ```elixir
  defmodule Relay.Repo.Migrations.CreateCommentsAndActivities do
    use Ecto.Migration

    def change do
      create table(:comments) do
        add :card_id, references(:cards, on_delete: :delete_all), null: false
        add :actor_type, :string, null: false
        add :user_id, references(:users, on_delete: :delete_all)
        add :body, :text, null: false

        timestamps(type: :utc_datetime)
      end

      create index(:comments, [:card_id, :inserted_at])
      create index(:comments, [:user_id])

      create table(:activities) do
        add :card_id, references(:cards, on_delete: :delete_all), null: false
        add :type, :string, null: false
        add :meta, :map, null: false, default: %{}
        add :actor_type, :string, null: false
        add :user_id, references(:users, on_delete: :delete_all)

        timestamps(type: :utc_datetime)
      end

      create index(:activities, [:card_id, :inserted_at])
      create index(:activities, [:user_id])
    end
  end
  ```

  Run `mix ecto.migrate` (and note `MIX_ENV=test mix ecto.migrate` is handled automatically
  by the test alias — just run the tests).

- [x] **TDD cycle 1 — comments.** Create `test/relay/activity_test.exs` with the comment
  tests (the file grows in later cycles):

  ```elixir
  defmodule Relay.ActivityTest do
    use Relay.DataCase, async: true

    alias Relay.Activity
    alias Schemas.Comment

    setup do
      user = insert(:user, name: "Ada Lovelace")
      card = insert(:card)
      %{user: user, card: card}
    end

    describe "add_comment/2" do
      test "persists a user comment with the user preloaded", %{card: card, user: user} do
        assert {:ok, %Comment{} = comment} =
                 Activity.add_comment(card, %{actor: {:user, user.id}, body: "Looks good"})

        assert comment.card_id == card.id
        assert comment.actor_type == :user
        assert comment.user_id == user.id
        assert comment.body == "Looks good"
        assert comment.user.name == "Ada Lovelace"
        assert Repo.get!(Comment, comment.id).body == "Looks good"
      end

      test "persists an agent comment with no user", %{card: card} do
        assert {:ok, %Comment{} = comment} =
                 Activity.add_comment(card, %{actor: :agent, body: "Done — see the PR."})

        assert comment.actor_type == :agent
        assert comment.user_id == nil
        assert comment.user == nil
      end

      test "rejects a blank body and persists nothing", %{card: card, user: user} do
        assert {:error, changeset} =
                 Activity.add_comment(card, %{actor: {:user, user.id}, body: ""})

        assert "can't be blank" in errors_on(changeset).body
        assert Repo.aggregate(Comment, :count) == 0
      end
    end
  end
  ```

- [x] Run `mix test test/relay/activity_test.exs` — expect failure (modules don't exist).

- [x] Create `lib/schemas/comment.ex`:

  ```elixir
  defmodule Schemas.Comment do
    @moduledoc """
    A comment on a card, authored by an actor: a user (`actor_type: :user`
    + `user_id`) or the single Relay AI agent (`actor_type: :agent`, no
    `user_id` — renders as "Relay AI"). Only `body` is user input;
    `card_id`, `actor_type`, and `user_id` are set programmatically, never
    cast from input.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "comments" do
      field :actor_type, Ecto.Enum, values: [:user, :agent]
      field :body, :string

      belongs_to :card, Schemas.Card
      belongs_to :user, Schemas.User

      timestamps(type: :utc_datetime)
    end

    @doc """
    Validates a comment whose actor fields are already set on the struct;
    only `:body` is cast from input.
    """
    def changeset(comment, attrs) do
      comment
      |> cast(attrs, [:body])
      |> validate_required([:card_id, :actor_type, :body])
      |> validate_actor_user()
      |> foreign_key_constraint(:card_id)
      |> foreign_key_constraint(:user_id)
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

- [x] Add `Comment` (and, ahead of cycle 2, `Activity`) to the `Schemas` boundary exports in
  `lib/schemas.ex`:

  ```elixir
  use Boundary, deps: [], exports: [Activity, Board, Card, CardOwner, Comment, Scope, Stage, User]
  ```

- [x] Create `lib/relay/activity.ex` with the context, its boundary, and `add_comment/2`
  (with the private helpers `log/2` and `list_timeline/1` will also use — the module below is
  complete for the whole task; `log/2` and `list_timeline/1` are added in cycles 2–3, shown
  here in final form):

  ```elixir
  defmodule Relay.Activity do
    @moduledoc """
    The Activity context: a card's conversational and audit record —
    comments posted by humans or the AI, and activity entries logged for
    every meaningful card change (MMF 07).

    An "actor" is either the single Relay AI agent (`:agent`) or a user
    (`{:user, user_id}`) — the same concept `Relay.Cards` uses for owners.
    This context never calls `Relay.Cards`; `Cards` depends on it to log.
    """

    use Boundary, deps: [Relay.Repo, Schemas]

    import Ecto.Query

    alias Relay.Repo
    alias Schemas.Card
    alias Schemas.Comment

    @doc """
    Posts a comment on `card` from `attrs` — `:actor`
    (`:agent | {:user, user_id}`, programmatic) and `:body` (the only
    user-supplied field) — returning `{:ok, comment}` with the author
    preloaded or `{:error, changeset}`.
    """
    def add_comment(%Card{} = card, %{actor: actor} = attrs) do
      {actor_type, user_id} = split_actor(actor)

      %Comment{card_id: card.id, actor_type: actor_type, user_id: user_id}
      |> Comment.changeset(Map.take(attrs, [:body]))
      |> Repo.insert()
      |> preload_user()
    end

    @doc """
    Appends an activity entry to `card`'s log from `attrs` — `:type`
    (`:created | :moved | :status_changed | :owners_changed | :commented`),
    `:actor` (`:agent | {:user, user_id}`), and optional `:meta` (a map
    with STRING keys and primitive values, stored as jsonb; defaults to
    `%{}`) — returning `{:ok, activity}` with the actor preloaded or
    `{:error, changeset}`.
    """
    def log(%Card{} = card, %{type: type, actor: actor} = attrs) do
      {actor_type, user_id} = split_actor(actor)

      %Schemas.Activity{
        card_id: card.id,
        type: type,
        meta: Map.get(attrs, :meta, %{}),
        actor_type: actor_type,
        user_id: user_id
      }
      |> Schemas.Activity.changeset()
      |> Repo.insert()
      |> preload_user()
    end

    @doc """
    The card's full timeline: its comments and activity entries merged
    into one list, ascending by `inserted_at` (comments sort before
    activity entries logged in the same second; within a source, ties
    break by id), each entry with its `:user` preloaded (`nil` for the
    agent).
    """
    def list_timeline(%Card{id: card_id}) do
      comments =
        Repo.all(
          from c in Comment,
            where: c.card_id == ^card_id,
            order_by: [asc: c.inserted_at, asc: c.id],
            preload: :user
        )

      activities =
        Repo.all(
          from a in Schemas.Activity,
            where: a.card_id == ^card_id,
            order_by: [asc: a.inserted_at, asc: a.id],
            preload: :user
        )

      Enum.sort_by(comments ++ activities, & &1.inserted_at, DateTime)
    end

    defp split_actor(:agent), do: {:agent, nil}
    defp split_actor({:user, user_id}) when is_integer(user_id), do: {:user, user_id}

    defp preload_user({:ok, record}), do: {:ok, Repo.preload(record, :user)}
    defp preload_user({:error, changeset}), do: {:error, changeset}
  end
  ```

  Note: `Schemas.Activity` is deliberately referenced fully-qualified (no alias) — an
  `alias Schemas.Activity` inside `defmodule Relay.Activity` would shadow the context's own
  name and confuse readers. `Enum.sort_by/3` is stable, which is what makes the
  comments-before-activities tie-break hold.

- [x] Add `Activity` to `Relay`'s exports in `lib/relay.ex`:

  ```elixir
  use Boundary,
    deps: [Schemas],
    exports: [Repo, Mailer, Accounts, Activity, Boards, Cards]
  ```

- [x] Add both factories to `test/support/factory.ex` (append inside the module, matching the
  existing full-control style — `card`/`user` overrides must be persisted records; Ecto only
  autogenerates `inserted_at` when it's unset, so tests may pass explicit timestamps):

  ```elixir
  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, a human comment; without, an agent ("Relay AI") comment.
  def comment_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    comment = %Schemas.Comment{
      card_id: card.id,
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id,
      body: sequence(:comment_body, &"Comment #{&1}")
    }

    comment |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end

  # Full-control factory: `card` (when overridden) must be a persisted card.
  # With a `user`, a human actor; without, the agent. Defaults to a :moved
  # entry with a sample string-keyed meta.
  def activity_factory(attrs) do
    {card, attrs} = Map.pop_lazy(attrs, :card, fn -> insert(:card) end)
    {user, attrs} = Map.pop(attrs, :user)

    activity = %Schemas.Activity{
      card_id: card.id,
      type: :moved,
      meta: %{"from_stage" => "Spec", "to_stage" => "Code"},
      actor_type: if(user, do: :user, else: :agent),
      user_id: user && user.id
    }

    activity |> merge_attributes(attrs) |> evaluate_lazy_attributes()
  end
  ```

- [x] Run `mix test test/relay/activity_test.exs` — cycle 1 tests pass (`log/2` /
  `list_timeline/1` are not exercised yet; if you deferred them, add them now as written
  above before cycle 2).

- [x] **TDD cycle 2 — activity log.** Append to `test/relay/activity_test.exs` (inside the
  module, after the `add_comment/2` describe):

  ```elixir
  describe "log/2" do
    test "persists an entry with type, meta, and actor, user preloaded", %{card: card, user: user} do
      assert {:ok, %Schemas.Activity{} = entry} =
               Activity.log(card, %{
                 type: :moved,
                 actor: {:user, user.id},
                 meta: %{"from_stage" => "Spec", "to_stage" => "Code"}
               })

      assert entry.card_id == card.id
      assert entry.type == :moved
      assert entry.actor_type == :user
      assert entry.user_id == user.id
      assert entry.user.name == "Ada Lovelace"

      assert Repo.get!(Schemas.Activity, entry.id).meta ==
               %{"from_stage" => "Spec", "to_stage" => "Code"}
    end

    test "meta defaults to an empty map and the agent actor has no user", %{card: card} do
      assert {:ok, entry} = Activity.log(card, %{type: :created, actor: :agent})

      assert entry.meta == %{}
      assert entry.actor_type == :agent
      assert entry.user_id == nil
      assert entry.user == nil
    end
  end
  ```

- [x] Run `mix test test/relay/activity_test.exs` — expect failure until
  `lib/schemas/activity.ex` exists. Create it:

  ```elixir
  defmodule Schemas.Activity do
    @moduledoc """
    One entry in a card's activity log: what happened (`type`), free-form
    details (`meta`, a jsonb map with STRING keys — e.g.
    `%{"from_stage" => "Spec", "to_stage" => "Code"}`), and who did it —
    a user (`actor_type: :user` + `user_id`) or the Relay AI agent
    (`actor_type: :agent`, no `user_id`). All fields are set
    programmatically by `Relay.Activity.log/2`, never cast from input.
    `:commented` is reserved for future feeds/API use (MMF 09/16) —
    nothing emits it in MMF 07.
    """

    use Ecto.Schema

    import Ecto.Changeset

    schema "activities" do
      field :type, Ecto.Enum, values: [:created, :moved, :status_changed, :owners_changed, :commented]
      field :meta, :map, default: %{}
      field :actor_type, Ecto.Enum, values: [:user, :agent]

      belongs_to :card, Schemas.Card
      belongs_to :user, Schemas.User

      timestamps(type: :utc_datetime)
    end

    @doc "Validates a programmatically-built activity entry."
    def changeset(activity) do
      activity
      |> change()
      |> validate_required([:card_id, :type, :actor_type])
      |> validate_actor_user()
      |> foreign_key_constraint(:card_id)
      |> foreign_key_constraint(:user_id)
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

  Run `mix test test/relay/activity_test.exs` — cycle 2 passes.

- [x] **TDD cycle 3 — timeline.** Append to `test/relay/activity_test.exs`:

  ```elixir
  describe "list_timeline/1" do
    test "merges comments and activity chronologically with users preloaded", %{card: card, user: user} do
      c1 = insert(:comment, card: card, user: user, body: "First", inserted_at: ~U[2026-07-07 10:00:10Z])
      a1 = insert(:activity, card: card, type: :created, meta: %{}, inserted_at: ~U[2026-07-07 10:00:00Z])
      a2 = insert(:activity, card: card, user: user, inserted_at: ~U[2026-07-07 10:00:20Z])
      c2 = insert(:comment, card: card, body: "Second", inserted_at: ~U[2026-07-07 10:00:30Z])

      timeline = Activity.list_timeline(card)

      assert Enum.map(timeline, &{&1.__struct__, &1.id}) == [
               {Schemas.Activity, a1.id},
               {Comment, c1.id},
               {Schemas.Activity, a2.id},
               {Comment, c2.id}
             ]

      assert [created, first_comment, moved, second_comment] = timeline
      assert created.user == nil
      assert first_comment.user.name == "Ada Lovelace"
      assert moved.user.id == user.id
      assert second_comment.user == nil
    end

    test "comments sort before activity entries at the same timestamp", %{card: card, user: user} do
      at = ~U[2026-07-07 12:00:00Z]
      comment = insert(:comment, card: card, user: user, inserted_at: at)
      entry = insert(:activity, card: card, inserted_at: at)

      assert Enum.map(Activity.list_timeline(card), &{&1.__struct__, &1.id}) == [
               {Comment, comment.id},
               {Schemas.Activity, entry.id}
             ]
    end

    test "excludes other cards' entries", %{card: card} do
      other = insert(:card)
      insert(:comment, card: other)
      insert(:activity, card: other)
      mine = insert(:comment, card: card)

      assert Enum.map(Activity.list_timeline(card), &{&1.__struct__, &1.id}) == [{Comment, mine.id}]
    end

    test "returns [] for a card with no history", %{card: card} do
      assert Activity.list_timeline(card) == []
    end
  end
  ```

  Run `mix test test/relay/activity_test.exs` — all pass (implementation already in place;
  if any ordering assertion fails, fix `list_timeline/1`, not the test).

- [x] Run `mix precommit` and fix anything it flags.
- [x] Commit.

**Deliverable:** the `Relay.Activity` context is fully unit-tested in isolation —
`mix test test/relay/activity_test.exs` green, `mix precommit` green, no other module touched
except the two boundary export lists and the factory.

**Commit message:** `feat(activity): Relay.Activity context with comments + activity log (MMF 07)`

---

### Task 2: Domain emit wiring — `Relay.Cards` logs activity for create/move/status/owners

One vertical slice: `Cards` gains a boundary dep on `Relay.Activity`; every card mutator gains
an optional trailing `actor` argument (default `:agent` — the MMF 09 API caller identity;
every existing call site keeps compiling and becomes agent-attributed, which is exactly the
API semantics) and logs the right activity entry; the MMF 05 no-op seam `emit_stage_changed/2` is
replaced with real logging; the LiveView passes `{:user, current_user_id}` at all six call
sites, with integration tests proving user attribution end-to-end.

**Files**

- Modify: `lib/relay/cards.ex`
- Modify: `lib/relay_web/live/board_live.ex` (six `Cards.*` call sites gain the actor arg)
- Modify: `test/relay/cards_test.exs` (new `describe "activity logging"`; update the
  `describe` strings for the changed arities)
- Modify: `test/relay_web/live/board_live_test.exs` (new `describe "activity attribution"`)

**Interfaces**

- Consumes (from Task 1, exact names):
  - `Relay.Activity.log(card, %{type: atom, actor: :agent | {:user, integer}, meta: map})`
    → `{:ok, %Schemas.Activity{}} | {:error, changeset}`
  - `Schemas.Activity` struct (for test assertions).
- Produces (Task 3 and the web layer rely on these EXACT signatures — each keeps ONE def
  clause with a default, so the old arity still works and means "acting as the agent"):
  - `Relay.Cards.create_card(%Schemas.Stage{}, attrs, actor \\ :agent)` → unchanged returns;
    logs `:created` (meta `%{}`) inside the create transaction.
  - `Relay.Cards.move_card(%Schemas.Card{}, %Schemas.Stage{}, index, actor \\ :agent)` →
    unchanged returns; a CROSS-STAGE move logs `:moved` with
    `meta: %{"from_stage" => <old stage name>, "to_stage" => <new stage name>}` inside the
    move transaction; a same-stage reorder logs nothing.
  - `Relay.Cards.set_status(%Schemas.Card{}, attrs, actor \\ :agent)` → unchanged returns;
    logs `:status_changed` with `meta: %{"from_status" => "queued", "to_status" => "in_review"}`
    (stringified enum values) ONLY when the status value actually changed (a progress-only
    update logs nothing).
  - `Relay.Cards.set_owners(%Schemas.Card{}, actors, actor \\ :agent)` → unchanged returns;
    logs `:owners_changed` with `meta: %{"action" => "set", "owners" => [labels]}`.
  - `Relay.Cards.add_owner(%Schemas.Card{}, owner_actor, actor \\ :agent)` → unchanged
    returns; logs `:owners_changed` with `meta: %{"action" => "added", "owner" => label}`
    ONLY when the owner was not already present (the ok no-op logs nothing).
  - `Relay.Cards.remove_owner(%Schemas.Card{}, owner_actor, actor \\ :agent)` → unchanged
    returns; logs `:owners_changed` with `meta: %{"action" => "removed", "owner" => label}`
    ONLY when a row was actually deleted.
  - Owner labels: `"AI"` for `:agent`; the user's `name || email` for `{:user, id}`
    (snapshotted into meta at log time).

**Steps**

- [ ] **TDD cycle 1 — create + move.** Append to `test/relay/cards_test.exs` (inside the
  module; it already has the `setup` providing `%{board: board, stage: stage}` and
  `use Relay.DataCase` brings `import Ecto.Query`):

  ```elixir
  describe "activity logging" do
    setup %{board: board} do
      user = insert(:user, name: "Ada Lovelace")
      target = insert(:stage, board: board, name: "Code", position: 2)
      %{user: user, target: target}
    end

    test "create_card/3 logs :created attributed to the actor", %{stage: stage, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"}, {:user, user.id})

      assert [%Schemas.Activity{type: :created, actor_type: :user, user_id: user_id, meta: %{}}] =
               activities(card)

      assert user_id == user.id
    end

    test "create_card/3 defaults the actor to the agent", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "T"})

      assert [%Schemas.Activity{type: :created, actor_type: :agent, user_id: nil}] = activities(card)
    end

    test "a failed create logs nothing", %{stage: stage} do
      {:error, _changeset} = Cards.create_card(stage, %{title: ""})

      assert Repo.aggregate(Schemas.Activity, :count) == 0
    end

    test "move_card/4 logs :moved with both stage names", %{stage: stage, target: target, user: user} do
      {:ok, card} = Cards.create_card(stage, %{title: "Mover"})

      {:ok, moved} = Cards.move_card(card, target, 0, {:user, user.id})

      assert [_created, %Schemas.Activity{type: :moved, actor_type: :user, meta: meta}] =
               activities(moved)

      assert meta == %{"from_stage" => stage.name, "to_stage" => "Code"}
    end

    test "a same-stage reorder logs nothing", %{stage: stage} do
      {:ok, card} = Cards.create_card(stage, %{title: "A"})
      {:ok, _other} = Cards.create_card(stage, %{title: "B"})

      {:ok, moved} = Cards.move_card(card, stage, 1)

      assert [%Schemas.Activity{type: :created}] = activities(moved)
    end
  end
  ```

  And add the private helper at the bottom of the test module (next to the existing
  `stage_card_ids`-style helpers):

  ```elixir
  defp activities(card) do
    Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: a.id)
  end
  ```

- [ ] Run `mix test test/relay/cards_test.exs` — the new tests fail (wrong arity / no rows).

- [ ] Implement in `lib/relay/cards.ex`:
  1. Boundary dep + alias:

     ```elixir
     use Boundary, deps: [Relay.Activity, Relay.Repo, Schemas]
     ```

     and add `alias Relay.Activity` to the alias block (Styler keeps it sorted:
     `Relay.Activity`, `Relay.Repo`, then the `Schemas.*` aliases). Also add
     `alias Schemas.User` (used by `owner_label/1` in cycle 3).
  2. `create_card/3` — replace the existing `create_card/2`:

     ```elixir
     def create_card(%Stage{} = stage, attrs, actor \\ :agent) do
       Repo.transaction(fn ->
         ref_number = allocate_ref_number(stage.board_id)

         case insert_card(stage, ref_number, attrs) do
           {:ok, card} ->
             {:ok, _entry} = Activity.log(card, %{type: :created, actor: actor})
             preload_owners(card)

           {:error, changeset} ->
             Repo.rollback(changeset)
         end
       end)
     end
     ```

     Update its `@doc` to mention the `actor` (`:agent | {:user, user_id}`, default
     `:agent` — the API identity; web callers pass the signed-in user) and the `:created`
     log entry.
  3. `move_card/4` — add the `actor` param and replace the MMF 05 no-op seam:

     ```elixir
     def move_card(
           %Card{board_id: board_id} = card,
           %Stage{board_id: board_id} = target_stage,
           index,
           actor \\ :agent
         )
         when is_integer(index) do
       previous_stage_id = card.stage_id

       Repo.transaction(fn ->
         moved = preload_owners(place_at(card, target_stage, index))

         if moved.stage_id != previous_stage_id do
           emit_stage_changed(moved, previous_stage_id, target_stage, actor)
         end

         moved
       end)
     end
     ```

     and replace the no-op `emit_stage_changed/2` private with:

     ```elixir
     # The MMF 05 seam, now live: a cross-stage move appends a :moved
     # timeline entry with both stage names snapshotted into meta.
     defp emit_stage_changed(%Card{} = moved, previous_stage_id, %Stage{} = target_stage, actor) do
       from_stage = Repo.get!(Stage, previous_stage_id)

       {:ok, _entry} =
         Activity.log(moved, %{
           type: :moved,
           actor: actor,
           meta: %{"from_stage" => from_stage.name, "to_stage" => target_stage.name}
         })
     end
     ```

     Update `move_card`'s `@doc` sentence about the seam ("A cross-stage move logs a
     `:moved` activity entry (MMF 07) attributed to `actor`.").
- [ ] Run `mix test test/relay/cards_test.exs` — cycle 1 green (all pre-existing tests must
  still pass unchanged — the default actor keeps old call sites compiling).

- [ ] **TDD cycle 2 — status.** Append inside the `describe "activity logging"` block:

  ```elixir
  test "set_status/3 logs :status_changed with from/to", %{stage: stage, user: user} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})

    {:ok, updated} = Cards.set_status(card, %{"status" => "in_review"}, {:user, user.id})

    assert [_created, %Schemas.Activity{type: :status_changed, actor_type: :user, meta: meta}] =
             activities(updated)

    assert meta == %{"from_status" => "queued", "to_status" => "in_review"}
  end

  test "a progress-only change does not log", %{stage: stage} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})
    {:ok, card} = Cards.set_status(card, %{"status" => "working", "progress" => "10"})

    {:ok, card} = Cards.set_status(card, %{"status" => "working", "progress" => "50"})

    assert Enum.map(activities(card), & &1.type) == [:created, :status_changed]
  end

  test "a failed status change logs nothing", %{stage: stage} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})

    {:error, _changeset} = Cards.set_status(card, %{"status" => "banana"})

    assert Enum.map(activities(card), & &1.type) == [:created]
  end
  ```

  Run them (fail), then implement — replace `set_status/2`:

  ```elixir
  def set_status(%Card{} = card, attrs, actor \\ :agent) do
    from_status = card.status

    card
    |> Card.status_changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
    |> log_status_changed(from_status, actor)
  end
  ```

  with the private helper (place near the other `log_*`/`preload_*` privates):

  ```elixir
  defp log_status_changed({:ok, %Card{} = card} = result, from_status, actor) do
    if card.status != from_status do
      {:ok, _entry} =
        Activity.log(card, %{
          type: :status_changed,
          actor: actor,
          meta: %{"from_status" => to_string(from_status), "to_status" => to_string(card.status)}
        })
    end

    result
  end

  defp log_status_changed({:error, _changeset} = result, _from_status, _actor), do: result
  ```

  Update `set_status`'s `@doc` (actor + "logs `:status_changed` when the status value
  actually changes"). Run `mix test test/relay/cards_test.exs` — green.

- [ ] **TDD cycle 3 — owners.** Append inside `describe "activity logging"`:

  ```elixir
  test "add_owner/3 logs :owners_changed with the owner label", %{stage: stage, user: user} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})

    {:ok, card} = Cards.add_owner(card, :agent, {:user, user.id})

    assert [_created, %Schemas.Activity{type: :owners_changed, actor_type: :user, meta: meta}] =
             activities(card)

    assert meta == %{"action" => "added", "owner" => "AI"}
  end

  test "adding an existing owner logs nothing new", %{stage: stage, user: user} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})
    {:ok, card} = Cards.add_owner(card, {:user, user.id})

    {:ok, card} = Cards.add_owner(card, {:user, user.id})

    assert Enum.map(activities(card), & &1.type) == [:created, :owners_changed]
  end

  test "remove_owner/3 logs the user's name; a no-op remove logs nothing", %{stage: stage, user: user} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})
    {:ok, card} = Cards.add_owner(card, {:user, user.id})

    {:ok, card} = Cards.remove_owner(card, {:user, user.id})
    {:ok, card} = Cards.remove_owner(card, {:user, user.id})

    assert [_created, _added, %Schemas.Activity{type: :owners_changed, meta: meta}] = activities(card)
    assert meta == %{"action" => "removed", "owner" => "Ada Lovelace"}
  end

  test "set_owners/3 logs the new owner labels", %{stage: stage, user: user} do
    {:ok, card} = Cards.create_card(stage, %{title: "T"})

    {:ok, card} = Cards.set_owners(card, [:agent, {:user, user.id}], {:user, user.id})

    assert [_created, %Schemas.Activity{type: :owners_changed, meta: meta}] = activities(card)
    assert meta == %{"action" => "set", "owners" => ["AI", "Ada Lovelace"]}
  end
  ```

  Run them (fail), then implement — replace the three owner functions:

  ```elixir
  def set_owners(%Card{} = card, actors, actor \\ :agent) when is_list(actors) do
    Repo.transaction(fn ->
      Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id)
      Enum.each(actors, &insert_owner_or_rollback(card, &1))
      log_owners_changed(card, actor, %{"action" => "set", "owners" => Enum.map(actors, &owner_label/1)})
      reload_with_owners(card)
    end)
  end

  def add_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    already_owner? = Repo.exists?(owner_query(card, owner_actor))

    case insert_owner(card, owner_actor) do
      {:ok, _owner} ->
        if not already_owner? do
          log_owners_changed(card, actor, %{"action" => "added", "owner" => owner_label(owner_actor)})
        end

        {:ok, reload_with_owners(card)}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  def remove_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    {deleted, _} = Repo.delete_all(owner_query(card, owner_actor))

    if deleted > 0 do
      log_owners_changed(card, actor, %{"action" => "removed", "owner" => owner_label(owner_actor)})
    end

    {:ok, reload_with_owners(card)}
  end
  ```

  plus the privates:

  ```elixir
  defp log_owners_changed(%Card{} = card, actor, meta) do
    {:ok, _entry} = Activity.log(card, %{type: :owners_changed, actor: actor, meta: meta})
  end

  # The label snapshotted into owners_changed meta — how the timeline
  # phrases the changed owner ("added AI as owner", "removed Ada …").
  defp owner_label(:agent), do: "AI"

  defp owner_label({:user, user_id}) do
    user = Repo.get!(User, user_id)
    user.name || user.email
  end
  ```

  Update the three `@doc`s (acting `actor` + when `:owners_changed` is logged; ok no-ops log
  nothing). Rename the arity-bearing `describe` strings in `test/relay/cards_test.exs`
  (`"create_card/2"` → `"create_card/3"`, `"move_card/3"` → `"move_card/4"`,
  `"set_status/2"` → `"set_status/3"`) and the `add_owner/2` / `remove_owner/2` /
  `set_owners/2` mentions inside the `"owner management"` test names to `/3`. Run
  `mix test test/relay/cards_test.exs` — green.

- [ ] **TDD cycle 4 — web attribution.** The LiveView must attribute actions to the
  signed-in human. Append to `test/relay_web/live/board_live_test.exs` (it already aliases
  `Relay.Boards`, `Relay.Cards`, `Relay.Repo`; reference the schema fully-qualified):

  ```elixir
  describe "activity attribution" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog | _rest] = board.stages
      %{board: board, backlog: backlog}
    end

    test "creating a card via the composer logs :created attributed to the signed-in user",
         %{conn: conn, user: user} do
      {:ok, view, _html} = live(conn, ~p"/board")

      view |> element("#stage-col-1-new-card") |> render_click()

      view
      |> form("#stage-col-1-compose-form", card: %{title: "Attributed"})
      |> render_submit()

      assert [%Schemas.Activity{type: :created, actor_type: :user, user_id: user_id}] =
               Repo.all(Schemas.Activity)

      assert user_id == user.id
    end

    test "drawer actions (status, owners, move) log user-attributed entries",
         %{conn: conn, user: user, board: board, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Card"})
      [_backlog, spec | _rest] = board.stages

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-status-form", card: %{status: "in_review"})
      |> render_change()

      view |> element("#card-drawer-add-me") |> render_click()
      view |> element("#card-drawer-move-to-#{spec.id}") |> render_click()

      entries = Repo.all(from a in Schemas.Activity, where: a.card_id == ^card.id, order_by: a.id)

      assert Enum.map(entries, & &1.type) == [:created, :status_changed, :owners_changed, :moved]

      [_created | user_entries] = entries
      assert Enum.all?(user_entries, &(&1.actor_type == :user and &1.user_id == user.id))
    end
  end
  ```

  (`board_live_test.exs` needs `import Ecto.Query` — add it under the existing
  `import Phoenix.LiveViewTest` if not already present.)

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — the new tests fail
  (everything is still agent-attributed). Then update `lib/relay_web/live/board_live.ex`:
  add a tiny private

  ```elixir
  # Every action taken in this LiveView is attributed to the signed-in
  # human; the :agent default on the Cards mutators is the API's (MMF 09).
  defp current_actor(socket), do: {:user, socket.assigns.current_scope.user.id}
  ```

  and thread it through all six mutator call sites:
  - `Cards.create_card(stage, card_params)` → `Cards.create_card(stage, card_params, current_actor(socket))`
  - `Cards.move_card(card, stage, index)` → `Cards.move_card(card, stage, index, current_actor(socket))`
  - `Cards.set_status(card, card_params)` → `Cards.set_status(card, card_params, current_actor(socket))`
  - both `Cards.add_owner(card, ...)` calls → `Cards.add_owner(card, :agent, current_actor(socket))`
    / `Cards.add_owner(card, actor, current_actor(socket))`
  - `Cards.remove_owner(card, actor)` → `Cards.remove_owner(card, actor, current_actor(socket))`

  (`update_card/2` is untouched — title/description edits are not logged in MMF 07.)
- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — green.
- [ ] Run `mix precommit` and fix anything it flags.
- [ ] Commit.

**Deliverable:** creating, moving (cross-stage), status-changing, and owner-changing a card
each append exactly the right `Schemas.Activity` row with the right actor — proven by context
tests AND LiveView integration tests; the full suite and `mix precommit` are green.

**Commit message:** `feat(cards): emit activity entries for create/move/status/owner changes (MMF 07)`

---

### Task 3: Drawer timeline UI — one interleaved timeline + comment composer

One vertical slice: the card drawer renders `Activity.list_timeline/1` as a single LiveView
stream (comments and activity merged chronologically), each entry showing an author identity
("Relay AI" for the agent, initials + name for users), a timestamp, and either the comment
body or a system phrase; plus a composer that posts via `Activity.add_comment/2` and appends
live. Status/owner/move changes made while the drawer is open refresh the timeline.

**Files**

- Modify: `lib/relay_web/components/core_components.ex` (`card_drawer/1` gains the timeline
  section + composer; new private helpers)
- Modify: `lib/relay_web/live/board_live.ex` (timeline stream, comment form + handlers,
  timeline refresh on status/owner/move)
- Modify: `storybook/core_components/card_drawer.story.exs` (new required attrs)
- Modify: `test/relay_web/live/board_live_test.exs` (new `describe "card timeline"`)

**Interfaces**

- Consumes (exact names from Tasks 1–2):
  - `Relay.Activity.list_timeline(card)` → `[%Schemas.Comment{} | %Schemas.Activity{}]`
    ascending by `inserted_at`, `:user` preloaded.
  - `Relay.Activity.add_comment(card, %{actor: {:user, id}, body: binary | nil})` →
    `{:ok, %Schemas.Comment{}}` (user preloaded) | `{:error, changeset}`
  - `Cards.set_status/3`, `Cards.add_owner/3`, `Cards.remove_owner/3`, `Cards.move_card/4`
    (already wired with `current_actor(socket)` in Task 2).
  - `current_actor(socket)` — private in `BoardLive` from Task 2, returns
    `{:user, current_user_id}`; reuse it in the `"post_comment"` handler.
  - Activity meta shapes from Task 2: `%{"from_stage", "to_stage"}`,
    `%{"from_status", "to_status"}`, `%{"action" => "added"|"removed", "owner" => label}`,
    `%{"action" => "set", "owners" => [labels]}`.
  - Factories `insert(:comment, ...)` / `insert(:activity, ...)` from Task 1.
- Produces:
  - `card_drawer/1` gains two required attrs: `timeline` (`:any` — the `@streams.timeline`
    LiveView stream, or a `[{dom_id, entry}]` list in Storybook) and `comment_form` (`:any` —
    a form for `comment[body]`). New DOM ids inside the drawer: `#<id>-timeline` (the
    `phx-update="stream"` container whose children are `#timeline-comment-<id>` /
    `#timeline-activity-<id>`), `#<id>-comment-form`, `#<id>-comment-input`. Entry classes:
    `.timeline-entry`, `.timeline-author`, `.timeline-time`, `.timeline-comment-body`,
    `.timeline-activity-phrase`.
  - `BoardLive` events: `"validate_comment"` and `"post_comment"` (form params
    `%{"comment" => %{"body" => ...}}`); new assign `:comment_form`; stream `:timeline`
    configured with `dom_id: &timeline_dom_id/1`.
  - System phrases (rendered by `activity_phrase/1`): `created this card`,
    `moved <from> → <to>`, `set status to <to_status>`, `added <owner> as owner`,
    `removed <owner> as owner`, `set owners to <a, b>`, `cleared the owners`, `commented`
    (defensive fallback for the reserved `:commented` type). Agent author renders as
    `Relay AI`; user author as `name || email` with an initials avatar.

**Steps**

- [ ] **TDD cycle 1 — timeline rendering + composer.** Append to
  `test/relay_web/live/board_live_test.exs` (add `alias Schemas.Comment` to the existing
  alias block at the top):

  ```elixir
  describe "card timeline" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, _spec, plan | _rest] = board.stages
      {:ok, card} = Cards.create_card(backlog, %{title: "Draft the spec"})
      %{board: board, backlog: backlog, plan: plan, card: card}
    end

    test "the drawer shows the agent-attributed created entry", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(
               view,
               "#card-drawer-timeline .timeline-activity-phrase",
               "created this card"
             )

      assert has_element?(view, "#card-drawer-timeline .timeline-author", "Relay AI")
    end

    test "a card with no history shows the empty state", %{conn: conn, backlog: backlog} do
      insert(:card, stage: backlog, title: "Bare", ref_number: 500, position: 5)

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-500")

      assert has_element?(view, "#card-drawer-timeline", "No activity yet")
    end

    test "posting a comment persists it and appends it with author and timestamp",
         %{conn: conn, user: user, card: card} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-comment-form", comment: %{body: "Looks good to me"})
      |> render_submit()

      assert [comment] = Repo.all(Comment)
      assert comment.card_id == card.id
      assert comment.actor_type == :user
      assert comment.user_id == user.id
      assert comment.body == "Looks good to me"

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-comment-body",
               "Looks good to me"
             )

      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", user.name)

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-time",
               Calendar.strftime(comment.inserted_at, "%b %d, %H:%M")
             )
    end

    test "a blank comment is rejected and persists nothing", %{conn: conn} do
      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      view
      |> form("#card-drawer-comment-form", comment: %{body: ""})
      |> render_submit()

      assert has_element?(view, "#card-drawer-comment-form", "can't be blank")
      assert Repo.aggregate(Comment, :count) == 0
    end

    test "an agent-authored comment renders with the Relay AI identity",
         %{conn: conn, card: card} do
      comment = insert(:comment, card: card, body: "Implemented — ready for review.")

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")

      assert has_element?(
               view,
               "#timeline-comment-#{comment.id} .timeline-comment-body",
               "Implemented — ready for review."
             )
    end
  end
  ```

  (The factory card must set an explicit `ref_number` — the factory's own sequence would
  collide with the context-allocated ref 1 on this board.)

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — the new describe fails.

- [ ] Implement the LiveView side in `lib/relay_web/live/board_live.ex`:
  1. `alias Relay.Activity` (alias block, sorted).
  2. In `mount/3`, configure the stream before anything streams into it (after the
     `assign(:compose_form, ...)` line, before the per-stage `Enum.reduce`):

     ```elixir
     |> stream_configure(:timeline, dom_id: &timeline_dom_id/1)
     ```

  3. In `assign_selected_card/2`, the `%Card{}` branch gains:

     ```elixir
     |> assign(:comment_form, empty_comment_form())
     |> stream(:timeline, Activity.list_timeline(card), reset: true)
     ```

     and the `nil` branch adds `comment_form: nil` to its `assign` keyword list plus a final
     `|> stream(:timeline, [], reset: true)` (pipe the `assign(socket, ...)` result into it).
  4. New event handlers (place next to the other drawer handlers; mirrors the card
     composer's validate-tracking pattern so the input clears after posting):

     ```elixir
     def handle_event("validate_comment", %{"comment" => comment_params}, socket) do
       {:noreply, assign(socket, :comment_form, to_form(comment_params, as: :comment))}
     end

     def handle_event(
           "post_comment",
           %{"comment" => comment_params},
           %{assigns: %{selected_card: %Card{} = card}} = socket
         ) do
       case Activity.add_comment(card, %{actor: current_actor(socket), body: comment_params["body"]}) do
         {:ok, comment} ->
           {:noreply,
            socket
            |> stream_insert(:timeline, comment)
            |> assign(:comment_form, empty_comment_form())}

         {:error, changeset} ->
           {:noreply, assign(socket, :comment_form, to_form(changeset))}
       end
     end

     def handle_event("post_comment", _params, socket), do: {:noreply, socket}
     ```

  5. New privates:

     ```elixir
     defp empty_comment_form, do: to_form(%{"body" => ""}, as: :comment)

     defp timeline_dom_id(%Schemas.Comment{id: id}), do: "timeline-comment-#{id}"
     defp timeline_dom_id(%Schemas.Activity{id: id}), do: "timeline-activity-#{id}"
     ```

  6. Pass the new attrs in `render/1`'s `<.card_drawer ...>` call:

     ```heex
     timeline={@streams.timeline}
     comment_form={@comment_form}
     ```

- [ ] Implement the component side in `lib/relay_web/components/core_components.ex`:
  1. Add `alias Schemas.Activity` and `alias Schemas.Comment` to the alias block (sorted).
  2. Add the two attrs to `card_drawer/1` (after `attr :status_form, ...`):

     ```elixir
     attr :timeline, :any,
       required: true,
       doc: "the :timeline LiveView stream — comments + activity entries merged chronologically"

     attr :comment_form, :any, required: true, doc: "a Phoenix.HTML.Form for comment[body]"
     ```

     and extend the component's `@doc` events list with `"validate_comment"` /
     `"post_comment"` (form params `comment[body]`).
  3. Add the timeline section inside the `<aside>`, after the closing `</dl>` of the
     properties rail:

     ```heex
     <section class="space-y-3 border-t border-base-300 pt-4">
       <h4 class="text-xs font-semibold uppercase tracking-wider text-base-content/60">
         Activity
       </h4>
       <ol id={"#{@id}-timeline"} phx-update="stream" class="space-y-3">
         <li class="hidden text-sm text-base-content/50 only:block">No activity yet</li>
         <li
           :for={{dom_id, entry} <- @timeline}
           id={dom_id}
           class="timeline-entry flex items-start gap-2"
           data-actor-type={entry.actor_type}
         >
           <span class={[
             "timeline-avatar flex size-6 shrink-0 items-center justify-center rounded-full text-[10px] font-semibold",
             if(entry.actor_type == :agent, do: "bg-secondary/15 text-secondary", else: "bg-primary/15 text-primary")
           ]}>
             {timeline_initials(entry)}
           </span>
           <div class="min-w-0 flex-1 space-y-0.5">
             <div class="flex items-baseline gap-2">
               <span class="timeline-author text-sm font-medium">{timeline_author(entry)}</span>
               <time class="timeline-time text-xs text-base-content/50">
                 {Calendar.strftime(entry.inserted_at, "%b %d, %H:%M")}
               </time>
             </div>
             <%= case entry do %>
               <% %Comment{} = comment -> %>
                 <p
                   class="timeline-comment-body whitespace-pre-wrap text-sm leading-relaxed"
                   phx-no-format
                 >{comment.body}</p>
               <% %Activity{} = activity -> %>
                 <p class="timeline-activity-phrase text-sm text-base-content/70">
                   {activity_phrase(activity)}
                 </p>
             <% end %>
           </div>
         </li>
       </ol>
       <.form
         for={@comment_form}
         id={"#{@id}-comment-form"}
         phx-change="validate_comment"
         phx-submit="post_comment"
       >
         <.input
           field={@comment_form[:body]}
           type="textarea"
           id={"#{@id}-comment-input"}
           rows="2"
           placeholder="Write a comment…"
         />
         <.button variant="primary" class="btn btn-primary btn-sm">Comment</.button>
       </.form>
     </section>
     ```

  4. New privates (near `owner_name/1`):

     ```elixir
     defp timeline_author(%{actor_type: :agent}), do: "Relay AI"
     defp timeline_author(%{actor_type: :user, user: user}), do: user.name || user.email

     defp timeline_initials(%{actor_type: :agent}), do: "AI"

     defp timeline_initials(%{actor_type: :user, user: user}) do
       (user.name || user.email)
       |> String.split(~r/\s+/, trim: true)
       |> Enum.map(&String.first/1)
       |> Enum.take(2)
       |> Enum.join()
       |> String.upcase()
     end

     defp activity_phrase(%Activity{type: :created}), do: "created this card"

     defp activity_phrase(%Activity{type: :moved, meta: meta}),
       do: "moved #{meta["from_stage"]} → #{meta["to_stage"]}"

     defp activity_phrase(%Activity{type: :status_changed, meta: meta}),
       do: "set status to #{meta["to_status"]}"

     defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "added"} = meta}),
       do: "added #{meta["owner"]} as owner"

     defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "removed"} = meta}),
       do: "removed #{meta["owner"]} as owner"

     defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "set", "owners" => []}}),
       do: "cleared the owners"

     defp activity_phrase(%Activity{type: :owners_changed, meta: %{"action" => "set", "owners" => owners}}),
       do: "set owners to #{Enum.join(owners, ", ")}"

     defp activity_phrase(%Activity{type: :commented}), do: "commented"
     ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — cycle 1 green.

- [ ] **TDD cycle 2 — live refresh + interleaving.** Append inside
  `describe "card timeline"`:

  ```elixir
  test "changing status in the open drawer appends the activity entry live", %{conn: conn} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view
    |> form("#card-drawer-status-form", card: %{status: "in_review"})
    |> render_change()

    assert has_element?(
             view,
             "#card-drawer-timeline .timeline-activity-phrase",
             "set status to in_review"
           )
  end

  test "adding an owner in the open drawer appends the activity entry live",
       %{conn: conn, user: user} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#card-drawer-add-me") |> render_click()

    assert has_element?(
             view,
             "#card-drawer-timeline .timeline-activity-phrase",
             "added #{user.name} as owner"
           )
  end

  test "moving from the open drawer appends the moved entry live", %{conn: conn, plan: plan} do
    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

    view |> element("#card-drawer-move-to-#{plan.id}") |> render_click()

    assert has_element?(
             view,
             "#card-drawer-timeline .timeline-activity-phrase",
             "moved Backlog → Plan"
           )
  end

  test "comments and activity interleave in chronological order",
       %{conn: conn, user: user, backlog: backlog} do
    card = insert(:card, stage: backlog, title: "History", ref_number: 501, position: 6)
    c1 = insert(:comment, card: card, user: user, body: "Kickoff", inserted_at: ~U[2026-07-01 09:00:00Z])
    a1 = insert(:activity, card: card, inserted_at: ~U[2026-07-02 09:00:00Z])
    c2 = insert(:comment, card: card, body: "Done", inserted_at: ~U[2026-07-03 09:00:00Z])

    {:ok, view, _html} = live(conn, ~p"/board?card=RLY-501")

    ids =
      view
      |> render()
      |> LazyHTML.from_fragment()
      |> LazyHTML.query("#card-drawer-timeline > li[id]")
      |> LazyHTML.attribute("id")

    assert ids == [
             "timeline-comment-#{c1.id}",
             "timeline-activity-#{a1.id}",
             "timeline-comment-#{c2.id}"
           ]
  end
  ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — the three live-refresh tests
  fail (the timeline stream isn't refreshed after drawer actions; the interleave test should
  already pass — if it fails, fix rendering/ordering, not the test). Implement in
  `lib/relay_web/live/board_live.ex`:
  1. `refresh_card/2` (used by status + owner changes) re-streams the timeline:

     ```elixir
     defp refresh_card(socket, %Card{} = card) do
       socket
       |> assign(:selected_card, card)
       |> assign(:status_form, status_form(card))
       |> stream(:timeline, Activity.list_timeline(card), reset: true)
       |> stream_insert(stream_name(card.stage_id), card)
     end
     ```

  2. `refresh_selected_after_move/2`'s matching branch also re-streams:

     ```elixir
     %Card{id: ^moved_id} ->
       socket
       |> assign(:selected_card, moved)
       |> assign(:selected_stage, find_stage_by_id(socket, moved.stage_id))
       |> stream(:timeline, Activity.list_timeline(moved), reset: true)
     ```

- [ ] Run `mix test test/relay_web/live/board_live_test.exs` — green.

- [ ] Update `storybook/core_components/card_drawer.story.exs` — both variations gain the
  two new required attrs. Variation `:viewing` gets:

  ```elixir
  timeline: story_timeline(),
  comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment),
  ```

  Variation `:editing_description` gets:

  ```elixir
  timeline: [],
  comment_form: Phoenix.Component.to_form(%{"body" => ""}, as: :comment),
  ```

  and add the private (structs, not maps — the component pattern-matches on them):

  ```elixir
  defp story_timeline do
    ada = %Schemas.User{id: 1, name: "Ada Lovelace", email: "ada@example.com"}

    [
      {"timeline-activity-1",
       %Schemas.Activity{id: 1, type: :created, meta: %{}, actor_type: :user, user: ada, inserted_at: ~U[2026-07-01 09:00:00Z]}},
      {"timeline-comment-1",
       %Schemas.Comment{id: 1, actor_type: :user, user: ada, body: "Kicking this off — spec draft attached.", inserted_at: ~U[2026-07-02 10:15:00Z]}},
      {"timeline-activity-2",
       %Schemas.Activity{id: 2, type: :moved, meta: %{"from_stage" => "Spec", "to_stage" => "Code"}, actor_type: :agent, user: nil, inserted_at: ~U[2026-07-03 11:00:00Z]}},
      {"timeline-comment-2",
       %Schemas.Comment{id: 2, actor_type: :agent, user: nil, body: "Implemented the drawer — ready for review.", inserted_at: ~U[2026-07-06 15:30:00Z]}}
    ]
  end
  ```

  Verify the story renders: `mix phx.server`, visit
  `/storybook/core_components/card_drawer` — the `:viewing` variation shows the four-entry
  timeline + composer, `:editing_description` shows "No activity yet".

- [ ] Run the full suite (`mix test`) then `mix precommit`; fix anything flagged.
- [ ] Commit. In the final hand-off message, tell the user the `card_drawer` story was
  refreshed and link it: `/storybook/core_components/card_drawer` (project rule for reusable
  components).

**Deliverable:** opening a card's drawer shows one interleaved, chronologically-ordered
timeline of comments and activity; posting a comment persists and appends live with the
author + timestamp; status/owner/move changes append their system phrases live; an
agent-authored comment renders as "Relay AI" — all proven by LiveView tests; full suite and
`mix precommit` green; the Storybook story renders both drawer variations.

**Commit message:** `feat(board): interleaved comments + activity timeline in the card drawer (MMF 07)`

---

## Spec coverage map (every requirement → a task)

- New `Relay.Activity` context, own boundary, exported → Task 1.
- `Schemas.Comment` / `Schemas.Activity` fields + enum (incl. reserved `:commented`) → Task 1.
- `add_comment/2`, `log/2`, `list_timeline/1` (merged, chronological, actor preloaded) → Task 1.
- Domain emits (create `:created`, move `:moved` w/ from/to stage replacing the MMF 05 seam,
  `:status_changed` w/ from/to, `:owners_changed`), actor on every emit, `Cards` → `Activity`
  boundary dep, no cycle → Task 2.
- Acceptance: "Posting a comment persists it and shows it with author + timestamp" → Task 3
  (`posting a comment persists it and appends it with author and timestamp`).
- Acceptance: "Moving a card or changing its status/owners appends an activity entry
  automatically" → Task 2 (persistence) + Task 3 (drawer shows it live).
- Acceptance: "Timeline entries render merged in chronological order" → Task 1
  (`list_timeline/1`) + Task 3 (interleave DOM test).
- Acceptance: "A comment authored by the agent renders with the Relay AI identity" → Task 3.
- Out of scope honored: no rich AI blocks, no mentions/notifications, no edit/delete, no API.
