# MMF 06 — The baton: stage ownership + card status
**Milestone:** ⭐ MVP   **Depends on:** 02, 03
**Design:** owner pills, card status badges, PROPERTIES RAIL owners (`Relay Board.dc.html`, Design System §Actors/§Status)   **Size:** ~1 loop

## Value
The core of Relay: at a glance you can see **who holds each card** (human vs AI) and **what
state it's in**. This is the signal the whole product is built around.

## In scope
- Card `status` enum: `queued | working | needs_input | in_review | done`, plus a `progress` int.
- **Ownership lives on the card** as a settable **list of actors** (`card_owners`); an actor is a
  user or the single **Relay AI agent** — the AI is just one owner among many. **Active owner**
  is derived from the list (AI active if present, else humans; others show **paused**). Nothing
  changes automatically — owners/status change only on explicit human or agent action.
- `Stage.owner` is retained as the **"meant for"** designation (not the card's owner).
- Visual system: active Human=blue / active AI=violet left-border + owner pill; `needs_input`
  amber; **red mismatch (both directions)** when the card's active-owner type ≠ its stage's
  owner ("meant for agents" / "meant for humans"); status badge (working·%, in-review, done).
- Properties rail: ACTIVE WORKER + OWNERS (active/paused); set status + add/remove owners.
- **Foundational refactor folded in here:** shared `Schemas` boundary (ADR 0002) — migrate the
  existing schemas to `Schemas.*` with no behaviour change (see the design spec).

## Out of scope
- The interactive needs-input Q&A — MMF 14. Review-gate actions — MMF 15. AI progress % source
  (just store/display the number) — automation later. Auto-changing owners/status on move.

## Acceptance criteria
- [ ] Each card shows its active owner (Human/AI) color + pill and its status badge.
- [ ] A card whose owner type conflicts with its stage's owner shows the red mismatch warning
      (both directions).
- [ ] A `needs_input` card shows the amber "NEEDS INPUT" treatment on the board.
- [ ] The drawer rail shows active worker + paused owners and can set status/owners.
- [ ] Existing schemas are migrated to `Schemas.*` with the suite/boundary check green.

## Notes
- Status/owners are just data now; MMFs 14/15 add the human-facing flows, MMF 09 lets the agent
  drive them. Keep the enum + card-owned actor list authoritative here.
- Design spec: [`../superpowers/specs/2026-07-07-baton-ownership-status-design.md`](../superpowers/specs/2026-07-07-baton-ownership-status-design.md).
