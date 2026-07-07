# MMF 15 — Review gate actions
**Milestone:** Post-MVP   **Depends on:** 06, 13
**Design:** drawer "READY FOR YOUR REVIEW" — approve / request changes / mark done / pull (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
The human side of the handoff: review AI output and either approve it forward, send it back
with feedback, or mark it done — the control point that keeps a person in charge.

## In scope
- Drawer action panel for a card in `in_review`: **Approve** (advance), **Request changes**
  (send back to the reject-target stage per MMF 13, with a note), **Mark done**, **Pull** (claim
  the card / take ownership).
- Each action writes activity (MMF 07) and transitions status/stage.

## Out of scope
- Gate configuration — MMF 13. AI result rendering — MMF 16.

## Acceptance criteria
- [ ] A card in `in_review` shows approve / request-changes / mark-done / pull.
- [ ] Approve advances; request-changes routes back per the gate config with the note attached.
- [ ] Mark done sets `done`; each action is logged in activity.

## Notes
- Reuses the routing from MMF 13 and the same transitions the API exposes (MMF 09).
