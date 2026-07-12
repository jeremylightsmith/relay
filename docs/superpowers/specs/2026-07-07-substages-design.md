# MMF 10b — Stage substages (Review / Done sub-lanes) — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/10b-substages.md`](../../mmfs/10b-substages.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP

> **Superseded (RLY-76):** Approve from a review substage advances to the parent's **Done
> substage** when it exists (the "next stage or substage" rule), not straight to the next main
> stage. See [`docs/glossary.md`](../../glossary.md) (the routing authority).

**Depends on:** MMF 05 (move), 06 (owners/`Schemas`), 08 (`/board/settings`)
**Development:** trunk-based on `main`

## Overview

A stage can carry optional **Review** and/or **Done** sub-lanes so finished / under-review work
waits *in place* at the end of a stage before hand-off — the kanban "done column" pattern plus
an explicit review holding area, without inventing new top-level columns.

## Decisions

- **Sub-lanes are stages.** A sub-lane is a child `Schemas.Stage` of its parent via
  `parent_id` (self-ref) + a `lane` role enum `main | review | done`. The parent is the `main`
  lane; a parent has at most one `review` and one `done` child.
- **Sub-lanes carry their own `owner`, but it's fully predictable:** **Review = always
  `:human`**; **Done = mirrors the parent stage's `owner`.** Set at creation, never edited
  directly.
- **Owner chrome renders only on the main stage.** Because review/done owners are predictable,
  sub-lanes show just label + count + cards — no owner pill. The MMF 06 red **mismatch** logic
  still applies per-lane under the hood (a human-owned card in a `review` lane is fine; an
  AI-owned card there would flag).
- **Toggled in `/board/settings`** (the pane from MMF 08), per stage.

## Data model

`Schemas.Stage` gains:

- `parent_id` — nullable self-reference (`belongs_to :parent, Schemas.Stage`).
- `lane` — `Ecto.Enum`, values `main | review | done`, default `:main`.

`Relay.Boards`: `enable_lane(stage, :review | :done)` (creates the child stage with the right
owner + position), `disable_lane(stage, lane)` (guarded — see below), and lane-aware board
loading so a parent's children are grouped under it.

## Behaviour / UI

- **Settings toggles** per stage: **REVIEW SUB-LANE** and **DONE COLUMN**. Enabling creates the
  child stage; disabling removes it. **Disabling a non-empty lane is guarded** — blocked (or the
  cards are relocated to the main lane) rather than silently dropping cards.
- **Board** renders `review`/`done` child lanes **stacked beneath the parent's main lane**, each
  with its own label + card count + cards.
- **Move (MMF 05) extended** so a card can be dropped into a stage's `main`/`review`/`done` lane;
  `move_card/3` targets a specific (sub-)stage as it already does.

## Testing

- A stage toggles a Review and/or Done sub-lane on; each persists as a child stage (Review owner
  `:human`, Done owner = parent's owner).
- The board renders the sub-lanes stacked under the parent with their own counts; no owner pill
  on sub-lanes, only on the main stage.
- A card can be moved into a Review or Done sub-lane and renders there.
- Toggling a non-empty sub-lane off is guarded (cards relocated or the toggle blocked).

## Acceptance criteria (from the MMF)

- [ ] A stage can toggle on a Review and/or Done sub-lane (persisted as child stages with the
      correct predictable owner).
- [ ] The board renders those sub-lanes stacked under the parent stage with their own counts.
- [ ] A card can be moved into a stage's Review or Done sub-lane and renders there.
- [ ] Toggling a non-empty sub-lane off is guarded (cards relocated or the toggle blocked).

## Out of scope

Approval-gate behaviour on the review lane (MMF 13), per-lane WIP (MMF 11), the card **skip**
action `↷` (folds into MMF 05/06 later), per-lane owner chrome.
