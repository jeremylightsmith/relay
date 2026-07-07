# MMF 13 — Approval gates & reject routing
**Milestone:** Post-MVP   **Depends on:** 12
**Design:** BOARD SETTINGS §STAGES — APPROVAL GATE / SEND REJECTS TO (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Lets a human stage act as a checkpoint: work must be approved to advance, and rejected work is
routed back to the right stage for the AI to fix. This is how "nothing ships without a person"
becomes structural.

## In scope
- Per-stage `approval_gate` flag and `send_rejects_to` (a target stage) on `Stage`.
- When a gated stage is configured, cards there expose approve/reject affordances (the actual
  approve/request-changes UX is MMF 15; this MMF is the config + routing rules).
- Reject moves the card to `send_rejects_to` and sets status appropriately (`working`/`queued`).

## Out of scope
- The in-drawer review action panel — MMF 15.

## Acceptance criteria
- [ ] A stage can be marked as an approval gate with a chosen reject-target stage.
- [ ] Rejecting a card on a gated stage moves it to the configured target.
- [ ] Approving advances the card to the next stage.

## Notes
- Routing lives in the `Cards`/`Boards` context so both UI (MMF 15) and API (MMF 09) reuse it.
