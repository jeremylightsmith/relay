# MMF 03 — Create & title cards
**Milestone:** ⭐ MVP   **Depends on:** 02
**Design:** stage compose CTA + card (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
A user can add work to the board. Cards appear in the right column and persist — the board
becomes usable for real.

## In scope
- `Card` schema (board_id, stage_id, title, position, tag, ref/number, created/updated).
- Stage "compose" CTA → inline new-card input → creates a card at the bottom of that stage.
- Cards render in their stage: title, `#tag` (optional), card ref.
- Card ordering within a stage (position).

## Out of scope
- Description/detail — MMF 04. Moving between stages — MMF 05. Status/owner badges — MMF 06.

## Acceptance criteria
- [ ] Using a stage's compose CTA creates a card in that stage and clears the input.
- [ ] Cards persist and re-render in position order on reload.
- [ ] Each card shows its title and ref; an empty stage shows its empty state.
- [ ] Creating a card assigns a per-board incrementing ref (e.g. `RLY-12`).

## Notes
- Add a `Cards` context. Ref numbering is per board.
