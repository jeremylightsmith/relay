# MMF 12 — Stage configuration UI
**Milestone:** Post-MVP   **Depends on:** 06
**Design:** BOARD SETTINGS §STAGES (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Teams shape the board around how they actually work — the design's promise that "no two teams
relay the same way." Turns the seeded pipeline into something owned by the user.

## In scope
- Settings → Stages pane: list stages grouped by the three categories.
- Per stage: rename, reorder (↑/↓ or drag), delete, move between categories, set OWNER
  (Human/AI segmented), and toggle the **Review sub-lane** and **Done column** sub-lanes
  (the sub-lane model itself lands in [MMF 10b](10b-substages.md); this MMF exposes the toggles
  in settings, matching the mockup's `REVIEW SUB-LANE` / `DONE COLUMN` controls).
- "Add stage to <category>".
- Guard rails: can't delete a stage with cards without moving them; keep ≥1 stage.

## Out of scope
- WIP field — MMF 11. Approval gate + reject routing — MMF 13.

## Acceptance criteria
- [ ] Add/rename/reorder/delete/move-category persist and reflect on the board.
- [ ] Changing a stage's owner updates its cards' owner (per MMF 06 derivation).
- [ ] Deleting a non-empty stage is blocked or forces a reassignment.

## Notes
- Reorder + category are the same data used by MMF 02's seed; this exposes it for editing.
