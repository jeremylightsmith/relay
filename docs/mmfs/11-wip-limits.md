# MMF 11 — WIP limits
**Milestone:** Post-MVP   **Depends on:** 06
**Design:** stage WIP label, settings WIP input, "wip 4/3" over-limit (`Relay Board.dc.html`, Design System)   **Size:** ~1 loop

## Value
Keeps any one stage from piling up — a core kanban discipline that makes the human↔AI relay
sustainable rather than a dumping ground.

## In scope
- Per-stage optional WIP limit (toggle + numeric value) stored on `Stage`.
- Stage header shows `wip n/limit`; over-limit shows the rose "over WIP" treatment.
- Soft enforcement: moving a card into a full stage warns (and is flagged), configurable
  later to hard-block.

## Out of scope
- The stage-settings editor chrome — MMF 12 (this MMF adds the WIP field + board display).

## Acceptance criteria
- [ ] A stage with a limit shows `used/limit`; exceeding it renders the over-limit style.
- [ ] Toggling the limit off hides the counter and disables enforcement.
- [ ] Moving a card into an at-limit stage surfaces the over-WIP warning.

## Notes
- Counts exclude cards in a stage's Done sub-column if that concept lands (see MMF 12/13).
