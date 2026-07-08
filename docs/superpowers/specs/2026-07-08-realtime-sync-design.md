# MMF 18 — Real-time board sync — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/18-realtime-sync.md`](../../mmfs/18-realtime-sync.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 05 (move), 07 (timeline), 09 (API writes)
**Development:** trunk-based on `main`

> **Sequencing note:** land this MMF **first** among the 2026-07-08 batch. Once the contexts
> broadcast, MMFs 11–16 get live propagation for free — their mutations all flow through the
> same context functions, so no per-feature realtime work is needed.

## Overview

The board becomes alive: when anyone — another browser session, or the agent via the REST API
(MMF 09) — moves a card, changes status/owners, posts a comment, or edits stage config, every
open `RelayWeb.BoardLive` for that board applies the change instantly, no reload. One
notification seam in the domain layer serves both the LiveView and API entry points.

## Decisions

- **A broadcast seam in the domain: `Relay.Events`** — a small sub-boundary (declared in
  `lib/relay.ex`, exported from `Relay`) over **Phoenix.PubSub** (`Relay.PubSub`, already in
  the supervision tree). Two functions: `subscribe(board_id)` and `broadcast(board_id, event)`.
- **Board-scoped topic** `"board:<board_id>"`. Everything a session needs arrives on its own
  board's topic; nothing else does (no cross-board leakage).
- **Semantic events, broadcast from the CONTEXTS** (`Relay.Cards`, `Relay.Boards`,
  `Relay.Activity`) after each successful mutation — never from controllers or LiveViews — so
  the LiveView and the REST API share one notification path:
  - `{:card_upserted, card}` — create, title/description/tag edit, status, owners (card with
    owners preloaded).
  - `{:card_moved, card, from_stage_id}` — cross- or within-stage move.
  - `{:timeline_appended, card_id, entry}` — a new comment or activity entry.
  - `{:stages_changed, board_id}` — any stage/config change (lanes today; MMF 11/12/13 config
    later) — coarse on purpose: receivers refetch stages.
  - (A `{:card_deleted, card}` event joins this vocabulary if/when card deletion ships — no
    delete path exists today.)
- **Everyone applies broadcasts, including the acting session.** The actor's own
  `handle_event` already updates its socket; the echoed broadcast is applied idempotently
  (streams upsert by DOM id; counts/stages are recomputed from the DB, not incremented), so
  double-apply is harmless and there is no "skip self" bookkeeping.
- **Idempotent application in `BoardLive.handle_info/2`**, reusing the existing helpers:
  `card_upserted` → `stream_insert` into the card's stage stream + recompute counts;
  `card_moved` → the existing `apply_move`-style restream of source + target stages;
  `timeline_appended` → `stream_insert(:timeline, entry)` only when the drawer has that card
  open; `stages_changed` → reload the board's stages and re-derive
  `stage_groups`/`sublanes_by_parent`/streams. If the open drawer's card is affected, its
  assigns (`selected_card`, status form, owners) refresh too.

## Data model

No schema or migration changes. New module `lib/relay/events.ex` (`Relay.Events`, its own
`use Boundary` sub-boundary added to `Relay`'s exports); `Relay.Cards` / `Relay.Boards` /
`Relay.Activity` add it to their boundary deps.

## Behaviour / UI

- `BoardLive.mount/3` calls `Relay.Events.subscribe(board.id)` when `connected?(socket)`.
- A card created/edited/moved/status-changed in session A appears in session B without reload,
  with the correct accent colour, status label, owner cluster, and lane counts — the live
  "working" feel the mockup's pulsing indicators promise (`docs/designs/Relay Board.dc.html`,
  the `relaypulse` working dot).
- The same happens when the mutation arrives via `PATCH /api/cards/:ref`, `POST .../move`,
  `POST .../comments`, or `POST .../needs-input` — agent actions show up live because the
  broadcasts fire in the contexts those controllers call.
- A comment posted while another user has the same card's drawer open appends to that open
  timeline stream.
- Broadcast failures never fail the mutation (fire-and-forget after commit).

## Testing

- Two mounted LiveViews on the same board: a card created/moved/status-changed in one renders
  in the other (assert with `has_element?` on the card's DOM id in the target stage stream).
- An API-driven move/comment/status change (`Phoenix.ConnTest` request) updates an open
  LiveView on that board.
- A comment broadcast appends to the timeline only in a session with that card's drawer open.
- A mutation on board A produces no change in a mounted LiveView on board B (scoping holds).
- Context-level: each mutating function in `Cards`/`Boards`/`Activity` broadcasts the expected
  event to a subscribed test process (`assert_receive`).
- Applying the same event twice leaves the DOM unchanged (idempotence).

## Acceptance criteria (from the MMF)

- [ ] A change in one session appears in another open session on the same board without reload.
- [ ] A move/comment/status change made via the API updates open boards live.
- [ ] Broadcasts are board-scoped (no cross-board leakage).
- [ ] Broadcasts originate in the contexts, so every future context mutation (MMFs 11–16) is
      live by construction.

## Out of scope

Presence/avatars of who's viewing (later), optimistic conflict resolution (later), cursor or
typing indicators, multi-board routing (MMF 19), members seeing each other (MMF 17), MCP
(MMF 21).
