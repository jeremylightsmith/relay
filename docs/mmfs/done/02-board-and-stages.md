# MMF 02 — Board with stages (seeded pipeline)
**Milestone:** ⭐ MVP   **Depends on:** 01
**Design:** BOARD section, category band + stages (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
After signing in, a user lands on their board and sees the workflow as columns grouped by
category — the workspace exists and is legible even before any cards.

## In scope
- `Board` schema (owner = user, name, url slug) + auto-create one default board per user.
- `Stage` schema (board_id, name, position, category enum `unstarted|in_progress|complete`,
  owner enum `human|ai`).
- Seed the default pipeline on board creation: Backlog·Human, Spec·Human (Unstarted); Plan·AI,
  Code·AI, Review·Human, Deploy·AI (In progress); Done (Complete).
- LiveView board page: category band across the top; stage columns in order, each showing name,
  owner pill, and an empty state. Read-only render.

## Out of scope
- Creating/rendering cards — MMF 03. Editing stages — MMF 12. Multiple boards — MMF 19.

## Acceptance criteria
- [ ] A new user automatically has one board with the seeded stages.
- [ ] The board renders stages in position order, grouped under their category band.
- [ ] Each stage shows its name and Human/AI owner pill.
- [ ] Stage colors/type follow the design tokens (see `../designs`).

## Notes
- Add a `Boards` context (own `Boundary`). Stage colors map to daisyUI theme tokens.
