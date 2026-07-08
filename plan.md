# Plan: MMF 18 — Real-time board sync

**Spec:** `docs/superpowers/specs/2026-07-08-realtime-sync-design.md`
**MMF:** `docs/mmfs/18-realtime-sync.md` · **Branch strategy:** trunk-based on `main`

## Goal

The board becomes alive: when anyone — another browser session, or the agent via the REST
API (MMF 09) — moves a card, changes status/owners, posts a comment, or edits stage config,
every open `RelayWeb.BoardLive` for that board applies the change instantly, no reload. One
notification seam in the domain layer serves both the LiveView and API entry points.

## Architecture

- **`Relay.Events`** (`lib/relay/events.ex`) — a new, tiny sub-boundary over
  **Phoenix.PubSub** (the `Relay.PubSub` server already in `Relay.Application`'s
  supervision tree). Two functions: `subscribe(board_id)` and `broadcast(board_id, event)`.
  Topic: `"board:<board_id>"` — board-scoped, so a session receives everything for its own
  board and nothing else.
- **Semantic events, broadcast from the CONTEXTS** (`Relay.Cards`, `Relay.Boards`,
  `Relay.Activity`) after each successful mutation — never from controllers or LiveViews —
  so the LiveView and the REST API share one notification path:
  - `{:card_upserted, card}` — create, title/description/tag edit, status, owners (card
    with owners preloaded).
  - `{:card_moved, card, from_stage_id}` — cross- or within-stage move.
  - `{:timeline_appended, card_id, entry}` — a new comment or activity entry (the
    `Schemas.Comment` / `Schemas.Activity` struct itself, `:user` preloaded).
  - `{:stages_changed, board_id}` — any stage/config change (lanes today) — coarse on
    purpose: receivers refetch stages.
- **Everyone applies broadcasts, including the acting session.** The actor's own
  `handle_event` already updates its socket; the echoed broadcast is applied idempotently
  (streams upsert by DOM id; counts/stages are recomputed from the DB, not incremented), so
  double-apply is harmless and there is no "skip self" bookkeeping.
- **Idempotent application in `BoardLive.handle_info/2`**, reusing the existing private
  helpers (`apply_move/3`, `restream_stage/3`, `stage_counts/2`, `stream_name/1`,
  `refresh_card/2`, `group_stages/1`, `sublanes_by_parent/1`).
- **Commit-then-broadcast for card events:** `Relay.Cards` mutations that run in a
  `Repo.transaction` broadcast their `card_*` event only after the transaction returns
  `{:ok, card}` (i.e. after commit), because `card_*` receivers re-read the DB.
  `timeline_appended` is broadcast by `Relay.Activity` at the `log`/`add_comment` call site
  (which for entries logged inside a Cards transaction is just before commit); that is safe
  because `timeline_appended` receivers apply the payload struct directly and never re-read
  the DB for it.
- **Fire-and-forget:** `Relay.Events.broadcast/2` swallows PubSub errors and always returns
  `:ok`, so a broadcast failure can never fail the mutation that triggered it.

## Tech

Elixir / Phoenix v1.8, Phoenix LiveView (streams), Phoenix.PubSub (`Relay.PubSub`), Ecto +
Postgres, `boundary` (compiler-enforced context boundaries), ExUnit +
`Phoenix.LiveViewTest` + `Phoenix.ConnTest` + ExMachina factories (`Relay.Factory`),
LazyHTML for DOM assertions.

## Global Constraints

- `mix precommit` is REQUIRED on every development cycle and must pass before work is
  considered done. It runs compile (warnings as errors), `mix format` (with Styler),
  `mix credo --strict`, `mix sobelow`, `mix deps.audit`, and the full test suite (warnings
  as errors). Fix any failure before finishing.
- **Boundaries are enforced by the compiler.** `Relay.Events` is its own sub-boundary
  declared with `use Boundary` and added to `Relay`'s `exports` in `lib/relay.ex`.
  `Relay.Cards` / `Relay.Boards` / `Relay.Activity` add `Relay.Events` to their boundary
  `deps`. The web layer reaches it through `Relay`'s exports (RelayWeb already has
  `deps: [Relay, Schemas]`). A boundary violation fails compilation.
- **Broadcasts originate in the contexts** — never in controllers or LiveViews — so every
  API-driven mutation (MMF 09) and every future context mutation (MMFs 11–16) is live by
  construction.
- **Broadcast failures never fail the mutation** (fire-and-forget after commit).
- **Board-scoped topics** — no cross-board leakage.
- LiveView stream rules: streams upsert by DOM id; streams cannot be counted or filtered —
  counts live in the `@stage_counts` assign recomputed from the DB; reordering requires a
  full re-stream with `reset: true`.
- Follow all conventions in `AGENTS.md` (Styler-formatted code, no `is_`-prefixed
  predicates, `start_supervised!/1` in tests, no `Process.sleep/1`, etc.).

**Acceptance criteria (from the MMF — every one must be covered by a test):**

- [ ] A change in one session appears in another open session on the same board without reload.
- [ ] A move/comment/status change made via the API updates open boards live.
- [ ] Broadcasts are board-scoped (no cross-board leakage).
- [ ] Broadcasts originate in the contexts, so every future context mutation is live by
      construction.

---

### Task 1: `Relay.Events` PubSub seam + boundary wiring

**Files**

- Create: `lib/relay/events.ex`
- Modify: `lib/relay.ex` (add `Events` to `exports`)
- Create: `test/relay/events_test.exs`

**Interfaces**

- Consumes: `Relay.PubSub` — the `Phoenix.PubSub` server started in
  `lib/relay/application.ex` as `{Phoenix.PubSub, name: Relay.PubSub}` (already there; do
  not change the application).
- Produces (Tasks 2 and 3 rely on these exact signatures):
  - `Relay.Events.subscribe(board_id) :: :ok | {:error, term}` — subscribes the calling
    process to `"board:#{board_id}"`.
  - `Relay.Events.broadcast(board_id, event) :: :ok` — broadcasts `event` (any term) to
    every subscriber of `"board:#{board_id}"`; swallows errors, always returns `:ok`.

**Steps**

- [x] Write the failing unit test at `test/relay/events_test.exs`:

```elixir
defmodule Relay.EventsTest do
  use ExUnit.Case, async: true

  alias Relay.Events

  test "subscribe/1 then broadcast/2 delivers the event to the subscriber" do
    board_id = System.unique_integer([:positive])

    assert :ok = Events.subscribe(board_id)
    assert :ok = Events.broadcast(board_id, {:stages_changed, board_id})

    assert_receive {:stages_changed, ^board_id}
  end

  test "an event for one board is not delivered to another board's subscriber" do
    board_id = System.unique_integer([:positive])
    other_board_id = System.unique_integer([:positive])

    assert :ok = Events.subscribe(board_id)
    assert :ok = Events.broadcast(other_board_id, {:stages_changed, other_board_id})

    refute_receive {:stages_changed, _board_id}, 100
  end

  test "broadcast/2 with no subscribers still returns :ok (fire-and-forget)" do
    assert :ok = Events.broadcast(System.unique_integer([:positive]), {:card_upserted, nil})
  end
end
```

- [x] Run `mix test test/relay/events_test.exs` — expect failure (module
      `Relay.Events` does not exist).
- [x] Create `lib/relay/events.ex`:

```elixir
defmodule Relay.Events do
  @moduledoc """
  The realtime notification seam (MMF 18): board-scoped Phoenix.PubSub
  topics carrying semantic domain events from the contexts to every open
  `RelayWeb.BoardLive` (and any future subscriber).

  Topic: `"board:<board_id>"`. Event vocabulary — broadcast by the
  contexts after each successful mutation, never by controllers or
  LiveViews, so the LiveView and REST API entry points share one path:

    * `{:card_upserted, card}` — create or any in-place edit
      (title/description/tag, status, owners); `card` arrives with
      owners preloaded.
    * `{:card_moved, card, from_stage_id}` — cross- or within-stage move.
    * `{:timeline_appended, card_id, entry}` — a new `Schemas.Comment` or
      `Schemas.Activity` entry (with `:user` preloaded).
    * `{:stages_changed, board_id}` — any stage/config change; coarse on
      purpose, receivers refetch stages.

  Broadcasting is fire-and-forget: `broadcast/2` swallows PubSub errors
  and always returns `:ok`, so a broadcast failure can never fail the
  mutation that triggered it.
  """

  use Boundary, deps: []

  @pubsub Relay.PubSub

  @doc "Subscribes the calling process to `board_id`'s event topic."
  def subscribe(board_id) do
    Phoenix.PubSub.subscribe(@pubsub, topic(board_id))
  end

  @doc """
  Broadcasts `event` to every subscriber of `board_id`'s topic.
  Fire-and-forget: errors are swallowed and `:ok` is always returned.
  """
  def broadcast(board_id, event) do
    _ = Phoenix.PubSub.broadcast(@pubsub, topic(board_id), event)
    :ok
  end

  defp topic(board_id), do: "board:#{board_id}"
end
```

- [x] Export the new sub-boundary from `Relay` — in `lib/relay.ex` change:

```elixir
  use Boundary,
    deps: [Schemas],
    exports: [Repo, Mailer, Accounts, Activity, ApiKeys, Boards, Cards]
```

to:

```elixir
  use Boundary,
    deps: [Schemas],
    exports: [Repo, Mailer, Accounts, Activity, ApiKeys, Boards, Cards, Events]
```

- [x] Run `mix test test/relay/events_test.exs` — expect all 3 tests to pass.
- [x] Run `mix precommit` — expect a clean pass (compile with warnings-as-errors validates
      the boundary declarations).
- [x] Commit.

**Deliverable:** `Relay.Events.subscribe/1` + `broadcast/2` over `Relay.PubSub` on
board-scoped topics, exported from the `Relay` boundary, with unit tests proving delivery,
board scoping, and the fire-and-forget `:ok` contract.

**Commit message:** `feat(events): add Relay.Events PubSub seam for board-scoped realtime events`

---

### Task 2: broadcast semantic events from the contexts

**Files**

- Modify: `lib/relay/cards.ex`
- Modify: `lib/relay/activity.ex`
- Modify: `lib/relay/boards.ex`
- Create: `test/relay/context_broadcasts_test.exs`

**Interfaces**

- Consumes (from Task 1): `Relay.Events.broadcast(board_id, event) :: :ok`.
- Consumes (existing, signatures unchanged): `Relay.Cards.create_card/3`, `update_card/2`,
  `set_status/3`, `set_owners/3`, `add_owner/3`, `remove_owner/3`, `move_card/4` (all
  return `{:ok, %Schemas.Card{}}` with owners preloaded, or `{:error, changeset}`);
  `Relay.Activity.add_comment/2` and `log/2` (return `{:ok, entry}` with `:user`
  preloaded, or `{:error, changeset}`); `Relay.Boards.enable_lane/2` (returns
  `{:ok, %Schemas.Stage{}}`) and `disable_lane/2` (returns
  `{:ok, :disabled} | {:ok, :not_enabled} | {:error, :not_empty}`).
- Produces (Task 3 relies on these exact event shapes arriving on `"board:<board_id>"`):
  - `{:card_upserted, %Schemas.Card{}}` — after successful `create_card`, `update_card`,
    `set_status`, `set_owners`, `add_owner`, `remove_owner`; card has `owners: :user`
    preloaded.
  - `{:card_moved, %Schemas.Card{}, from_stage_id :: integer}` — after successful
    `move_card`; card has owners preloaded; `from_stage_id` is the stage the card was in
    before the move (equal to `card.stage_id` for a within-stage reorder).
  - `{:timeline_appended, card_id :: integer, entry}` — after successful `add_comment`
    (entry is a `%Schemas.Comment{}`) or `log` (entry is a `%Schemas.Activity{}`), both
    with `:user` preloaded.
  - `{:stages_changed, board_id :: integer}` — after `enable_lane` actually creates a lane
    or `disable_lane` actually removes one (idempotent no-ops broadcast nothing).

**Steps**

- [x] Write the failing context tests at `test/relay/context_broadcasts_test.exs`:

```elixir
defmodule Relay.ContextBroadcastsTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card

  setup do
    user = insert(:user)
    board = Boards.get_or_create_default_board(user)
    [backlog, spec | _rest] = board.stages
    :ok = Events.subscribe(board.id)
    %{user: user, board: board, backlog: backlog, spec: spec}
  end

  describe "Cards broadcasts" do
    test "create_card broadcasts {:card_upserted, card} with owners preloaded", %{backlog: backlog} do
      {:ok, %Card{id: card_id}} = Cards.create_card(backlog, %{title: "Live"})

      assert_receive {:card_upserted, %Card{id: ^card_id, title: "Live", owners: []}}
    end

    test "a failed create_card broadcasts no card event", %{backlog: backlog} do
      {:error, _changeset} = Cards.create_card(backlog, %{title: ""})

      refute_receive {:card_upserted, _card}, 100
    end

    test "update_card broadcasts {:card_upserted, card}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Old"})

      {:ok, _card} = Cards.update_card(card, %{title: "New"})

      assert_receive {:card_upserted, %Card{id: ^card_id, title: "New"}}
    end

    test "a failed update_card broadcasts no card event beyond the create", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Keep"})
      assert_receive {:card_upserted, %Card{id: ^card_id}}

      {:error, _changeset} = Cards.update_card(card, %{title: ""})

      refute_receive {:card_upserted, _card}, 100
    end

    test "set_status broadcasts {:card_upserted, card}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Status"})

      {:ok, _card} = Cards.set_status(card, %{"status" => "working", "progress" => "40"})

      assert_receive {:card_upserted, %Card{id: ^card_id, status: :working, progress: 40}}
    end

    test "set_owners, add_owner, and remove_owner broadcast {:card_upserted, card} with owners preloaded",
         %{backlog: backlog, user: user} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Owned"})

      {:ok, _card} = Cards.set_owners(card, [{:user, user.id}])
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: [%{actor_type: :user}]}}

      {:ok, _card} = Cards.add_owner(card, :agent)
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: owners}} when length(owners) == 2

      {:ok, _card} = Cards.remove_owner(card, :agent)
      assert_receive {:card_upserted, %Card{id: ^card_id, owners: [%{actor_type: :user}]}}
    end

    test "move_card broadcasts {:card_moved, moved, from_stage_id}", %{backlog: backlog, spec: spec} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Mover"})
      backlog_id = backlog.id
      spec_id = spec.id

      {:ok, _moved} = Cards.move_card(card, spec, 0)

      assert_receive {:card_moved, %Card{id: ^card_id, stage_id: ^spec_id, owners: []}, ^backlog_id}
    end

    test "a within-stage reorder broadcasts {:card_moved, moved, same_stage_id}", %{backlog: backlog} do
      {:ok, _first} = Cards.create_card(backlog, %{title: "First"})
      {:ok, %Card{id: card_id} = second} = Cards.create_card(backlog, %{title: "Second"})
      backlog_id = backlog.id

      {:ok, _moved} = Cards.move_card(second, backlog, 0)

      assert_receive {:card_moved, %Card{id: ^card_id, stage_id: ^backlog_id}, ^backlog_id}
    end
  end

  describe "Activity broadcasts" do
    test "add_comment broadcasts {:timeline_appended, card_id, comment}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Talk"})

      {:ok, %{id: comment_id}} = Activity.add_comment(card, %{actor: :agent, body: "hello"})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Comment{id: ^comment_id, body: "hello"}}
    end

    test "a failed add_comment broadcasts nothing new", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Quiet"})
      assert_receive {:timeline_appended, ^card_id, _entry}

      {:error, _changeset} = Activity.add_comment(card, %{actor: :agent, body: ""})

      refute_receive {:timeline_appended, _card_id, _entry}, 100
    end

    test "log broadcasts {:timeline_appended, card_id, entry}", %{backlog: backlog} do
      {:ok, %Card{id: card_id} = card} = Cards.create_card(backlog, %{title: "Log"})

      {:ok, %{id: entry_id}} = Activity.log(card, %{type: :commented, actor: :agent})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{id: ^entry_id, type: :commented}}
    end

    test "card mutations that log also broadcast the timeline entry (create -> :created)",
         %{backlog: backlog} do
      {:ok, %Card{id: card_id}} = Cards.create_card(backlog, %{title: "Created"})

      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :created}}
    end
  end

  describe "Boards broadcasts" do
    test "enable_lane broadcasts {:stages_changed, board_id} only when it creates the lane",
         %{board: board} do
      board_id = board.id
      code = Enum.find(board.stages, &(&1.name == "Code"))

      {:ok, _review} = Boards.enable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, _existing} = Boards.enable_lane(code, :review)
      refute_receive {:stages_changed, ^board_id}, 100
    end

    test "disable_lane broadcasts only when it actually removes the lane", %{board: board} do
      board_id = board.id
      code = Enum.find(board.stages, &(&1.name == "Code"))
      {:ok, _review} = Boards.enable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, :disabled} = Boards.disable_lane(code, :review)
      assert_receive {:stages_changed, ^board_id}

      {:ok, :not_enabled} = Boards.disable_lane(code, :review)
      refute_receive {:stages_changed, ^board_id}, 100
    end
  end
end
```

- [x] Run `mix test test/relay/context_broadcasts_test.exs` — expect every test to fail on
      `assert_receive` timeouts (nothing broadcasts yet).
- [x] Wire `Relay.Cards` (`lib/relay/cards.ex`). Change its boundary declaration and
      aliases — replace:

```elixir
  use Boundary, deps: [Relay.Activity, Relay.Boards, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Repo
```

with:

```elixir
  use Boundary, deps: [Relay.Activity, Relay.Boards, Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Events
  alias Relay.Repo
```

- [x] In `lib/relay/cards.ex`, replace the body of `create_card/3` (keep its `@doc`) so the
      broadcast fires after the transaction commits:

```elixir
  def create_card(%Stage{} = stage, attrs, actor \\ :agent) do
    result =
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

    broadcast_upserted(result)
  end
```

- [x] In `lib/relay/cards.ex`, append `|> broadcast_upserted()` to the `update_card/2` and
      `set_status/3` pipelines (keep the `@doc`s):

```elixir
  def update_card(%Card{} = card, attrs) do
    card
    |> Card.changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
    |> broadcast_upserted()
  end
```

```elixir
  def set_status(%Card{} = card, attrs, actor \\ :agent) do
    from_status = card.status

    card
    |> Card.status_changeset(attrs)
    |> Repo.update()
    |> preload_owners_result()
    |> log_status_changed(from_status, actor)
    |> broadcast_upserted()
  end
```

- [x] In `lib/relay/cards.ex`, replace the bodies of `set_owners/3`, `add_owner/3`, and
      `remove_owner/3` (keep their `@doc`s) so each broadcasts its `{:ok, card}` result
      (after the transaction commits, where there is one):

```elixir
  def set_owners(%Card{} = card, actors, actor \\ :agent) when is_list(actors) do
    result =
      Repo.transaction(fn ->
        Repo.delete_all(from o in CardOwner, where: o.card_id == ^card.id)
        Enum.each(actors, &insert_owner_or_rollback(card, &1))
        log_owners_changed(card, actor, %{"action" => "set", "owners" => Enum.map(actors, &owner_label/1)})
        reload_with_owners(card)
      end)

    broadcast_upserted(result)
  end
```

```elixir
  def add_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    already_owner? = Repo.exists?(owner_query(card, owner_actor))

    case insert_owner(card, owner_actor) do
      {:ok, _owner} ->
        if not already_owner? do
          log_owners_changed(card, actor, %{"action" => "added", "owner" => owner_label(owner_actor)})
        end

        broadcast_upserted({:ok, reload_with_owners(card)})

      {:error, changeset} ->
        {:error, changeset}
    end
  end
```

```elixir
  def remove_owner(%Card{} = card, owner_actor, actor \\ :agent) do
    {deleted, _} = Repo.delete_all(owner_query(card, owner_actor))

    if deleted > 0 do
      log_owners_changed(card, actor, %{"action" => "removed", "owner" => owner_label(owner_actor)})
    end

    broadcast_upserted({:ok, reload_with_owners(card)})
  end
```

- [x] In `lib/relay/cards.ex`, replace the body of `move_card/4` (keep its `@doc` and
      guard) so `{:card_moved, moved, previous_stage_id}` broadcasts after commit:

```elixir
  def move_card(%Card{board_id: board_id} = card, %Stage{board_id: board_id} = target_stage, index, actor \\ :agent)
      when is_integer(index) do
    previous_stage_id = card.stage_id

    result =
      Repo.transaction(fn ->
        moved = preload_owners(place_at(card, target_stage, index))

        if moved.stage_id != previous_stage_id do
          emit_stage_changed(moved, previous_stage_id, target_stage, actor)
        end

        moved
      end)

    case result do
      {:ok, moved} ->
        Events.broadcast(moved.board_id, {:card_moved, moved, previous_stage_id})
        {:ok, moved}

      {:error, _changeset} = error ->
        error
    end
  end
```

- [x] In `lib/relay/cards.ex`, add the broadcast helper among the private functions (e.g.
      right after `preload_owners_result/1`):

```elixir
  # MMF 18: announce a created/edited card to every open board session.
  # Called only after the mutation (and its transaction, where there is
  # one) has committed; Events.broadcast/2 is fire-and-forget.
  defp broadcast_upserted({:ok, %Card{} = card} = result) do
    Events.broadcast(card.board_id, {:card_upserted, card})
    result
  end

  defp broadcast_upserted({:error, _changeset} = result), do: result
```

- [x] Wire `Relay.Activity` (`lib/relay/activity.ex`). Replace:

```elixir
  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
```

with:

```elixir
  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
```

then append `|> broadcast_appended(card)` to both insert pipelines (keep the `@doc`s):

```elixir
  def add_comment(%Card{} = card, %{actor: actor} = attrs) do
    {actor_type, user_id} = split_actor(actor)

    %Comment{card_id: card.id, actor_type: actor_type, user_id: user_id}
    |> Comment.changeset(Map.take(attrs, [:body]))
    |> Repo.insert()
    |> preload_user()
    |> broadcast_appended(card)
  end
```

```elixir
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
    |> broadcast_appended(card)
  end
```

and add the private helper right before `split_actor/1`:

```elixir
  # MMF 18: announce the new timeline entry to every open board session.
  # Receivers apply the payload struct directly (no DB re-read), so this
  # is safe even when the log happens inside a caller's transaction.
  defp broadcast_appended({:ok, entry} = result, %Card{} = card) do
    Events.broadcast(card.board_id, {:timeline_appended, card.id, entry})
    result
  end

  defp broadcast_appended({:error, _changeset} = result, _card), do: result
```

- [x] Wire `Relay.Boards` (`lib/relay/boards.ex`). Replace:

```elixir
  use Boundary, deps: [Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Repo
```

with:

```elixir
  use Boundary, deps: [Relay.Events, Relay.Repo, Schemas]

  import Ecto.Query

  alias Relay.Events
  alias Relay.Repo
```

then replace the bodies of `enable_lane/2` and `disable_lane/2` (keep `@doc`s and guards)
so only an actual change broadcasts:

```elixir
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
        |> broadcast_stages_changed(parent.board_id)
    end
  end
```

```elixir
  def disable_lane(%Stage{} = parent, lane) when lane in [:review, :done] do
    case get_sublane(parent, lane) do
      nil ->
        {:ok, :not_enabled}

      %Stage{} = child ->
        if Repo.exists?(from c in Card, where: c.stage_id == ^child.id) do
          {:error, :not_empty}
        else
          {:ok, _} = Repo.delete(child)
          broadcast_stages_changed({:ok, :disabled}, parent.board_id)
        end
    end
  end
```

and add the private helper right after `get_sublane/2`:

```elixir
  # MMF 18: stage config changed — coarse event, receivers refetch stages.
  defp broadcast_stages_changed({:ok, _value} = result, board_id) do
    Events.broadcast(board_id, {:stages_changed, board_id})
    result
  end

  defp broadcast_stages_changed({:error, _reason} = result, _board_id), do: result
```

- [x] Run `mix test test/relay/context_broadcasts_test.exs` — expect all tests to pass.
- [x] Run `mix precommit` — the full existing suite must stay green (no public signature
      changed; return values are identical).
- [x] Commit.

**Deliverable:** every mutating context function announces its semantic event on the
board's topic after a successful mutation (post-commit for card events), idempotent no-ops
and failed mutations broadcast nothing, and context tests prove each event with
`assert_receive`. Because the REST API controllers call these same context functions, API
writes are broadcasting too — no controller changes needed.

**Commit message:** `feat(events): broadcast semantic board events from Cards, Boards, and Activity`

---

### Task 3: `BoardLive` subscribes and applies events live

**Files**

- Modify: `lib/relay_web/live/board_live.ex`
- Create: `test/relay_web/live/board_live_realtime_test.exs`

**Interfaces**

- Consumes (from Task 1): `Relay.Events.subscribe(board_id)`.
- Consumes (from Task 2): the four event shapes arriving as `handle_info/2` messages —
  `{:card_upserted, %Schemas.Card{}}`, `{:card_moved, %Schemas.Card{}, from_stage_id}`,
  `{:timeline_appended, card_id, entry}`, `{:stages_changed, board_id}`.
- Consumes (existing private helpers in `board_live.ex`, reused as-is): `apply_move/3`,
  `stage_counts/2`, `stream_name/1`, `refresh_card/2`, `group_stages/1`,
  `sublanes_by_parent/1`, `find_stage_by_id/2`.
- Produces: no new public interface — `handle_info/2` clauses plus three private helpers
  (`maybe_refresh_drawer/2`, `reload_board/1`, `refresh_selected_stage/1`).

**Steps**

- [x] Write the failing LiveView tests at
      `test/relay_web/live/board_live_realtime_test.exs`:

```elixir
defmodule RelayWeb.BoardLiveRealtimeTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Repo

  describe "two sessions on the same board" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "a card created in session A appears in session B with the count bumped", %{conn: conn} do
      {:ok, view_a, _html} = live(conn, ~p"/board")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      view_a |> element("#stage-col-1-new-card") |> render_click()
      view_a |> form("#stage-col-1-compose-form", card: %{title: "Broadcast me"}) |> render_submit()

      assert has_element?(view_b, "#stage-col-1-cards .board-card", "Broadcast me")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "1")
    end

    test "a move in session A restreams source and target in session B",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Pass the baton"})

      {:ok, view_a, _html} = live(conn, ~p"/board")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      render_hook(view_a, "move_card", %{"ref" => "RLY-1", "stage_id" => spec.id, "index" => 0})

      assert has_element?(view_b, "#stage-col-2-cards .board-card", "Pass the baton")
      refute has_element?(view_b, "#stage-col-1-cards .board-card")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "0")
      assert has_element?(view_b, "#stage-col-2 .stage-count", "1")
    end

    test "a status change in session A's drawer re-renders the board card in session B",
         %{conn: conn, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Needs a human"})

      {:ok, view_a, _html} = live(conn, ~p"/board?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board")

      view_a |> form("#card-drawer-status-form", card: %{status: "needs_input"}) |> render_change()

      assert has_element?(view_b, "#stage-col-1-cards .board-card .card-needs-input", "NEEDS INPUT")
    end

    test "a status change made elsewhere refreshes another session's open drawer",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Drawer sync"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      {:ok, _card} = Cards.set_status(card, %{"status" => "in_review"})

      assert has_element?(
               view_b,
               "#card-drawer-timeline .timeline-activity-phrase",
               "set status to in_review"
             )
    end

    test "an owner added elsewhere shows in another session's open drawer rail and board card",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Baton"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      {:ok, _card} = Cards.add_owner(card, :agent)

      assert has_element?(view_b, "#card-drawer-rail .rail-owner[data-actor-type='agent']")
      assert has_element?(view_b, "#stage-col-1-cards .board-card[data-active-owner='ai']")
    end

    test "a comment posted in session A appends to session B's open drawer timeline exactly once",
         %{conn: conn, backlog: backlog} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Chatty"})

      {:ok, view_a, _html} = live(conn, ~p"/board?card=RLY-1")
      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-1")

      view_a |> form("#card-drawer-comment-form", comment: %{body: "Live comment"}) |> render_submit()

      comment = Repo.get_by!(Schemas.Comment, body: "Live comment")

      assert has_element?(view_b, "#timeline-comment-#{comment.id} .timeline-comment-body", "Live comment")
      # the acting session receives its own echo — applied idempotently
      assert element_count(view_a, "#timeline-comment-#{comment.id}") == 1
    end

    test "a comment does not touch a session whose drawer shows a different card",
         %{conn: conn, backlog: backlog} do
      {:ok, card_one} = Cards.create_card(backlog, %{title: "One"})
      {:ok, _card_two} = Cards.create_card(backlog, %{title: "Two"})

      {:ok, view_b, _html} = live(conn, ~p"/board?card=RLY-2")

      {:ok, comment} = Activity.add_comment(card_one, %{actor: :agent, body: "For card one"})

      refute has_element?(view_b, "#timeline-comment-#{comment.id}")
    end

    test "enabling and disabling a lane restructures another open session", %{conn: conn, board: board} do
      code = Enum.find(board.stages, &(&1.name == "Code"))

      {:ok, view_b, _html} = live(conn, ~p"/board")

      {:ok, review} = Boards.enable_lane(code, :review)
      assert has_element?(view_b, "#sublane-#{review.id}-cards")

      {:ok, :disabled} = Boards.disable_lane(code, :review)
      refute has_element?(view_b, "#sublane-#{review.id}-cards")
    end
  end

  describe "board scoping" do
    setup :register_and_log_in_user

    test "a mutation on board A does not touch a session on board B", %{user: user} do
      board_a = Boards.get_or_create_default_board(user)
      [backlog_a | _rest] = board_a.stages

      other_user = insert(:user)
      _board_b = Boards.get_or_create_default_board(other_user)

      {:ok, view_b, _html} = live(log_in_user(build_conn(), other_user), ~p"/board")

      {:ok, _card} = Cards.create_card(backlog_a, %{title: "Only on A"})

      refute has_element?(view_b, ".board-card")
      assert has_element?(view_b, "#stage-col-1 .stage-count", "0")
    end
  end

  describe "idempotent event application" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      %{board: board, backlog: backlog, spec: spec}
    end

    test "applying the same card_upserted twice leaves a single card", %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Once"})

      {:ok, view, _html} = live(conn, ~p"/board")

      send(view.pid, {:card_upserted, card})
      send(view.pid, {:card_upserted, card})

      assert element_count(view, "#stage-col-1-cards .board-card") == 1
      assert has_element?(view, "#stage-col-1 .stage-count", "1")
    end

    test "applying the same card_moved twice leaves a single card in the target",
         %{conn: conn, backlog: backlog, spec: spec} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Mover"})

      {:ok, view, _html} = live(conn, ~p"/board")

      {:ok, moved} = Cards.move_card(card, spec, 0)

      send(view.pid, {:card_moved, moved, backlog.id})
      send(view.pid, {:card_moved, moved, backlog.id})

      assert element_count(view, "#stage-col-1-cards .board-card") == 0
      assert element_count(view, "#stage-col-2-cards .board-card") == 1
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "applying the same timeline_appended twice appends a single entry",
         %{conn: conn, backlog: backlog} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Talky"})
      {:ok, comment} = Activity.add_comment(card, %{actor: :agent, body: "Once only"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      send(view.pid, {:timeline_appended, card.id, comment})
      send(view.pid, {:timeline_appended, card.id, comment})

      assert element_count(view, "#timeline-comment-#{comment.id}") == 1
    end
  end

  describe "API-driven changes update mounted LiveViews" do
    setup :register_and_log_in_user

    setup %{user: user} do
      board = Boards.get_or_create_default_board(user)
      [backlog, spec | _rest] = board.stages
      {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, user)
      %{board: board, backlog: backlog, spec: spec, token: token}
    end

    test "an API move updates an open board live", %{conn: conn, backlog: backlog, spec: spec, token: token} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent moves me"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert token |> api_conn() |> post(~p"/api/cards/RLY-1/move", %{stage: spec.id}) |> json_response(200)

      assert has_element?(view, "#stage-col-2-cards .board-card", "Agent moves me")
      refute has_element?(view, "#stage-col-1-cards .board-card")
      assert has_element?(view, "#stage-col-2 .stage-count", "1")
    end

    test "an API status change updates an open board live", %{conn: conn, backlog: backlog, token: token} do
      {:ok, _card} = Cards.create_card(backlog, %{title: "Agent works"})

      {:ok, view, _html} = live(conn, ~p"/board")

      assert token |> api_conn() |> patch(~p"/api/cards/RLY-1", %{status: "needs_input"}) |> json_response(200)

      assert has_element?(view, "#stage-col-1-cards .board-card .card-needs-input", "NEEDS INPUT")
    end

    test "an API comment appends to an open drawer's timeline", %{conn: conn, backlog: backlog, token: token} do
      {:ok, card} = Cards.create_card(backlog, %{title: "Ping"})

      {:ok, view, _html} = live(conn, ~p"/board?card=RLY-1")

      assert token
             |> api_conn()
             |> post(~p"/api/cards/RLY-1/comments", %{body: "From the agent"})
             |> json_response(201)

      comment = Repo.get_by!(Schemas.Comment, card_id: card.id)
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-comment-body", "From the agent")
      assert has_element?(view, "#timeline-comment-#{comment.id} .timeline-author", "Relay AI")
    end
  end

  defp api_conn(token) do
    put_req_header(build_conn(), "authorization", "Bearer " <> token)
  end

  defp element_count(view, selector) do
    view
    |> render()
    |> LazyHTML.from_fragment()
    |> LazyHTML.query(selector)
    |> Enum.count()
  end
end
```

- [x] Run `mix test test/relay_web/live/board_live_realtime_test.exs` — expect failures:
      the two-session/API tests fail on missing elements (no subscription yet), and the
      `send/2` idempotence tests crash the LiveView (no `handle_info/2` clause), which also
      surfaces as failures.
- [x] Subscribe on connected mount in `lib/relay_web/live/board_live.ex`. Add the alias —
      replace:

```elixir
  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
```

with:

```elixir
  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
```

then in `mount/3` replace:

```elixir
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)
```

with:

```elixir
  def mount(_params, _session, socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)

    if connected?(socket), do: Events.subscribe(board.id)

    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)
```

- [x] Add the `handle_info/2` clauses directly after the last `handle_event` clause
      (`def handle_event("post_comment", _params, socket), do: {:noreply, socket}`) and
      before the private helpers:

```elixir
  # MMF 18 — realtime application of Relay.Events broadcasts. Every open
  # session applies every event for its board, including the acting
  # session's own echo: streams upsert by DOM id and counts/stages are
  # recomputed from the DB, so double-apply is a no-op by construction.
  @impl true
  def handle_info({:card_upserted, %Card{} = card}, socket) do
    if find_stage_by_id(socket, card.stage_id) do
      cards_by_stage = socket.assigns.board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

      {:noreply,
       socket
       |> stream_insert(stream_name(card.stage_id), card)
       |> assign(:stage_counts, stage_counts(socket.assigns.board.stages, cards_by_stage))
       |> maybe_refresh_drawer(card)}
    else
      # The card sits in a stage this socket hasn't loaded yet (e.g. a
      # just-enabled sub-lane racing its stages_changed event): rebuild.
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:card_moved, %Card{} = moved, from_stage_id}, socket) do
    if find_stage_by_id(socket, moved.stage_id) do
      {:noreply, apply_move(socket, from_stage_id, moved)}
    else
      {:noreply, reload_board(socket)}
    end
  end

  def handle_info({:timeline_appended, card_id, entry}, socket) do
    case socket.assigns.selected_card do
      %Card{id: ^card_id} -> {:noreply, stream_insert(socket, :timeline, entry)}
      _other -> {:noreply, socket}
    end
  end

  def handle_info({:stages_changed, _board_id}, socket) do
    {:noreply, reload_board(socket)}
  end
```

- [x] Add the three private helpers right after the existing
      `refresh_selected_after_move/2` helper:

```elixir
  # A remotely upserted card that is open in this session's drawer: sync
  # the drawer assigns (selected card, status form, timeline) through the
  # same refresh_card/2 path local drawer actions use.
  defp maybe_refresh_drawer(socket, %Card{id: id} = card) do
    case socket.assigns.selected_card do
      %Card{id: ^id} -> refresh_card(socket, card)
      _other -> socket
    end
  end

  # stages_changed (or an event for a stage this socket doesn't know yet):
  # refetch the board and rebuild every stage-derived assign and stream,
  # exactly like mount does. Streams reset from the DB, so this is
  # idempotent and safe to run on the acting session's own echo too.
  defp reload_board(socket) do
    board = Boards.get_or_create_default_board(socket.assigns.current_scope.user)
    cards_by_stage = board |> Cards.list_cards() |> Enum.group_by(& &1.stage_id)

    socket =
      socket
      |> assign(:board, board)
      |> assign(:stage_groups, group_stages(board.stages))
      |> assign(:stage_counts, stage_counts(board.stages, cards_by_stage))
      |> assign(:sublanes_by_parent, sublanes_by_parent(board.stages))

    board.stages
    |> Enum.reduce(socket, fn stage, acc ->
      stream(acc, stream_name(stage.id), Map.get(cards_by_stage, stage.id, []), reset: true)
    end)
    |> refresh_selected_stage()
  end

  # After a stage reload, re-derive the open drawer's stage from the new
  # board (disable_lane refuses to remove a non-empty lane, so the
  # selected card's stage always still exists).
  defp refresh_selected_stage(socket) do
    case socket.assigns.selected_card do
      %Card{} = card -> assign(socket, :selected_stage, find_stage_by_id(socket, card.stage_id))
      _other -> socket
    end
  end
```

- [x] Update the `@moduledoc` of `RelayWeb.BoardLive` by appending one paragraph after the
      MMF 05 paragraph:

```elixir
  MMF 18 makes the board realtime: mount subscribes to `Relay.Events` for this
  board, and handle_info/2 applies the broadcast domain events (card_upserted,
  card_moved, timeline_appended, stages_changed) idempotently to the streams,
  counts, and open drawer — whether the change came from another browser
  session or from the REST API.
```

- [x] Run `mix test test/relay_web/live/board_live_realtime_test.exs` — expect all tests
      to pass. (Broadcast delivery is deterministic here: PubSub dispatches locally and
      synchronously inside the mutating call, so the event is already in the receiving
      LiveView's mailbox before the test's next `render`/`has_element?` call — no sleeps
      needed.)
- [x] Run `mix test test/relay_web/live/board_live_test.exs` — the existing BoardLive suite
      must stay green (the acting session now also applies its own echoed events; they are
      idempotent no-ops).
- [x] Run `mix precommit` — expect a clean pass.
- [x] Commit.

**Deliverable:** every open `BoardLive` on a board applies creates, edits, moves, status
and owner changes, comments, and lane toggles live — from other sessions and from the REST
API — with board-scoped delivery, idempotent double-apply, and a live-refreshing open
drawer. All MMF 18 acceptance criteria are covered by tests.

**Commit message:** `feat(board): apply realtime board events in BoardLive (MMF 18)`

---

## Self-review notes (already applied)

- **Placeholder scan:** no TBDs; every test and implementation block is complete code.
- **Signature consistency:** `Events.subscribe/1` + `Events.broadcast/2` (Task 1) are the
  only cross-task functions; Task 2 broadcasts and Task 3 consumes the exact four event
  shapes listed in Task 2's Produces block. `broadcast_upserted/1`,
  `broadcast_appended/2`, and `broadcast_stages_changed/2` are context-private.
- **Spec coverage:** all four acceptance criteria have tests (two-session propagation:
  Task 3 "two sessions" describe; API-driven: Task 3 "API-driven" describe; board
  scoping: Task 1 topic test + Task 3 "board scoping" describe; contexts-originate:
  Task 2 tests drive context functions directly and the API tests pass with zero
  controller changes). Idempotence and drawer-only timeline application each have
  dedicated tests. Fire-and-forget is encoded in `Events.broadcast/2` returning `:ok`
  unconditionally and tested with the no-subscriber test.
- **Transaction ordering:** card events broadcast only after `Repo.transaction` returns
  `{:ok, _}`; the `timeline_appended` pre-commit edge (entries logged inside a Cards
  transaction) is documented in Architecture and safe because its receivers never re-read
  the DB.
- **Boundary wiring:** `Relay.Events` uses `use Boundary, deps: []` (Phoenix.PubSub is an
  external dep, not boundary-checked); it is added to `Relay`'s `exports`; Cards/Boards/
  Activity each add `Relay.Events` to their `deps`; RelayWeb already depends on `Relay`.
