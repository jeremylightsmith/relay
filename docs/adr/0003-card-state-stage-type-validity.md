# ADR 0003 — Card state × stage type validity

## Status

Accepted

## Context

A stage's behaviour is one axis, its `type` (`Schemas.Stage.types/0`: `queue`, `work`,
`planning`, `review`, `done`). A substage is a child stage whose type is `review` or `done`. A
card's status (`Schemas.Card.statuses/0`: `ready`, `queued`, `working`, `needs_input`,
`in_review`, `failed`) says whose turn it is and whether anything is holding it.

Cards change stage through many movers: a board drag, the drawer's "Move to…", the REST API,
the run engine, approve, reject, and a stage whose type is edited under its cards. Without one
rule saying which statuses make sense in which stage type, each mover would guess, and nothing
would stop a `working` card from sitting in a review gate or an `in_review` card in a queue.

## Decision

**The validity matrix.** A status is valid in a stage of a given type, and each type has a
default:

| Stage type | Valid statuses | Default |
| --- | --- | --- |
| `queue` | `ready`, `queued` | `ready` |
| `work` / `planning` | `working`, `ready`, `needs_input`, `failed` | `working` |
| `review` | `in_review` | `in_review` |
| `done` | `ready`, `queued` | `ready` |

It is encoded once, as pure functions on the schema: `Schemas.Stage.valid_status?/2`,
`Schemas.Stage.default_status/1`, and the arrival rule that combines them,
`Schemas.Stage.arrival_status/2`: **keep the card's status if it is valid in the destination
type, otherwise take that type's default.**

**Every arrival goes through the arrival rule.** That covers creating a card in a stage, a
cross-stage `Hamaca.Cards.move_card/4` (which every mover uses), the untrusted
`PATCH /api/cards/:ref` status write (`Hamaca.Cards.set_status_snapped/3`), a stage-type edit
(`Hamaca.Cards.update_stage/2` re-snaps resident cards via `snap_cards_in/1`), and re-homing
archived cards when a stage is deleted. A same-stage reorder never touches status. The rule only
ever writes a type's default, so `queued`, `needs_input` and `failed` come only from their own
writers: the scheduler (`ready ↔ queued`), a node asking a question (`request_input`), and a run
failing (`mark_failed`).

What the matrix says, and why:

- **A work or planning stage defaults to `working`**, whether or not a flow works it. A card
  lands in motion; whether an agent picks it up is the flow's business, not the status's.
- **`ready` is valid in work and planning stages**, so a card can wait its turn in a busy work
  column without a detour through a queue.
- **`needs_input` and `failed` are valid in work and planning stages**, so moving a blocked or dead
  card to another work stage doesn't silently drop its open question or its failure. Moving it
  anywhere else resolves it to that type's default.
- **A review stage holds only `in_review`.** Any card that lands in a review gate is reviewable
  and rejectable.
- **`queued` means capacity-blocked**: a flow would pull the card, but no runner has a free
  slot. A card held back by a WIP limit stays `ready`. `queued` is valid only in the queue and
  done stages flows pull from, and it is never a default.
- **There is no `done` status.** Done is derived: a `ready` card at the board's terminal stage
  reads as Done (`Hamaca.Cards.done?/2`). A `ready` card in a mid-board Done substage is only
  parked.

A few writers set a status the arrival rule wouldn't pick, because the move alone doesn't say
enough: starting a run sets `working`, a reject sets `ready` (so the card reads as handed back
for rework), and an approve at the board's terminal stage sets `ready` in place. The
status-by-status detail and every trigger are in
[`../architecture/state.md`](../architecture/state.md).

## Consequences

- No mover needs its own arrival logic, and none can leave a card in a status invalid for the
  column it's in. Approve, reject and the engine just move the card and let the arrival rule do
  the rest.
- A status that is still valid rides across a move unchanged. A `failed` card dragged onto
  another work stage stays `failed`; a `working` card dragged to another work stage still reads
  `working` even though nothing is running there. That's the price of keep-if-valid.
- Changing the matrix changes what every mover does at once. The data has to be re-snapped by
  a migration, because existing rows aren't re-checked until they move.

## Alternatives considered

- **An explicit arrival status per stage, configurable in settings.** Rejected: it adds a second
  axis the type already implies, and it still needs a validity check to decide whether a card's
  current status should survive the move.
- **Validate status transitions instead of stage-entry validity.** Rejected: a transition graph
  can't answer "this stage's type just changed under its cards", which needs a pointwise
  validity check.

## Open questions

- **Approving at the terminal stage leaves a `ready` card in a review stage**, which the matrix
  doesn't allow. When the review gate has no next stage or substage (the board's last main stage
  is a review stage, or it has a Review substage and no Done substage),
  `Hamaca.Cards.approve/2` completes the card in place as `ready` so it derives Done. Should the
  matrix admit `ready` there, or should a board always end in a `done`-type stage?
