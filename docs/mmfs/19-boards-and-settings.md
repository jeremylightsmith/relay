# MMF 19 — Multiple boards & general settings
**Milestone:** Post-MVP   **Depends on:** 02
**Design:** top-bar board title, BOARD SETTINGS §GENERAL (name / URL / Danger zone) (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Users run more than one workflow — create boards, name them, give them a URL, switch between
them, and archive the ones they're done with.

## In scope
- Create additional boards (each seeds its own pipeline per MMF 02) + a board switcher in the
  top bar.
- Settings → General: edit board name and URL slug (`relay.app/<slug>`, unique); Danger zone:
  archive board.
- Route boards by slug; archived boards are hidden from the switcher and read-only.

## Out of scope
- Templates/duplication — later. Cross-board search — later.

## Acceptance criteria
- [ ] A user can create, name, and switch between multiple boards.
- [ ] Editing the slug changes the board URL and enforces uniqueness.
- [ ] Archiving removes a board from the active switcher and makes it read-only.

## Notes
- Slug uniqueness is global (or per-owner) — decide at spec time; keep it simple.
