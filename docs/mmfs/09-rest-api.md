# MMF 09 — Relay REST API
**Milestone:** ⭐ MVP   **Depends on:** 06, 07, 08
**Design:** implied by API keys + agent worker (`Relay Board.dc.html`)   **Size:** ~1 loop

## Value
Relay becomes programmable. An external agent can read the board, work a card, and report
back — the technical prerequisite for Claude Code to hold the baton.

## In scope
- Token auth: `Authorization: Bearer <board key>` → resolves board; updates `last_used_at`;
  actions attributed to the Relay AI agent.
- JSON endpoints (scoped to the key's board):
  - `GET /api/board` — stages + cards + status/owner.
  - `GET /api/cards` / `GET /api/cards/:ref` — list/read (with description, comments, activity).
  - `PATCH /api/cards/:ref` — update title/description/tag/status.
  - `POST /api/cards/:ref/move` — set stage (+ position).
  - `POST /api/cards/:ref/comments` — add a comment (as agent).
  - `POST /api/cards/:ref/needs-input` — set `needs_input` with a question (feeds MMF 14).
- Consistent JSON errors; the `:api` pipeline (no CSRF/session).

## Out of scope
- The CLI wrapper — MMF 10. MCP — MMF 21. Webhooks/streaming — later.

## Acceptance criteria
- [ ] A valid board key authenticates; a missing/invalid/revoked key returns 401.
- [ ] `GET /api/board` returns stages and cards with status + owner for that board only.
- [ ] `PATCH`/`move`/`comments` persist and are reflected in the LiveView board.
- [ ] Agent-authored comments/moves show as the Relay AI agent in activity.

## Notes
- Reuse the same contexts as the LiveView UI (no logic fork). Keep endpoints thin over
  `Cards`/`Boards`. This is the contract MMF 10 wraps.
