# MMF 06 — The baton: stage ownership + card status
**Milestone:** ⭐ MVP   **Depends on:** 02, 03
**Design:** owner pills, card status badges, PROPERTIES RAIL owners (`Relay Board.dc.html`, Design System §Actors/§Status)   **Size:** ~1 loop

## Value
The core of Relay: at a glance you can see **who holds each card** (human vs AI) and **what
state it's in**. This is the signal the whole product is built around.

## In scope
- Card `status` enum: `queued | working | needs_input | in_review | done`.
- A card's **owner** is derived from its stage's owner (Human/AI); when an AI stage is
  `working` a card, human owners show **paused**.
- Visual system from the design: Human=blue / AI=violet left-border + owner pill; status badge
  (working·%, NEEDS INPUT amber, ready/in-review, done green).
- Properties rail: ACTIVE WORKER + OWNERS (active/paused) reflecting stage owner & status.
- Status is settable (by a human here; by the API/agent in MMF 09).

## Out of scope
- The interactive needs-input Q&A — MMF 14. Review-gate actions — MMF 15. AI progress % source
  (just store/display the number) — automation later.

## Acceptance criteria
- [ ] Each card shows its owner (Human/AI) color + pill and its status badge.
- [ ] Moving a card into an AI stage sets owner=AI; into a human stage sets owner=Human.
- [ ] A `needs_input` card shows the amber "NEEDS INPUT" treatment on the board.
- [ ] The drawer rail shows active worker and paused owners consistent with status.

## Notes
- Status transitions are just data now; MMFs 14/15 add the human-facing flows, MMF 09 lets the
  agent drive them. Keep the enum + owner-derivation authoritative here.
