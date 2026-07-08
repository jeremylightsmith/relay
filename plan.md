# Plan — MMF 13: Approval gates & reject routing

**Spec:** `docs/superpowers/specs/2026-07-08-approval-gates-design.md`
**Branch:** trunk-based on `main`

## Goal

A stage can act as a checkpoint: two new `Schemas.Stage` fields (`approval_gate`,
`reject_to_stage_id`), context functions `Relay.Cards.approve/2` and `Relay.Cards.reject/3`
that route cards past/back from a gate, gate controls on the Board Settings stage card, and
`POST /api/cards/:ref/approve` / `POST /api/cards/:ref/reject` endpoints over those same
context functions. **Config + routing only** — the in-drawer approve/reject action panel is
MMF 15 and must NOT be built here.

## Architecture

- **Data:** migration adds `approval_gate :boolean, default: false, null: false` and
  `reject_to_stage_id` (nullable self-FK, `on_delete: :nilify_all`) to `stages`.
  `Stage.changeset/2` casts both. Same-board/main-lane validation for the reject target is
  **context-level** in `Relay.Boards.update_stage/2` (the schema doesn't know the board).
- **Routing lives in `Relay.Cards`** (never in the web layer), composed from the existing,
  already-tested primitives: `move_card/4` (broadcasts `{:card_moved, …}`), `set_status/3`
  (broadcasts `{:card_upserted, …}`, logs `:status_changed`), `Relay.Activity.add_comment/2`
  and `Relay.Activity.log/2` (broadcast `{:timeline_appended, …}`). Both functions take the
  standard actor (`:agent | {:user, id}`, default `:agent`) so MMF 15's drawer and the API
  share one path.
- **Gate resolution:** a card is "at a gate" when its stage (main lane) — or its parent, for
  a card sitting in a sub-lane — has `approval_gate: true`; otherwise `{:error, :not_gated}`.
- **Approve:** move to the **next main stage by position** (`Relay.Boards.next_main_stage/1`,
  new — sub-lane children are never "next"; from a sub-lane, next = first main stage after
  the parent). Arrival status: `:working` if the target stage's `owner` is `:ai`, `:queued`
  if `:human`. At the last main stage: no move — set status `:done` in place.
- **Reject:** move to the gate's `reject_to_stage_id`, or — when `nil` — the gate's own main
  lane (the gate stage itself; a review-sub-lane card returns to the parent, a main-lane card
  stays put). Same arrival-status rule. The `note` is posted as a comment from `actor`, and
  the note is also snapshotted into the `:rejected` activity meta.
- **New activity types** `:approved` / `:rejected` on `Schemas.Activity` with meta
  `%{"from_stage" => …, "to_stage" => …}` (display names via `Boards.stage_display_name/1`)
  plus `"note"` for rejects.
- **Settings UI:** in the existing stage settings card in `RelayWeb.BoardSettingsLive`,
  below the REVIEW SUB-LANE row and in the same mono-label + toggle idiom: an
  `APPROVAL GATE` toggle (`#stage-<id>-gate-toggle`) and, when on, a `SEND REJECTS TO`
  select (`#stage-<id>-reject-target`) listing "This stage" (nil) + the board's other main
  stages. Persist via `Boards.update_stage/2` (already broadcasts `{:stages_changed, …}`).
- **API:** two new routes in the existing `scope "/api", RelayWeb.Api`, handled by
  `RelayWeb.Api.CardController` calling the context as `:agent`, rendering the existing
  `:show` (CardJSON) shape. Errors: 404 unknown ref, 422 for `{:error, :not_gated}` or a
  missing reject note (new `RelayWeb.Api.FallbackController` clauses). `GET /api/board`
  stage payloads gain `approval_gate` + `reject_to_stage_id` (in `CardJSON.stage/1`).

## Tech

Elixir / Phoenix 1.8, LiveView, Ecto (Postgres), ExMachina factories, `boundary`-enforced
context boundaries (web → `Relay` exports only; `Relay.Cards` already deps on
`Relay.Boards` + `Relay.Activity`).

## Global Constraints

- `mix precommit` is REQUIRED and must pass before work is considered done: compile with
  warnings-as-errors, `mix format` (Styler), `mix credo --strict`, `mix sobelow`,
  `mix deps.audit`, full test suite (warnings as errors).
- Generate migrations with `mix ecto.gen.migration migration_name_using_underscores`.
- Programmatic fields (`board_id`, `stage_id`, `position`, `ref_number`, actor fields) are
  never cast from input.
- Predicate functions end in `?`, never start with `is_`.
- HEEx: `{...}` in attributes, `<%= %>` only in bodies; class lists use `[...]` syntax;
  use `<.icon>` and `<.input>` (use `<.input type="select">` for the reject target);
  comments are `<%!-- … --%>`; every key element gets a unique DOM id.
- LiveView tests target element ids via `element/2` / `has_element?/2`, never raw HTML.
- Broadcasts come from contexts only (MMF 18): reuse `{:stages_changed, board_id}`,
  `{:card_moved, card, from_stage_id}`, `{:card_upserted, card}`,
  `{:timeline_appended, card_id, entry}` — never broadcast from controllers/LiveViews.
- Do NOT build any drawer approve/reject UI — that is MMF 15. Keep `Cards.approve/2` /
  `Cards.reject/3` clean for it.

---

### Task 1: Gate schema + `Cards.approve/2` / `Cards.reject/3` routing

**Files**
- Create: `priv/repo/migrations/<timestamp>_add_approval_gates_to_stages.exs` (generated)
- Modify: `lib/schemas/stage.ex`, `lib/schemas/activity.ex`, `lib/relay/boards.ex`,
  `lib/relay/cards.ex`, `lib/relay/activity.ex` (doc only)
- Test (create): `test/relay/cards_gates_test.exs`, `test/relay/boards_gate_config_test.exs`

**Interfaces**

Consumes (existing, unchanged):
- `Relay.Cards.move_card(card, target_stage, index, actor \\ :agent) :: {:ok, Card.t()} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.set_status(card, attrs, actor \\ :agent) :: {:ok, Card.t()} | {:error, Ecto.Changeset.t()}`
- `Relay.Activity.add_comment(card, %{actor: actor, body: body})`
- `Relay.Activity.log(card, %{type: type, actor: actor, meta: meta})`
- `Relay.Boards.stage_display_name(stage) :: String.t()`
- `Relay.Boards.enable_lane(parent, lane)`, `Relay.Boards.delete_stage(stage)`,
  `Relay.Boards.list_stages(board)`, `Relay.Boards.get_stage(board, id)`
- `Relay.Events.subscribe(board_id)`

Produces (Task 2 and MMF 15 rely on these exact signatures):
- `Schemas.Stage` fields: `approval_gate :: boolean` (default `false`),
  `reject_to_stage_id :: integer | nil` (via `belongs_to :reject_to_stage`); both cast by
  `Stage.changeset/2`.
- `Relay.Boards.update_stage(stage, attrs)` — now accepts `:approval_gate` and
  `:reject_to_stage_id` in `attrs`; returns `{:error, changeset}` (error on
  `:reject_to_stage_id`) when the target is not a main-lane stage on the same board.
- `Relay.Boards.next_main_stage(%Schemas.Stage{lane: :main}) :: Schemas.Stage.t() | nil`
- `Relay.Cards.approve(card, actor \\ :agent) :: {:ok, Card.t()} | {:error, :not_gated} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.reject(card, note, actor \\ :agent) :: {:ok, Card.t()} | {:error, :not_gated} | {:error, Ecto.Changeset.t()}` (`note` must be a binary — guard)
- `Schemas.Activity.type` enum gains `:approved` and `:rejected`.

**Steps**

- [x] Write the failing context tests. Create `test/relay/cards_gates_test.exs`:

```elixir
defmodule Relay.CardsGatesTest do
  use Relay.DataCase, async: true

  alias Relay.Activity
  alias Relay.Boards
  alias Relay.Cards
  alias Relay.Events
  alias Schemas.Card

  # Pipeline (positions 1-5): Plan | Code | Review (gate) | Deploy | Done (gate, last).
  setup do
    board = insert(:board, key: "RLY")
    plan = insert(:stage, board: board, name: "Plan", owner: :ai, category: :planning, position: 1)
    code = insert(:stage, board: board, name: "Code", owner: :ai, category: :in_progress, position: 2)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        owner: :human,
        category: :in_progress,
        position: 3,
        approval_gate: true
      )

    deploy = insert(:stage, board: board, name: "Deploy", owner: :ai, category: :in_progress, position: 4)

    done =
      insert(:stage,
        board: board,
        name: "Done",
        owner: :human,
        category: :complete,
        position: 5,
        approval_gate: true
      )

    %{board: board, plan: plan, code: code, review: review, deploy: deploy, done: done}
  end

  describe "approve/2" do
    test "advances to the next main stage, arriving :working for an AI-meant target",
         %{review: review, deploy: deploy} do
      card = insert(:card, stage: review)

      assert {:ok, %Card{} = approved} = Cards.approve(card, :agent)
      assert approved.stage_id == deploy.id
      assert approved.status == :working
    end

    test "arrives :queued when the next main stage is meant for a human" do
      board = insert(:board)

      gate =
        insert(:stage,
          board: board,
          name: "Code",
          owner: :ai,
          category: :in_progress,
          position: 1,
          approval_gate: true
        )

      verify = insert(:stage, board: board, name: "Verify", owner: :human, category: :in_progress, position: 2)
      card = insert(:card, stage: gate)

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == verify.id
      assert approved.status == :queued
    end

    test "skips sub-lane stages when finding the next stage", %{review: review, deploy: deploy} do
      {:ok, _sublane} = Boards.enable_lane(review, :review)
      {:ok, _sublane} = Boards.enable_lane(deploy, :done)
      card = insert(:card, stage: review)

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == deploy.id
    end

    test "from the gate's review sub-lane, next = the first main stage after the parent",
         %{review: review, deploy: deploy} do
      {:ok, sublane} = Boards.enable_lane(review, :review)
      card = insert(:card, stage: sublane)

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == deploy.id
      assert approved.status == :working
    end

    test "at the last main stage sets :done in place", %{done: done} do
      card = insert(:card, stage: done)

      assert {:ok, approved} = Cards.approve(card)
      assert approved.stage_id == done.id
      assert approved.status == :done
    end

    test "logs an :approved activity with from/to stage names", %{review: review} do
      card = insert(:card, stage: review)
      {:ok, _approved} = Cards.approve(card, :agent)

      entry = card |> Activity.list_timeline() |> Enum.find(&(Map.get(&1, :type) == :approved))
      assert entry.actor_type == :agent
      assert entry.meta == %{"from_stage" => "Review", "to_stage" => "Deploy"}
    end

    test "broadcasts the move and the :approved timeline entry", %{board: board, review: review} do
      card = insert(:card, stage: review)
      card_id = card.id
      review_id = review.id
      :ok = Events.subscribe(board.id)

      {:ok, _approved} = Cards.approve(card)

      assert_receive {:card_moved, %Card{id: ^card_id}, ^review_id}
      assert_receive {:timeline_appended, ^card_id, %Schemas.Activity{type: :approved}}
    end

    test "never touches the card's owners", %{review: review} do
      card = insert(:card, stage: review)
      insert(:card_owner, card: card)

      {:ok, approved} = Cards.approve(card)
      assert [%{actor_type: :agent}] = approved.owners
    end

    test "returns {:error, :not_gated} on a non-gated stage", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_gated} = Cards.approve(card)
    end
  end

  describe "reject/3" do
    test "routes to the configured target with arrival status, note comment, and :rejected entry",
         %{review: review, code: code} do
      {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})
      card = insert(:card, stage: review)

      assert {:ok, rejected} = Cards.reject(card, "Specs are missing edge cases", :agent)
      assert rejected.stage_id == code.id
      assert rejected.status == :working

      timeline = Activity.list_timeline(card)
      assert Enum.any?(timeline, &(is_struct(&1, Schemas.Comment) and &1.body == "Specs are missing edge cases"))

      entry = Enum.find(timeline, &(Map.get(&1, :type) == :rejected))
      assert entry.actor_type == :agent

      assert entry.meta == %{
               "from_stage" => "Review",
               "to_stage" => "Code",
               "note" => "Specs are missing edge cases"
             }
    end

    test "with a nil target, a sub-lane card returns to the gate's own main lane", %{review: review} do
      {:ok, sublane} = Boards.enable_lane(review, :review)
      card = insert(:card, stage: sublane)

      assert {:ok, rejected} = Cards.reject(card, "Please tighten the copy")
      assert rejected.stage_id == review.id
      assert rejected.status == :queued
    end

    test "with a nil target, a main-lane card stays in the gate stage", %{review: review} do
      card = insert(:card, stage: review)

      assert {:ok, rejected} = Cards.reject(card, "Not ready")
      assert rejected.stage_id == review.id
      assert rejected.status == :queued
    end

    test "never touches the card's owners", %{review: review, code: code} do
      {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})
      card = insert(:card, stage: review)
      insert(:card_owner, card: card)

      {:ok, rejected} = Cards.reject(card, "Redo")
      assert [%{actor_type: :agent}] = rejected.owners
    end

    test "returns {:error, :not_gated} on a non-gated stage", %{code: code} do
      card = insert(:card, stage: code)
      assert {:error, :not_gated} = Cards.reject(card, "nope")
    end
  end
end
```

- [x] Create `test/relay/boards_gate_config_test.exs`:

```elixir
defmodule Relay.BoardsGateConfigTest do
  use Relay.DataCase, async: true

  alias Relay.Boards

  setup do
    board = insert(:board)
    code = insert(:stage, board: board, name: "Code", owner: :ai, category: :in_progress, position: 1)
    review = insert(:stage, board: board, name: "Review", owner: :human, category: :in_progress, position: 2)
    deploy = insert(:stage, board: board, name: "Deploy", owner: :ai, category: :in_progress, position: 3)
    %{board: board, code: code, review: review, deploy: deploy}
  end

  describe "update_stage/2 gate config" do
    test "round-trips approval_gate and reject_to_stage_id", %{board: board, review: review, code: code} do
      assert {:ok, updated} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})
      assert updated.approval_gate
      assert updated.reject_to_stage_id == code.id

      reloaded = board |> Boards.list_stages() |> Enum.find(&(&1.id == review.id))
      assert reloaded.approval_gate
      assert reloaded.reject_to_stage_id == code.id
    end

    test "rejects a reject target on another board", %{review: review} do
      foreign = insert(:stage, board: insert(:board))

      assert {:error, changeset} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: foreign.id})
      assert %{reject_to_stage_id: ["must be a main stage on the same board"]} = errors_on(changeset)
    end

    test "rejects a sub-lane reject target", %{review: review, deploy: deploy} do
      {:ok, sublane} = Boards.enable_lane(deploy, :review)

      assert {:error, changeset} = Boards.update_stage(review, %{reject_to_stage_id: sublane.id})
      assert %{reject_to_stage_id: ["must be a main stage on the same board"]} = errors_on(changeset)
    end

    test "deleting the reject-target stage nilifies the FK", %{board: board, review: review, code: code} do
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})

      assert {:ok, _deleted} = Boards.delete_stage(code)

      reloaded = Boards.get_stage(board, review.id)
      assert reloaded.approval_gate
      assert reloaded.reject_to_stage_id == nil
    end
  end

  describe "next_main_stage/1" do
    test "returns the following main stage by position, skipping sub-lanes, or nil at the end",
         %{code: code, review: review, deploy: deploy} do
      {:ok, _sublane} = Boards.enable_lane(review, :review)

      assert Boards.next_main_stage(code).id == review.id
      assert Boards.next_main_stage(review).id == deploy.id
      assert Boards.next_main_stage(deploy) == nil
    end
  end
end
```

- [x] Run `mix test test/relay/cards_gates_test.exs test/relay/boards_gate_config_test.exs`
  — expect failures/compile errors (fields and functions don't exist yet).
- [x] Generate the migration with
  `mix ecto.gen.migration add_approval_gates_to_stages` and fill in the generated file:

```elixir
defmodule Relay.Repo.Migrations.AddApprovalGatesToStages do
  use Ecto.Migration

  def change do
    alter table(:stages) do
      add :approval_gate, :boolean, default: false, null: false
      add :reject_to_stage_id, references(:stages, on_delete: :nilify_all)
    end
  end
end
```

- [x] Run `mix ecto.migrate` (expect success).
- [x] Add the fields to `lib/schemas/stage.ex`. In the `schema "stages"` block, after
  `field :wip_limit, :integer`, add:

```elixir
    field :approval_gate, :boolean, default: false

    belongs_to :reject_to_stage, Schemas.Stage
```

  (Ecto derives the `reject_to_stage_id` FK column from the association name.) In
  `changeset/2`, extend the cast list:

```elixir
    |> cast(attrs, [:name, :description, :position, :category, :owner, :wip_limit, :approval_gate, :reject_to_stage_id])
```

  Also extend the `@moduledoc` with one sentence: `` `approval_gate`/`reject_to_stage_id`
  are the MMF 13 checkpoint config — the reject target must be a main-lane stage on the
  same board (validated in `Relay.Boards.update_stage/2`; nil = the gate's own main lane). ``
- [x] Add the new activity types in `lib/schemas/activity.ex`:

```elixir
    field :type, Ecto.Enum,
      values: [:created, :moved, :status_changed, :owners_changed, :commented, :approved, :rejected]
```

  and in `lib/relay/activity.ex`, update the `log/2` doc's type list to
  `` (`:created | :moved | :status_changed | :owners_changed | :commented | :approved | :rejected`) ``.
- [x] Extend `lib/relay/boards.ex`. Replace `update_stage/2` (and its `@doc`) with the
  validated pipeline below, add `next_main_stage/1` (public, right after `update_stage/2`),
  and add the private validator with the other private helpers (near `main_stages/1`):

```elixir
  @doc """
  Updates a main stage's editable configuration (name, description, owner,
  WIP limit — and the MMF 13 gate fields `approval_gate` /
  `reject_to_stage_id`). The reject target must be a main-lane stage on
  the same board (nil means "this stage"). Broadcasts
  `{:stages_changed, board_id}` on success. `owner` is the stage's
  *meant-for* designation only — this never touches any card's
  `card_owners` rows.
  """
  def update_stage(%Stage{} = stage, attrs) do
    stage
    |> Stage.changeset(attrs)
    |> validate_reject_target(stage.board_id)
    |> Repo.update()
    |> broadcast_stages_changed(stage.board_id)
  end

  @doc """
  The next main stage after `stage` in board order (position), or nil
  when `stage` is the board's last main stage. Sub-lane children are
  never "next" — MMF 13's approve routing advances through this.
  """
  def next_main_stage(%Stage{lane: :main} = stage) do
    stage.board_id
    |> main_stages()
    |> Enum.drop_while(&(&1.id != stage.id))
    |> Enum.at(1)
  end
```

```elixir
  # MMF 13: a gate may only send rejects to a main-lane stage on its own
  # board. Validated here (not in the schema) because only the context
  # knows the board.
  defp validate_reject_target(changeset, board_id) do
    case Ecto.Changeset.get_change(changeset, :reject_to_stage_id) do
      nil ->
        changeset

      target_id ->
        if Repo.exists?(from s in Stage, where: s.id == ^target_id and s.board_id == ^board_id and s.lane == :main) do
          changeset
        else
          Ecto.Changeset.add_error(changeset, :reject_to_stage_id, "must be a main stage on the same board")
        end
    end
  end
```

- [x] Add `approve/2` and `reject/3` to `lib/relay/cards.ex`. Add a module attribute after
  the aliases:

```elixir
  # Approve/reject append the card to the bottom of the target stage;
  # move_card/4 clamps this into range.
  @append_index 1_000_000
```

  Add the two public functions after `move_card/4`:

```elixir
  @doc """
  Approves the card past its approval gate (MMF 13). Allowed when the
  card's stage — or its parent, for a card sitting in a sub-lane — has
  `approval_gate` set; otherwise returns `{:error, :not_gated}`. Moves
  the card to the bottom of the next main stage by position (sub-lane
  children are never "next"; from a sub-lane, next = the first main
  stage after the parent), arriving `:working` when that stage is meant
  for AI and `:queued` when meant for a human. At the board's last main
  stage there is no move — the card's status becomes `:done` in place.
  Logs an `:approved` activity entry (from/to stage display names in
  meta) attributed to `actor`, and reuses `move_card`/`set_status`, so
  the usual `{:card_moved}`/`{:card_upserted}`/`{:timeline_appended}`
  events fire. Reused verbatim by the API (MMF 09) and the drawer
  (MMF 15).
  """
  def approve(%Card{} = card, actor \\ :agent) do
    case fetch_gate(card) do
      {:ok, from_stage, gate} ->
        case Boards.next_main_stage(gate) do
          nil -> approve_in_place(card, from_stage, actor)
          %Stage{} = target -> route(card, from_stage, target, :approved, nil, actor)
        end

      {:error, :not_gated} ->
        {:error, :not_gated}
    end
  end

  @doc """
  Rejects the card at its approval gate (MMF 13), under the same gate
  rule as `approve/2` (`{:error, :not_gated}` otherwise). Moves the card
  to the gate's `reject_to_stage_id` — or, when nil, the gate's own main
  lane — arriving `:working`/`:queued` by the target's meant-for owner.
  Posts `note` as a comment from `actor` and logs a `:rejected` activity
  entry (from/to stage display names plus the note in meta). Reuses
  `move_card`/`set_status`, so the usual events fire.
  """
  def reject(%Card{} = card, note, actor \\ :agent) when is_binary(note) do
    case fetch_gate(card) do
      {:ok, from_stage, gate} -> route(card, from_stage, reject_target(gate), :rejected, note, actor)
      {:error, :not_gated} -> {:error, :not_gated}
    end
  end
```

  And the private helpers (place them right after `parse_ref_number/2`):

```elixir
  # The gate governing the card: its own stage when main-lane, else the
  # sub-lane's parent. {:error, :not_gated} when that stage isn't a gate.
  defp fetch_gate(%Card{stage_id: stage_id}) do
    stage = Repo.get!(Stage, stage_id)
    gate = if stage.lane == :main, do: stage, else: Repo.get!(Stage, stage.parent_id)

    if gate.approval_gate, do: {:ok, stage, gate}, else: {:error, :not_gated}
  end

  defp reject_target(%Stage{reject_to_stage_id: nil} = gate), do: gate
  defp reject_target(%Stage{reject_to_stage_id: target_id}), do: Repo.get!(Stage, target_id)

  # Shared approve/reject transition: move to the bottom of `target`, set
  # the arrival status, attach the note (rejects only), then log the
  # :approved/:rejected entry. A nil-target reject resolves to the gate
  # itself, so a main-lane card "moves" within its own stage (no :moved
  # entry — move_card only logs cross-stage moves).
  defp route(%Card{} = card, from_stage, %Stage{} = target, type, note, actor) do
    with {:ok, moved} <- move_card(card, target, @append_index, actor),
         {:ok, updated} <- set_status(moved, %{status: arrival_status(target)}, actor),
         :ok <- attach_note(updated, note, actor) do
      log_gate(updated, type, actor, from_stage, target, note)
      {:ok, updated}
    end
  end

  # Approve at the board's last main stage: :done in place, no move.
  defp approve_in_place(%Card{} = card, from_stage, actor) do
    case set_status(card, %{status: :done}, actor) do
      {:ok, updated} ->
        log_gate(updated, :approved, actor, from_stage, from_stage, nil)
        {:ok, updated}

      {:error, changeset} ->
        {:error, changeset}
    end
  end

  defp arrival_status(%Stage{owner: :ai}), do: :working
  defp arrival_status(%Stage{owner: :human}), do: :queued

  defp attach_note(_card, nil, _actor), do: :ok

  defp attach_note(%Card{} = card, note, actor) do
    case Activity.add_comment(card, %{actor: actor, body: note}) do
      {:ok, _comment} -> :ok
      {:error, changeset} -> {:error, changeset}
    end
  end

  defp log_gate(%Card{} = card, type, actor, from_stage, to_stage, note) do
    meta = %{
      "from_stage" => Boards.stage_display_name(from_stage),
      "to_stage" => Boards.stage_display_name(to_stage)
    }

    meta = if note, do: Map.put(meta, "note", note), else: meta

    {:ok, _entry} = Activity.log(card, %{type: type, actor: actor, meta: meta})
  end
```

- [x] Run `mix test test/relay/cards_gates_test.exs test/relay/boards_gate_config_test.exs`
  (expect pass).
- [x] Run `mix precommit` (expect green; fix any format/credo fallout).
- [x] Commit.

**Deliverable:** gated stages exist in the data model with validated reject targets, and
`Relay.Cards.approve/2` / `Relay.Cards.reject/3` perform the full spec'd routing with
activity logging and broadcasts — independently testable via the two new context test files.

**Commit message:** `feat(gates): approval-gate schema + Cards.approve/reject routing (MMF 13)`

---

### Task 2: Gate settings controls + API approve/reject endpoints

**Files**
- Modify: `lib/relay_web/live/board_settings_live.ex`, `lib/relay_web/router.ex`,
  `lib/relay_web/controllers/api/card_controller.ex`,
  `lib/relay_web/controllers/api/fallback_controller.ex`,
  `lib/relay_web/controllers/api/card_json.ex`
- Test (create): `test/relay_web/live/board_settings_gate_test.exs`,
  `test/relay_web/api/card_gates_test.exs`

**Interfaces**

Consumes (from Task 1 — exact signatures):
- `Relay.Cards.approve(card, actor \\ :agent) :: {:ok, Card.t()} | {:error, :not_gated} | {:error, Ecto.Changeset.t()}`
- `Relay.Cards.reject(card, note, actor \\ :agent) :: {:ok, Card.t()} | {:error, :not_gated} | {:error, Ecto.Changeset.t()}`
- `Relay.Boards.update_stage(stage, attrs)` accepting `%{approval_gate: boolean, reject_to_stage_id: integer | nil}`
- `Schemas.Stage.approval_gate` / `Schemas.Stage.reject_to_stage_id`
- Existing: `Relay.Cards.get_card_by_ref(board, ref)`, `Relay.Activity.list_timeline(card)`,
  `RelayWeb.Api.CardJSON` `:show` rendering, `RelayWeb.Api.FallbackController` pattern.

Produces:
- Routes `POST /api/cards/:ref/approve` and `POST /api/cards/:ref/reject` (body
  `{"note": "..."}`, required) → `RelayWeb.Api.CardController.approve/2` / `.reject/2`.
- Fallback clauses for `{:error, :not_gated}` and `{:error, :missing_note}` → 422.
- `CardJSON.stage/1` gains `approval_gate` + `reject_to_stage_id` keys (feeds `GET /api/board`).
- Settings DOM ids: `#stage-<id>-gate-toggle`, `#stage-<id>-reject-form`,
  `#stage-<id>-reject-target`.

**Steps**

- [x] Write the failing settings test. Create
  `test/relay_web/live/board_settings_gate_test.exs`:

```elixir
defmodule RelayWeb.BoardSettingsGateTest do
  use RelayWeb.ConnCase, async: true

  import Phoenix.LiveViewTest

  alias Relay.Boards
  alias Relay.Cards

  setup :register_and_log_in_user

  setup %{user: user} do
    %{board: Boards.get_or_create_default_board(user)}
  end

  defp stage_named(board, name), do: Enum.find(board.stages, &(&1.name == name))

  describe "the stage card's APPROVAL GATE controls" do
    test "renders the gate toggle off with no reject select by default", %{conn: conn, board: board} do
      review = stage_named(board, "Review")

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#stage-#{review.id}-gate-toggle")
      refute has_element?(view, "#stage-#{review.id}-gate-toggle[checked]")
      refute has_element?(view, "#stage-#{review.id}-reject-target")
    end

    test "toggling the gate on persists and reveals the reject select", %{conn: conn, board: board} do
      review = stage_named(board, "Review")

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#stage-#{review.id}-gate-toggle") |> render_click()

      assert has_element?(view, "#stage-#{review.id}-gate-toggle[checked]")
      assert has_element?(view, "#stage-#{review.id}-reject-target")
      assert Boards.get_stage(board, review.id).approval_gate
    end

    test "toggling the gate off persists and clears the reject target", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true, reject_to_stage_id: code.id})

      {:ok, view, _html} = live(conn, ~p"/board/settings")
      view |> element("#stage-#{review.id}-gate-toggle") |> render_click()

      refute has_element?(view, "#stage-#{review.id}-reject-target")
      reloaded = Boards.get_stage(board, review.id)
      refute reloaded.approval_gate
      assert reloaded.reject_to_stage_id == nil
    end

    test "the reject select lists This stage plus only the other main stages", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true})
      {:ok, sublane} = Boards.enable_lane(code, :review)

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      assert has_element?(view, "#stage-#{review.id}-reject-target option[value='']", "This stage")
      assert has_element?(view, "#stage-#{review.id}-reject-target option[value='#{code.id}']", "Code")
      refute has_element?(view, "#stage-#{review.id}-reject-target option[value='#{review.id}']")
      refute has_element?(view, "#stage-#{review.id}-reject-target option[value='#{sublane.id}']")
    end

    test "picking a reject target persists it and rejected cards route there", %{conn: conn, board: board} do
      review = stage_named(board, "Review")
      code = stage_named(board, "Code")
      {:ok, _stage} = Boards.update_stage(review, %{approval_gate: true})

      {:ok, view, _html} = live(conn, ~p"/board/settings")

      view
      |> element("#stage-#{review.id}-reject-form")
      |> render_change(%{"reject_to_stage_id" => to_string(code.id)})

      assert Boards.get_stage(board, review.id).reject_to_stage_id == code.id

      {:ok, card} = Cards.create_card(review, %{title: "Gated work"})
      {:ok, rejected} = Cards.reject(card, "Needs edge cases")
      assert rejected.stage_id == code.id
    end
  end
end
```

- [x] Write the failing API test. Create `test/relay_web/api/card_gates_test.exs`:

```elixir
defmodule RelayWeb.Api.CardGatesTest do
  use RelayWeb.ConnCase, async: true

  alias Relay.Boards
  alias Relay.Cards

  setup %{conn: conn} do
    board = insert(:board)
    {:ok, %{token: token}} = Relay.ApiKeys.create_key(board, board.owner)
    code = insert(:stage, board: board, name: "Code", owner: :ai, category: :in_progress, position: 1)

    review =
      insert(:stage,
        board: board,
        name: "Review",
        owner: :human,
        category: :in_progress,
        position: 2,
        approval_gate: true
      )

    deploy = insert(:stage, board: board, name: "Deploy", owner: :ai, category: :in_progress, position: 3)
    conn = put_req_header(conn, "authorization", "Bearer " <> token)
    {:ok, conn: conn, board: board, code: code, review: review, deploy: deploy}
  end

  defp ref(board, card), do: Cards.ref(board, card)

  test "POST approve advances the card, attributed to Relay AI", %{
    conn: conn,
    board: board,
    review: review,
    deploy: deploy
  } do
    card = insert(:card, stage: review)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/approve")
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["stage_id"] == deploy.id
    assert body["status"] == "working"

    approved = Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "approved"))
    assert approved["author"]["name"] == "Relay AI"
    assert approved["meta"] == %{"from_stage" => "Review", "to_stage" => "Deploy"}
  end

  test "POST reject routes the card with the note attached", %{
    conn: conn,
    board: board,
    review: review,
    code: code
  } do
    {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})
    card = insert(:card, stage: review)

    body =
      conn
      |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "Handle the empty case"})
      |> json_response(200)
      |> Map.fetch!("data")

    assert body["stage_id"] == code.id
    assert body["status"] == "working"
    assert Enum.any?(body["timeline"], &(&1["kind"] == "comment" and &1["body"] == "Handle the empty case"))

    rejected = Enum.find(body["timeline"], &(&1["kind"] == "activity" and &1["type"] == "rejected"))
    assert rejected["author"]["name"] == "Relay AI"
    assert rejected["meta"]["note"] == "Handle the empty case"
  end

  test "reject without a note 422s", %{conn: conn, board: board, review: review} do
    card = insert(:card, stage: review)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{}) |> json_response(422)
  end

  test "approve and reject on a non-gated stage 422", %{conn: conn, board: board, code: code} do
    card = insert(:card, stage: code)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/approve") |> json_response(422)
    assert conn |> post(~p"/api/cards/#{ref(board, card)}/reject", %{note: "no"}) |> json_response(422)
  end

  test "approve and reject on an unknown ref 404", %{conn: conn} do
    assert conn |> post(~p"/api/cards/RLY-9999/approve") |> json_response(404)
    assert conn |> post(~p"/api/cards/RLY-9999/reject", %{note: "x"}) |> json_response(404)
  end

  test "GET /api/board stage payloads include the gate fields", %{conn: conn, review: review, code: code} do
    {:ok, _stage} = Boards.update_stage(review, %{reject_to_stage_id: code.id})

    stages = conn |> get(~p"/api/board") |> json_response(200) |> Map.fetch!("stages")
    payload = Enum.find(stages, &(&1["id"] == review.id))

    assert payload["approval_gate"] == true
    assert payload["reject_to_stage_id"] == code.id
  end
end
```

- [x] Run
  `mix test test/relay_web/live/board_settings_gate_test.exs test/relay_web/api/card_gates_test.exs`
  — expect failures (no controls, no routes).
- [x] Add the gate row to `lib/relay_web/live/board_settings_live.ex`. In `render/1`,
  insert the following block **immediately after** the closing `</div>` of the REVIEW
  SUB-LANE row (the `<div>` that opens with `border-top:1px dashed …` and contains the
  `REVIEW SUB-LANE` label), still inside the stage card container:

```heex
                    <%!-- MMF 13 — APPROVAL GATE + SEND REJECTS TO, in the card's mono-label row
                         idiom (the mockup ships no literal gate controls). A nil target means
                         "Rejected work returns to this stage's In progress lane". --%>
                    <div style="display:flex;align-items:center;gap:12px;flex-wrap:wrap;">
                      <div style="display:flex;align-items:center;gap:10px;">
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
                          APPROVAL GATE
                        </span>
                        <input
                          id={"stage-#{stage.id}-gate-toggle"}
                          type="checkbox"
                          class="toggle toggle-sm"
                          checked={stage.approval_gate}
                          phx-click="toggle_gate"
                          phx-value-stage-id={stage.id}
                        />
                      </div>
                      <form
                        :if={stage.approval_gate}
                        id={"stage-#{stage.id}-reject-form"}
                        phx-change="set_reject_target"
                        style="display:flex;align-items:center;gap:10px;"
                      >
                        <input type="hidden" name="stage_id" value={stage.id} />
                        <span class="font-mono" style="font-size:11px;color:oklch(0.58 0.02 255);">
                          SEND REJECTS TO
                        </span>
                        <.input
                          type="select"
                          id={"stage-#{stage.id}-reject-target"}
                          name="reject_to_stage_id"
                          value={stage.reject_to_stage_id}
                          options={reject_options(stage, @stages)}
                          class="select select-sm w-auto"
                        />
                      </form>
                    </div>
```

- [x] Add the two event handlers in the same LiveView, right after the
  `handle_event("delete_stage", …)` clause:

```elixir
  # MMF 13 — toggling the gate off also clears its reject target, so a
  # re-enabled gate starts back at the default ("This stage").
  def handle_event("toggle_gate", %{"stage-id" => stage_id}, socket) do
    stage = find_stage(socket, stage_id)

    attrs =
      if stage.approval_gate,
        do: %{approval_gate: false, reject_to_stage_id: nil},
        else: %{approval_gate: true}

    {:ok, _stage} = Boards.update_stage(stage, attrs)
    {:noreply, refresh_stages(socket)}
  end

  def handle_event("set_reject_target", %{"stage_id" => stage_id, "reject_to_stage_id" => target}, socket) do
    stage = find_stage(socket, stage_id)
    {:ok, _stage} = Boards.update_stage(stage, %{reject_to_stage_id: parse_reject_target(target)})
    {:noreply, refresh_stages(socket)}
  end
```

  and these private helpers next to `lane_atom/1` and friends:

```elixir
  # "" is the select's "This stage" default — reject_to_stage_id nil.
  defp parse_reject_target(""), do: nil
  defp parse_reject_target(id), do: String.to_integer(id)

  # "This stage" (nil target) plus every OTHER main stage on the board.
  # `stages` is the mains-only list refresh_stages/1 assigns.
  defp reject_options(stage, stages) do
    [{"This stage", ""} | for(s <- stages, s.id != stage.id, do: {s.name, s.id})]
  end
```

- [x] Run `mix test test/relay_web/live/board_settings_gate_test.exs` (expect pass).
- [x] Add the API routes in `lib/relay_web/router.ex`, inside the existing
  `scope "/api", RelayWeb.Api` block after the `needs-input` route:

```elixir
    post "/cards/:ref/approve", CardController, :approve
    post "/cards/:ref/reject", CardController, :reject
```

- [x] Add the controller actions in `lib/relay_web/controllers/api/card_controller.ex`,
  after the `needs_input/2` clauses:

```elixir
  def approve(conn, %{"ref" => ref}) do
    board = conn.assigns.current_board

    with %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.approve(card, :agent) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  def reject(conn, %{"ref" => ref} = params) do
    board = conn.assigns.current_board

    with {:ok, note} <- reject_note(params),
         %Schemas.Card{} = card <- Cards.get_card_by_ref(board, ref),
         {:ok, card} <- Cards.reject(card, note, :agent) do
      render(conn, :show, board: board, card: card, timeline: Activity.list_timeline(card))
    else
      nil -> {:error, :not_found}
      {:error, reason} -> {:error, reason}
    end
  end

  # The note is required for rejects (spec: 422 when missing).
  defp reject_note(%{"note" => note}) when is_binary(note) and note != "", do: {:ok, note}
  defp reject_note(_params), do: {:error, :missing_note}
```

- [x] Add the 422 clauses in `lib/relay_web/controllers/api/fallback_controller.ex`, after
  the `{:error, :not_found}` clause:

```elixir
  def call(conn, {:error, :not_gated}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "not_gated", message: "This card's stage is not an approval gate")
  end

  def call(conn, {:error, :missing_note}) do
    conn
    |> put_status(:unprocessable_entity)
    |> put_view(json: ErrorJSON)
    |> render(:error, code: "missing_note", message: "note is required")
  end
```

- [x] Expose the gate fields in `lib/relay_web/controllers/api/card_json.ex` — replace
  `stage/1` with:

```elixir
  @doc "The shared stage shape."
  def stage(stage) do
    %{
      id: stage.id,
      name: stage.name,
      category: stage.category,
      owner: stage.owner,
      position: stage.position,
      approval_gate: stage.approval_gate,
      reject_to_stage_id: stage.reject_to_stage_id
    }
  end
```

- [x] Run `mix test test/relay_web/api/card_gates_test.exs` (expect pass).
- [x] Run `mix precommit` (expect green — full suite, format, credo, sobelow).
- [x] Commit.

**Deliverable:** the Board Settings stage card carries an APPROVAL GATE toggle and a
SEND REJECTS TO select that persist through `Boards.update_stage/2` and drive real reject
routing, and agents can approve/reject via `POST /api/cards/:ref/approve|reject` with
Relay-AI-attributed timeline entries, 404 on unknown refs, and 422 on non-gated stages or a
missing note — independently testable via the two new web test files.

**Commit message:** `feat(gates): gate settings controls + API approve/reject endpoints (MMF 13)`
