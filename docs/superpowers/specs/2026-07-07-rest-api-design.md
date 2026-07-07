# MMF 09 — Relay REST API — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/09-rest-api.md`](../../mmfs/09-rest-api.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 06 (status/owners), 07 (timeline), 08 (keys)
**Development:** trunk-based on `main`

## Overview

Relay becomes programmable. An external agent reads the board, works a card, and reports back
over JSON — the contract MMF 10's CLI wraps. Endpoints are **thin over the existing contexts**
(`Cards`/`Boards`/`Activity`) so there is no logic fork between the API and the LiveView.

## Decisions

- **Bearer-token auth via an `ApiAuth` plug.** `Authorization: Bearer relay_<prefix>_<secret>`
  → `ApiKeys.authenticate/1` resolves the board (prefix lookup + constant-time hash compare),
  bumps `last_used_at`, and assigns `conn.assigns.current_board` + `actor: :agent`. Missing /
  malformed / invalid / revoked → **401 JSON**. Uses the existing `:api` pipeline (no
  session/CSRF).
- **Board scoping is implicit** — every endpoint operates on the authed key's board only; a
  `:ref` that doesn't resolve on that board → 404.
- **All writes are attributed to `:agent`** so comments/moves/owner changes render as "Relay
  AI" in the timeline (MMF 07).
- **New `RelayWeb.Api.*` controllers** under `scope "/api", RelayWeb.Api`, with a small JSON
  view layer and a consistent error shape `{"error": %{"code", "message"}}`.

## Endpoints (all scoped to the key's board)

| Method & path | Action |
|---|---|
| `GET /api/board` | Stages (incl. owner/category) + cards with status + owners |
| `GET /api/cards` | List cards (id, ref, title, stage, status, owners) |
| `GET /api/cards/:ref` | One card incl. description + timeline (comments + activity) |
| `PATCH /api/cards/:ref` | Update `title`/`description`/`tag`/**`status`**/**`owners`** |
| `POST /api/cards/:ref/move` | Set `stage` (+ optional `position`) → `Cards.move_card/3` |
| `POST /api/cards/:ref/comments` | Add a comment (as agent) → `Activity.add_comment/2` |
| `POST /api/cards/:ref/needs-input` | Set `status: needs_input` + post the question |

- **`owners`** on PATCH takes the desired owner set (e.g. `["agent"]` to claim, `["user:ID"]`
  to hand back) → `Cards.set_owners/2`. This is how the agent grabs and releases the baton.
- **`needs-input`** sets the status and records the question as an agent comment + activity —
  the minimal seam MMF 14 builds the interactive Q&A on.

## Behaviour

- Every mutating call reflects immediately in the LiveView board (same contexts + streams).
- Errors are JSON with appropriate status (400 validation, 401 auth, 404 unknown ref).

## Testing

- A valid board key authenticates; missing/invalid/revoked → 401.
- `GET /api/board` returns only the key's board, with cards' status + owners.
- `PATCH` (status/owners/title), `move`, and `comments` persist and appear in the LiveView.
- Setting `owners: ["agent"]` flips the card to AI-active; handing back to `user:ID` restores
  the human as active.
- Agent-authored comments/moves/owner changes render as "Relay AI" in the timeline.
- A `:ref` from another board → 404 (board scoping holds).

## Acceptance criteria (from the MMF)

- [ ] A valid board key authenticates; a missing/invalid/revoked key returns 401.
- [ ] `GET /api/board` returns stages and cards with status + owners for that board only.
- [ ] `PATCH`/`move`/`comments`/`needs-input` persist and reflect in the LiveView board.
- [ ] Agent-authored writes show as the Relay AI agent in the timeline.

## Out of scope

The CLI wrapper (MMF 10), MCP (MMF 21), webhooks/streaming, per-key scopes.
