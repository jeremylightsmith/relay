# MMF 10b — Stage substages (Review / Done sub-lanes)
**Milestone:** Post-MVP (slots BEFORE MMF 11 — WIP limits)   **Depends on:** 05, 06
**Design:** `Relay Board.dc.html` — board `stages`/`lanes` + BOARD SETTINGS §STAGES (`DONE COLUMN`, `REVIEW SUB-LANE`)   **Size:** ~1 loop

## Value
A stage can carry optional **Review** and/or **Done** sub-lanes, so finished or
under-review work waits *in place* at the end of a stage before it's handed off — the
kanban "done column" pattern, plus an explicit review holding area. Makes each stage's
internal flow legible without inventing whole new top-level columns.

## Model (decision)
**Substages are modeled AS stages.** A sub-lane is a child `Stage` of its parent
(e.g. a `Code` stage may have `Code:Review` and `Code:Done` sub-lanes). Implement via a
`Stage.parent_id` (self-reference) + a `Stage.lane` role enum `main | review | done`; the
parent stage is the `main` lane. (The `parent:child` name is the display convention; the
relationship is the FK.) On the board, a stage column renders its `main` lane and any
`review`/`done` child lanes stacked underneath, each with its own label, card count, and
cards. Sub-lanes are optional and toggled per stage (see below). See project decision in
memory `substages-model`.

## In scope
- `Stage.parent_id` (nullable self-ref) + `Stage.lane` enum (`main`/`review`/`done`); a
  parent stage has at most one `review` and one `done` child. Migration + schema + factory.
- Stage settings toggles **REVIEW SUB-LANE** and **DONE COLUMN**: enabling creates the child
  stage; disabling removes it (guard: refuse/relocate if it holds cards).
- Board renders sub-lanes grouped under the parent stage (lane label + count + cards),
  matching the mockup's `lane` rendering.
- Cards can be moved into a sub-lane (extends MMF 05 move to target `main`/`review`/`done`).

## Out of scope
- Approval-gate *behavior* on the review lane (MMF 13). Per-lane WIP (MMF 11). Card **skip**
  action `↷` seen in the refreshed mockup — fold into MMF 06/05 as a small follow-up.

## Acceptance criteria
- [ ] A stage can toggle on a Review sub-lane and/or a Done sub-lane (persisted as child stages).
- [ ] The board renders those sub-lanes stacked under the parent stage with their own counts.
- [ ] A card can be moved into a stage's Review or Done sub-lane and renders there.
- [ ] Toggling a non-empty sub-lane off is guarded (cards are relocated or the toggle is blocked).

## Notes
- Keep `Boards`/`Cards` queries lane-aware. This MMF makes MMF 12 (stage config) and MMF 13
  (approval gates) land cleanly on top. The refreshed board mockup (2026-07-07) is the source.
