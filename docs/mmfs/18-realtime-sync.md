# MMF 18 — Real-time board sync
**Milestone:** Post-MVP   **Depends on:** 05
**Design:** live "working · %", pulsing indicators (`Relay Board.dc.html`/Landing)   **Size:** ~1 loop

## Value
The board is alive: when anyone — or the AI via the API — moves a card, changes status, or
posts a comment, everyone watching sees it instantly. This is what makes watching the AI work
feel real, and it's why Relay is built on LiveView.

## In scope
- Phoenix PubSub broadcasts on card/stage/comment/status changes, scoped per board.
- All open LiveViews for a board apply updates live (card moves, status/owner, new comments,
  lane counts) without reload.
- API-driven changes (MMF 09) broadcast the same way, so agent actions appear live.

## Out of scope
- Presence/avatars of who's viewing — later. Optimistic conflict resolution — later.

## Acceptance criteria
- [ ] A change in one session appears in another open session on the same board without reload.
- [ ] A move/comment/status made via the API updates open boards live.
- [ ] Broadcasts are board-scoped (no cross-board leakage).

## Notes
- Centralize broadcasts in the contexts so UI and API paths share one notification path.
