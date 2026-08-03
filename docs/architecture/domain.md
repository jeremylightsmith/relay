# Domain model

Every context is a `Boundary` sub-boundary declared in `lib/relay.ex` and listed in
`Relay`'s `exports` — that list is the authoritative context inventory; this page annotates
it. Schemas live in the `Schemas` peer (ADR 0002) so web and domain share structs without
sharing behavior.

## Contexts

- **Boards** — boards and their stage tree (stages, sub-lanes, review gates, WIP limits,
  `ai_enabled`). Stage/config semantics: [ADR 0003](../adr/0003-card-state-stage-type-validity.md).
  Also holds the RLY-69 public-board settings (`public_enabled` + `public_intake_stage_id`,
  written via `update_public_settings/2`) and `list_public_cards/1`, the public roadmap's
  card query (non-archived, stage category in `Stage.public_categories/0`).
- **Flows** — workflow definitions as declarative graph data (ADR 0006 / RLY-131): per-board
  rows in the `flows` table (`key`, `enabled`, `isolation`, `version`, three trigger stage FKs
  stored as ids with nilify-on-delete) with the node/edge graph embedded as jsonb; `"start"`/
  `"done"`/`"needs_input"` are edge sentinels (`"needs_input"` is `to`-only and parks the run —
  RLY-194); nodes carry an optional `timeout_minutes` (validated `> 0`) and an agent-only
  `expects_commits` boolean (default `false`, RLY-194) marking a node whose reported success
  `RunServer` may override if it produced no commits.
  Every node also carries a `reads`/`writes` **card-field contract** (RE244; vocabulary
  `Schemas.Card.contract_fields/0`) — `writes` is enforced at run time by
  `RunServer.override_missing_writes/4`, `reads` is advisory.
  The invariant that no `:agent`/`:gate`
  node in any shipped flow leaves `:failed` unrouted is enforced by
  `default_library_test.exs`.
  `Relay.Flows.seed_default_flows!/1` idempotently seeds the default spec/plan/code library
  (from `Relay.Flows.DefaultLibrary`, which **loads** `docs/designs/flows/*.json` at
  compile time via `@external_resource` — those files are the source of truth, and
  `Relay.Flows.Document` is the one serializer both they and the API go through)
  — `Boards.create_board/2` calls it after enabling the `Spec:Review`/`Spec:Done`/`Plan:Done`
  sub-lanes so every trigger resolves. Flows seed disabled; at most one enabled flow may pull
  from a stage (partial unique index). Nothing executes yet — the engine is the Runs card (02).
  **Versioning (RLY-152, absorbed into the flow editor card):** every flow's definition
  (nodes, edges, isolation) is versioned — `flows.version` holds the current number, and each
  version is snapshotted immutably into `flow_versions` (`belongs_to :flow`, `version`,
  `isolation`, embedded `nodes`/`edges`; no `updated_at`, never edited after insert). A flow
  always has a snapshot row for its current version — created on `create_flow/2`,
  `duplicate_flow/1`, and `seed_default_flows!/1`, and on every bump — the invariant a future
  Runs pin-to-version feature relies on. `save_definition/2` is the one path that changes a
  flow's definition after creation: it validates like `update_flow/2`, then bumps `version` to
  n+1 and writes a new snapshot **only if** the definition changed; a trigger-only change
  (including a stage rename) saves with no bump, since triggers are per-board wiring and not
  part of the versioned definition. `get_version/2` fetches an immutable snapshot by number;
  `mid_run_count/1` returns the real count of cards currently mid-run on a flow — runs whose
  status is active (`Schemas.Run.active_statuses/0`, i.e. running or parked) — and feeds both
  the flow-editor save note and the delete-confirm warning, so that number is defined once.
  **Serialization (RLY-241):** `Relay.Flows.Document` is the one serializer for a flow's canonical
  JSON document — `encode/1` (sparse: nil and schema-default fields omitted) and `decode/1`
  (dense: every node/edge field present, filled from the schema default, so `customized?/1`'s
  field-by-field comparison against the embedded structs stays exact). `decode ∘ encode` is a
  fixed point, which is what makes pull → push unchanged a no-op. Triggers serialize as stage
  **names**, not ids, so a document is portable across boards.
  `upsert_from_document/3` is the write path behind `PUT /api/flows/:key`: decode → key check →
  resolve trigger names → optional compare-and-swap on `version` → `create_flow/2` or
  `save_definition/2` → reconcile `enabled` through `enable_flow/1`/`disable_flow/1`, all in one
  transaction so a push never half-applies.
  The Flows settings tab (RLY-142) is backed by `customized?/1`
  (normalized nodes/edges/isolation comparison against the library — trigger wiring never
  counts), `default_key?/1`, `duplicate_flow/1` (disabled `<key>-copy` clone),
  `unique_key/2` (the `base`/`base-2`/… generator behind both `-copy` and the create form's
  prefilled key), create-from-scratch (RLY-158 — the tab's "+ New flow" panel collects a key,
  all three trigger stages and isolation, then calls `create_flow/2` with an empty
  `start → done` skeleton and hands off to the editor; the flow is created disabled, so
  creation can never breach the one-enabled-flow-per-stage rule), and
  `reset_to_default/1` (restores the shipped definition via `save_definition/2`, so a reset
  bumps the version and snapshots like any other save; triggers and `enabled` untouched), and
  `delete_flow/1` (RLY-221 — removes a flow from this board, disable-first: an enabled flow
  returns `{:error, :flow_enabled}`, a disabled one is deleted and the DB cascade nil-s each
  active run's `flow_id` (`runs.flow_id on_delete: :nilify_all`) and removes its version
  snapshots (`flow_versions.flow_id on_delete: :delete_all`); a deleted shipped default does
  not re-seed on the next deploy).
  `diff_from_default/1` structurally diffs a customized default flow against its shipped
  default (`nil` for a non-library key) — nodes grouped added/removed/changed (changed lists
  the differing fields), edges as `{from, to, on}` tuples grouped added/removed.
  **Editor (RLY-143):** `RelayWeb.FlowEditorLive`, a full-page LiveView at
  `/board/:slug/flows/:key`, edits a flow's working copy (nodes/edges/isolation/triggers) with
  inline validation against `Schemas.Flow.changeset/2`, saves through `save_definition/2`
  behind a "Save as v(n+1)" confirm modal, and offers the diff-vs-default / reset-to-default
  affordance for customized library flows. The graph is rendered by the shared
  `RelayWeb.FlowGraphComponents.flow_graph/1` function component (absolutely-positioned node
  divs + an SVG edge layer, `interactive?` toggles `phx-click`, accepts `node_states` for a
  later read-only reuse by the run panel) laid out by the pure, unit-tested
  `RelayWeb.FlowLayout.layout/2` (a deterministic vertical layout derived from graph
  structure alone: the `:succeeded` spine runs straight down a single column, off-spine
  rework nodes sit in a second column, and backward edges pack into right-hand gutter lanes —
  no stored coordinates, no dragging).
  **Requirements (RLY-182):** `Flows.node_requirements/1` is a pure graph read — the agent
  and skill names a flow's nodes name, with no executor knowledge. It lives here rather than
  in Runs because `Flows` may not depend on `Runs` (a boundary cycle the compiler rejects);
  `Runs` reads it to answer whether anyone can actually satisfy it.
- **Runs** — the workflow execution engine (ADR 0006 card 02 / RLY-132): a run executes a
  `Schemas.Flow` graph against a card as a supervised, Postgres-backed state machine. This
  boundary owns five things.
  **The engine** (`Relay.Runs.Engine` / `RunServer`): outcome routing, per-node `max_retries`,
  per-edge `max_loops`, the visit cap, the failure-signature breaker (whole-run), needs-input
  parking and restart resume — budgets are per-`foreach`-iteration.
  **The scheduler brain**: `Relay.Runs.Scheduler.plan/1`, a pure `Snapshot → Plan` behind a
  per-board `Scheduler.Server`; `capacity_diagnosis/1` turns an empty/silent roster into a verdict.
  **The read side**: `list_runs_for_card/1`, `latest_run/1`, `run_summaries_for_board/1`,
  `run_summary_for_card/1`, `happy_path/1`, `queued_flow/4`, `face_summary/4` — one shared
  private builder, so the summary shape is defined exactly once.
  **The board-health audit** (RE249): `Relay.Runs.audit/2` / `Relay.Runs.Audit.findings/2`, a
  pure function over runs (`:node_executions` preloaded) on the metrics' `metric_windows/0`
  vocabulary, answering *is this board's history clean?*; owns `severities/0`/`checks/0`, advisory.
  **The dispatcher seam**: the `Relay.Runs.Dispatcher` behaviour (`config :relay, :runs_dispatcher`).
  Card writes go through `Relay.Cards`, so ADR 0003/0004 rules apply automatically.
  Run/node/job statuses are in [state.md](state.md); dispatch, the executor, worktrees and the
  transport in [runner.md](runner.md); the failure grid in [failures.md](failures.md). Why:
  [ADR 0006](../adr/0006-workflow-orchestration.md), [ADR 0007](../adr/0007-card-lifecycle-and-failure-states.md); per-function detail in the `Relay.Runs` `@moduledoc`.
- **Cards** — the card lifecycle: create/edit/move/archive, status (`working`,
  `needs_input`, `failed`, …), sub-tasks, spec/plan/branch/pr fields, approve/reject,
  needs-input questions. `failed` (RLY-179) is set only by `Relay.Cards.mark_failed/3` when a
  run ends terminally — a separate path from `needs_input`'s genuine question. Card state ×
  stage validity is governed by
  [ADR 0003](../adr/0003-card-state-stage-type-validity.md); ownership and the claim rule
  by [ADR 0004](../adr/0004-card-ownership-and-the-claim-rule.md); derived agent health
  (`Cards.health/1`, 90s `STALE_AFTER`) and the four-bucket needs-you rollup
  (`needs_input` / `in_review` / `awaiting_human` / `agent_stalled` — RLY-148) surfaced by
  `GET /api/board` and the boards-home badges. A move that would strand a live run
  (`Cards.stranded_run/2`: an active run whose flow `works_in_stage` is not the destination) is
  refused up front with `{:error, :would_strand_run}` — `POST /api/cards/:ref/move` maps it to
  **409 `would_strand_run`** (RLY-217); the board pre-checks and confirms instead of surfacing
  the raw error.
- **Members** — board membership; who can see and act on a board.
- **Accounts** — users and Google sign-in (`GoogleTokenValidator` verifies native mobile
  tokens); user API tokens for `/api/all`.
- **ApiKeys** — per-board agent credentials for the `/api` scope.
- **Activity** — the card timeline: comments, activity entries, and runner log rows.
  `Activity.LogSink` batches ref-tagged runner lines into one insert per burst;
  `Activity.Pruner` ages `:action` chatter out after 14 days (RLY-112).
- **AgentLog** — stateless live relay of runner feed lines to the board's log sheet
  (subscribe-only; no server buffer, no backfill — RLY-55).
- **Events** — the realtime seam: contexts broadcast semantic domain events after each
  successful mutation (never controllers/LiveViews), so LiveView and REST mutations share
  one notification path. See [runtime.md](runtime.md) for the topic/event vocabulary.
- **BoardWatch** — per-board monotonic version counter in ETS; bumped on every
  `Events.broadcast/2`, polled by the CLI to cheaply detect change (RLY-12).
- **Attachments** — file uploads onto cards, served by `AttachmentController`.
- **Push** — APNs notifications, dispatched off-caller via a `Task.Supervisor` so a status
  change never waits on Apple (RLY-81).
- **Votes** — public upvotes (RLY-69): a unique `(card_id, user_id)` row; `toggle_vote/2`
  toggles and broadcasts `{:vote_changed, card_id}`. A card's supporters are the voting users.
- **StoryMap** (`Relay.StoryMap`) — the board's second lens (RE265), orthogonal to stages:
  `Schemas.StoryActivity` (big user goals, left to right), `Schemas.StoryTask` (the backbone,
  ordered within an activity; `board_id` denormalized so every read is one board-scoped
  `where`), and `Schemas.Release` (the swimlanes — a **new axis orthogonal to stage**; every
  board is seeded with `Schemas.Release.seed_names/0` by `Boards.create_board/2`, every
  pre-existing board by the `backfill_story_map_releases` migration, which carries the one
  deliberately frozen copy of that list). Cards carry three nilable FKs —
  `story_activity_id`, `story_task_id`, `release_id` — plus (RE262) `story_map_position`, all
  cast only through `Schemas.Card.story_map_changeset/2`, starting fully UNMAPPED, with release
  independent of activity/task. *A set `story_task_id` implies the matching `story_activity_id`*, enforced by
  derivation in `assign_card/2` (the task supplies its activity; a conflicting one passed
  alongside is ignored), by `update_task/2` (moving a task to another activity rewrites its
  mapped cards' `story_activity_id` in the same transaction), and by the changeset as a
  backstop. Deleting structure **unmaps**
  cards, never deletes them (`cards → structure` is `nilify_all`, `activity → its tasks` is
  `delete_all`). Structure writes broadcast `{:story_map_changed, board_id}`; assignment reuses
  `{:card_upserted, card}` via `Cards.notify_upserted/1`. `Relay.Boards` deliberately does
  **not** depend on this context — `StoryMap → Cards → Boards` already exists, so the reverse
  edge would close a boundary cycle; the release seed therefore lives in `Boards`.
  **View (RE264, RE263):** the backbone × releases grid at `/board/:slug/story-map`, a
  `:story_map` live_action on `RelayWeb.BoardLive` rather than its own LiveView — clicking a
  card must open the card drawer *in place*, and the drawer's ~50 assigns and ~40 event
  handlers live in `BoardLive`; a separate LiveView could only honour that by duplicating them
  or extracting the drawer's whole state machine. The grid itself is isolated: the pure,
  unit-tested `RelayWeb.StoryMapGrid.build/5`
  (`(activities, tasks, releases, cards, draft)` → bands, columns, lanes, cells, unmapped —
  every card placed exactly once, an activity-less card in the tray, a release-less mapped card
  in the LAST lane, a release-less board in one synthetic `(No release)` lane) plus
  `RelayWeb.StoryMapComponents` for the render.
  `RelayWeb.CoreComponents.board_view_tabs/1` is the Board ↔ Story map switch.
  **Create (RE263):** three affordances — a trailing `＋` add-activity column, a per-activity
  `＋ Add task`, and an `＋ Release` row — all committing through one `inline_name_input/1`.
  Which one is open is the single `:story_map_draft` assign on `BoardLive`
  (`nil | :activity | :release | {:task, activity_id}`, one draft at a time board-wide), and it
  is the `draft` argument to `build/5`: the draft materializes a `"draft:<activity_id>"` column
  that carries no `cells`, and every column gains `bare?` / `draft?`. Names are trimmed and
  capped by `Schemas.StoryActivity.max_name_length/0` — the one definition, shared by
  `StoryTask` and `Release`, so an over-long paste is an error changeset rather than a Postgrex
  22001 crash. On an archived board the four write events are refused *and* the affordances are
  not rendered (`read_only`, the same attr name and behaviour as the stage column's compose
  `＋`).
  **Assignment (RE262):** the map is writable — drag a card between cells, drag it out of or
  onto the UNMAPPED tray, and an inline `＋` per cell that creates a real board card in
  `Boards.intake_stage/1` (the board's first top-level stage by position — the one definition of
  "where a card created outside a column lands") and places it. `StoryMap.assign_card/2` takes
  an optional 0-based `:position` and renumbers the whole target DB cell `1..n` in one
  transaction; `unassign_card/1` nils the position with the three FKs, so a card in the tray has
  no story-map position. `RelayWeb.StoryMapGrid.decode_placement/2` parses the column/lane keys
  that same module defines, and the `StoryMapDnD` hook (`assets/js/hooks/story_map_dnd.js`)
  pushes `{ref, column, lane, index}` — no optimistic client move, so a second tab follows for
  free.
  Still to come: edit (RE261) and zoom (RE260).
- **Markdown**, **Mailer**, **Repo** — rendering, mail, and Ecto plumbing.

## Core schemas

```mermaid
erDiagram
    User ||--o{ Board : owns
    Board ||--o{ Stage : has
    Stage |o--o{ Stage : "parent / sublanes"
    Stage ||--o{ Card : holds
    Board ||--o{ Card : has
    Board ||--o{ Flow : "flow definitions"
    Stage |o--o{ Flow : "trigger (pulls-from / works-in / lands-on)"
    Flow ||--o{ FlowVersion : "immutable version snapshots"
    Card ||--o{ SubTask : has
    Card ||--o{ CardOwner : "owners (user or agent)"
    Card ||--o{ Comment : timeline
    Card ||--o{ Activity : timeline
    Card ||--o{ Attachment : has
    Card ||--o| CardRejection : "embeds (CHANGES REQUESTED)"
    Card ||--o{ Run : "flow traversals"
    Flow |o--o{ Run : "live definition (nilified on delete)"
    Run ||--o{ NodeExecution : "per-attempt history"
    NodeExecution ||--o| NodeJob : "dispatch unit"
    Board ||--o{ Executor : "registered executors"
    Board ||--o{ Membership : has
    Board ||--o{ StoryActivity : "story map activities"
    Board ||--o{ StoryTask : "story map tasks"
    StoryActivity ||--o{ StoryTask : "backbone (cascade delete)"
    Board ||--o{ Release : "story map swimlanes"
    StoryActivity |o--o{ Card : "story_activity_id (nilified on delete)"
    StoryTask |o--o{ Card : "story_task_id (nilified on delete)"
    Release |o--o{ Card : "release_id (nilified on delete)"
    User ||--o{ Membership : has
    Board ||--o{ ApiKey : "agent credentials"
    User ||--o{ UserApiToken : "mobile bearer"
    User ||--o{ DeviceToken : "push"
    Card ||--o{ Vote : upvotes
    User ||--o{ Vote : cast
```

A `Stage` may point at a `parent` (sub-lanes like `Spec:Review`) and a `reject_to_stage`
(where a rejection sends the card). `Scope` (not shown) is the per-request authorization
context threaded through web and API entry points.

A `Card` additionally carries an optional story-map placement — `story_activity_id`,
`story_task_id` and `release_id`, all nilable, all nilified rather than cascaded when the
structure they point at is deleted. Release is a **new axis orthogonal to stage**: a card has
both.

A `Card` also carries `story_map_position`: its order **within its story-map cell**, nullable
and independent of `cards.position` (its order within its stage column). The two orderings never
affect each other — dragging on the map rewrites one, dragging on the board the other. `nil`
means nobody has ordered the card on the map yet, and nil sorts **last** inside a cell. Placing a
card renumbers its whole target cell, and the **siblings** are renumbered with a bare
`update_all` so their `updated_at` is untouched — that column is the recency proxy behind the
Done column's render window and the needs-you feed, both board-lens orderings that would
otherwise be silently reshuffled by a drag on the map.

---
*Sources of truth: `lib/relay.ex` (`exports`), `lib/schemas/*.ex`, ADRs 0002–0004, 0006.*
