# MMF 04 — Card detail drawer
**Milestone:** ⭐ MVP   **Depends on:** 03
**Design:** Scrim + Drawer, header / DESCRIPTION / PROPERTIES RAIL (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Clicking a card opens a detail drawer where a person can read and edit the full card — the
place a spec lives. This is where humans and AI put the substance of the work.

## In scope
- Right-side drawer (daisyUI `drawer drawer-end`) with scrim; opens on card click, closes on ✕/scrim.
- Header: stage chip, card ref, editable title.
- `DESCRIPTION`: rich-enough text (markdown or plain multiline) — view + edit + save.
- Properties rail: current STAGE, TAGS, DATES (created/updated).
- Deep-link: opening a card reflects in the URL (`?card=REF`) so it's shareable.

## Out of scope
- Comments/activity — MMF 07. AI result & sub-tasks — MMF 16. Owner/status panels — MMF 06/14/15.

## Acceptance criteria
- [ ] Clicking a card opens the drawer for that card; ✕ or scrim closes it.
- [ ] Editing and saving the title/description persists and reflects on the board card.
- [ ] The rail shows stage, tags, and created/updated dates.
- [ ] Visiting the deep-link URL opens the drawer directly.

## Notes
- Keep description storage simple (text/markdown); a rich editor can come later.
