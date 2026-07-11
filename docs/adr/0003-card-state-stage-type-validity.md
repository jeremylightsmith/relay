# ADR 0003 — Card state × stage type validity

## Status
Accepted (2026-07-11)

## Context

RLY-46 replaces the `owner` / `lane` / `approval_gate` / `reject_to_stage_id` axes on
`Schemas.Stage` with a single behavioral axis: `type ::
:queue | :work | :planning | :review | :done` (plus `ai_enabled`, meaningful only for
`:work`/`:planning`). A sub-lane is now just a child stage (`parent_id` set) whose own
`type` is `:review` or `:done`; the old MMF 13 approval gate is simply "the card sits in a
`:review`-type stage," and the reject target is chosen at reject time (default: the nearest
earlier main stage) rather than stored on the stage.

That leaves an open question the old model answered implicitly via `arrival_status/1`
(purely a function of the stage's `owner`): **which of the existing card statuses
(`:queued :working :needs_input :in_review :done`) makes sense in a stage of a given
type, and what should a card default to when it lands there?** Without an explicit answer,
every mover (drag, "Move to…", the API, the runner, approve/reject/send-back) would have to
independently guess, and nothing would stop a `:done` card from silently sitting in a
`:queue` column or a `:working` card from parking in `:review`.

## Decision

**The validity matrix** — a status is valid in a stage of a given type, and a stage's
default (the status a card takes when it has no valid status to keep) is:

| Stage type | Valid statuses | Default on entry |
| --- | --- | --- |
| `queue` | `queued` | `queued` |
| `work` / `planning` | `working`, `queued`, `needs_input` | `working` |
| `review` | `in_review`, `done` | `in_review` |
| `done` | `done` | `done` |

Encoded as `Schemas.Stage.valid_status?/2` and `Schemas.Stage.default_status/1` — pure,
stateless functions with no DB access, so every caller (contexts, LiveView, tests) shares
one source of truth.

Notable choices baked into the matrix:

- **`work`/`planning` default to `:working` regardless of `ai_enabled`.** This is a *pull*
  model: a card lands "in motion" whether the stage is AI-listened or human-worked, and
  `ai_enabled` only decides whether Relay's agent polls it — it doesn't gate the status.
- **`:queued` means "parked, ready to be pulled"** — valid in `work`/`planning` stages too
  (not just `queue`), so a card can wait its turn in a busy work column without an
  artificial bounce through a queue stage.
- **`:needs_input` is kept valid in `work`/`planning`** so a card dragged (or approved) into
  a work-type stage while blocked on a human doesn't silently drop its open question — the
  snap (below) only overrides an *invalid* status, and `needs_input` is explicitly valid
  there.
- **`:done` is valid in `review`** for two reasons: approving from the board's last main
  stage completes the card in place (no next main stage to move to — see
  `Relay.Cards.approve/2`), and an already-`:done` card that later passes back through a
  review stage (e.g. a redo that climbs past its origin) must not be silently reopened.

**The snap rule is one code path.** `Relay.Cards.move_card/4` — the single funnel every
mover uses (drag-and-drop, the drawer's "Move to…", the REST API, the agent runner,
`approve`/`reject`/`send_back`) — snaps a card's status on every **cross-stage** move: if
the card's current status is valid for the destination type it is left alone, otherwise it
is set to the destination type's default (`Schemas.Stage.valid_status?/2` then
`default_status/1`, via `Relay.Cards.set_status/3` so `blocked_since` bookkeeping and
activity logging still run). A same-stage reorder never touches status. The same rule
re-applies to a stage's **resident cards** when its `type` changes in settings, via
`Relay.Cards.snap_cards_in/1`.

## Consequences

- Every stage-type combination has a well-defined entry status; no mover needs its own
  arrival-status logic, and none can leave a card in a status invalid for the column it
  sits in.
- Approve/reject/send-back no longer set an explicit arrival status — they simply move the
  card, and the snap in `move_card/4` handles arrival. This is *why* `route/6`,
  `approve_in_place/3`, and `send_back/4` got simpler in this change: one fewer
  responsibility to keep in sync with the matrix.
- A dragged `:needs_input` card survives a move into another `work`/`planning` stage — the
  question stays open — but is force-resolved (to that type's default) the moment it lands
  somewhere `needs_input` isn't valid (`queue`, `review`, `done`).

### Deliberate deviation: `done`-type stages snap to `:done`, not `:ready`

The spec's sketched card-state model distinguishes a card mid-board that's finished its
current stage's work ("ready to advance") from one that has reached the board's terminal
`Done` column. This ADR does **not** introduce that distinction yet: every `done`-type stage
— whether it's the board's terminal column or an earlier "Done sub-lane" a card visits
mid-flow — snaps a card straight to `:done`. That is a deliberate, temporary simplification:
introducing a `:ready` status and the mid-board/terminal-done split is deferred to a later,
dedicated card-sub-state reframe. Until then, `:done` is overloaded to mean "this stage's
work is finished," and the matrix above should be read with that caveat.

## Alternatives considered

- **Store an explicit arrival status per stage** (like the old `owner`-keyed
  `arrival_status/1`), configurable in settings. Rejected: it re-introduces a second,
  independently-configurable axis the type already implies, and doesn't explain what
  happens when a card's *current* status doesn't match — the keep-or-default snap needs the
  validity matrix regardless.
- **Validate status transitions instead of stage-entry validity.** Rejected: a
  transition-graph model doesn't compose with "a stage's type changed under a resident
  card" (`snap_cards_in/1`), which needs a pointwise validity check, not a transition rule.
