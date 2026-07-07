# MMF 05 — Move cards between stages
**Milestone:** ⭐ MVP   **Depends on:** 03
**Design:** board columns (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Work flows. A user can move a card from one stage to the next (or reorder within a stage) —
this *is* passing the baton across the board.

## In scope
- Drag a card between stages and to a new position; persist stage_id + position.
- Keyboard/menu fallback ("Move to…") for accessibility and API parity.
- Stage lane counts update as cards move.
- Emit a stage-change so downstream automation/activity can react (activity log in MMF 07).

## Out of scope
- WIP-limit enforcement — MMF 11. Approval gates on move — MMF 13. Cross-client live sync — MMF 18.

## Acceptance criteria
- [ ] Dragging a card to another stage persists and re-renders it there after reload.
- [ ] Reordering within a stage persists position.
- [ ] Lane counts reflect the card's new location.
- [ ] A non-drag "Move to <stage>" path produces the same result.

## Notes
- Use LiveView drag hooks (phx-hook) with `phx-update` on stage containers. Moving a card into
  a stage sets the card's owner via the stage (see MMF 06).
