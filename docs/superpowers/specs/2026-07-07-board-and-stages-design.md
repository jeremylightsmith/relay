# MMF 02 — Board with stages (seeded pipeline) — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/02-board-and-stages.md`](../../mmfs/02-board-and-stages.md)
**Status:** Draft for review → `/write-plan`
**Branch:** `mmf-02-04-board` (built together with MMF 03 + 04)
**Shared files (02–04):** `Relay.Boards`, `Relay.Cards`, `RelayWeb.BoardLive` (+ template),
`lib/relay_web/components/core_components.ex`, `router.ex`, `lib/relay.ex` (exports)
**Depends on:** MMF 01 (auth / `current_scope`)

## Overview

After signing in, the user lands on their board and sees the workflow as columns grouped by
category — the workspace exists and is legible before any cards. This MMF introduces the
`Boards` context, the `Board`/`Stage` schemas, default-board provisioning, and a read-only
board LiveView. It **replaces MMF 01's post-login stub** as the authenticated home (`/board`).

## Decisions

- **One board per user** for now; routed at `/board`. `slug` is stored but slug-routing is
  deferred to MMF 19.
- **`Board.key`** (short prefix, default `"RLY"`) is added here because card refs (MMF 03)
  need it; editing it is deferred to MMF 19.
- **Category band** renders as grouping headers spanning the stages in each category, ordered
  Unstarted → In progress → Complete.

## Data model

New context **`Relay.Boards`** (own `Boundary`, exported from `Relay`).

`Relay.Boards.Board`:
- `owner_id` → `Accounts.User` (required)
- `name` :string (default "My board")
- `slug` :string, unique
- `key` :string (default "RLY") — card-ref prefix
- timestamps

`Relay.Boards.Stage`:
- `board_id` (required)
- `name` :string (required)
- `position` :integer (order within the board)
- `category` :string enum `unstarted | in_progress | complete` (required)
- `owner` :string enum `human | ai` (required)
- timestamps

Indexes: unique `boards.slug`; `stages` unique on `(board_id, position)`.

## Provisioning & seed

- `Boards.get_or_create_default_board(user)` — returns the user's board, creating one (with a
  unique slug) + seeding stages on first call. Idempotent.
- Seeded pipeline (positions 1–7):
  1. Backlog · human · unstarted
  2. Spec · human · unstarted
  3. Plan · ai · in_progress
  4. Code · ai · in_progress
  5. Review · human · in_progress
  6. Deploy · ai · in_progress
  7. Done · human · complete

## UI — `RelayWeb.BoardLive`

- Route `/board` inside the `:require_authenticated` `live_session` (from MMF 01). MMF 01's
  post-login redirect now targets `/board`.
- `mount` → `get_or_create_default_board(current_scope.user)` → assign board + stages.
- Render: a **category band** (headers for each non-empty category in order) above **stage
  columns** in `position` order. Each column shows its name, an **owner pill** (Human=primary /
  AI=secondary) and an empty-state placeholder. Read-only.
- Uses the daisyUI theme tokens; a reusable `stage_column` + `owner_pill` component in
  `core_components` (consumed again by 03/04).

## Boundary

- `Relay.Boards` → `use Boundary, deps: [Relay.Repo, Relay.Accounts], exports: [Board, Stage]`.
- Add `Boards` to `Relay`'s `exports`.

## Testing

- `get_or_create_default_board/1`: creates one board + 7 stages with correct
  category/owner/position; second call returns the same board (no duplicates).
- `BoardLive`: renders 7 stages grouped under their category headers, in order, with the right
  owner pills; empty stages show the empty state.
- Auth gating inherited from MMF 01 (unauthenticated `/board` redirects to sign-in).

## Acceptance criteria (from the MMF)

- [ ] A new user automatically has one board with the seeded stages.
- [ ] The board renders stages in position order, grouped under their category band.
- [ ] Each stage shows its name and Human/AI owner pill.
- [ ] Stage colors/type follow the design tokens.

## Out of scope

Cards (MMF 03), drawer (04), moving cards (05), status/owner-on-cards (06), WIP (11), stage
editing (12), multiple boards + slug routing + archive (19).
