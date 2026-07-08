# MMF 16 — AI result & sub-tasks in the drawer — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/16-ai-result-subtasks.md`](../../mmfs/16-ai-result-subtasks.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 04 (drawer), 09 (API), 18 (broadcasts — land first)
**Development:** trunk-based on `main`

## Overview

The AI gets a structured place to show its work: an **AI RESULT** block (summary paragraphs,
✓ check items, screenshot refs, an optional link) the agent writes over the API and the drawer
renders, plus a persistent **SUB-TASKS** checklist with a progress count that both the human
(click) and the agent (API) can tick off. A reviewer sees at a glance what was done — the
natural companion to MMF 15's review actions.

## Decisions

- **`Card.result` is structured jsonb** — one shape shared by API and UI, no rich-text
  editing. A map with all-optional keys, validated on write (unknown keys rejected):
  - `"summary"` — list of strings (paragraphs);
  - `"checks"` — list of strings (rendered as ✓ items);
  - `"images"` — list of `%{"url" => …, "caption" => …}` (refs only — no uploads);
  - `"link"` — `%{"url" => …, "label" => …}` (the mockup's "View deployment" footer).
  Written whole via `Cards.set_result(card, result, actor)` (`nil` clears); logs a
  `:result_updated` activity entry.
- **Sub-tasks are a table, not JSON:** new **`Schemas.Subtask`** (`subtasks`: `card_id` FK
  delete-cascade, `title` string, `done` boolean default false, `position` integer) — clean
  per-item toggling, ordering, and progress without whole-blob rewrites. Exported from
  `lib/schemas.ex`.
- **Context surface in `Relay.Cards`:** `list_subtasks(card)` (position order),
  `set_subtasks(card, titles, actor)` (replace the checklist — how the agent posts its plan;
  existing `done` state is not preserved across replaces), and
  `toggle_subtask(card, subtask_id, done, actor)`. Toggles log a `:subtask_toggled` activity
  entry (title + done in meta); replaces log `:subtasks_set`.
- **API extends the existing `RelayWeb.Api.CardController`/`card_json` over these functions**
  (no logic fork): `PATCH /api/cards/:ref` accepts `"result"`; `PUT /api/cards/:ref/subtasks`
  replaces the checklist (`{"subtasks": ["…", …]}`); `PATCH /api/cards/:ref/subtasks/:id`
  sets `{"done": true|false}`. `GET /api/cards/:ref` returns `result` + `subtasks`
  (id/title/done/position). Agent writes are `:agent`-attributed as everywhere else.
- Mutations broadcast (`{:card_upserted, …}` / `{:timeline_appended, …}`, MMF 18) so a
  reviewer watching the drawer sees results and ticks arrive live.

## Data model

- Migration 1: `add :result, :map, null: true` to `cards` (jsonb). Never cast in the general
  `Card.changeset/2` — only through `set_result`'s dedicated validation.
- Migration 2: `create table(:subtasks)` — `card_id` (references cards, `on_delete:
  :delete_all`, indexed), `title` (null: false), `done` (boolean, default false, null:
  false), `position` (integer, null: false), timestamps.

## Behaviour / UI (per `docs/designs/Relay Board.dc.html`, lines ~445–499)

- **AI RESULT block** (between DESCRIPTION and SUB-TASKS, only when `result` is set): header
  = the violet AI mark + mono 10px `AI RESULT` label (`oklch(0.48 0.13 292)`); a violet-tinted
  card (border `oklch(0.92 0.02 292)`, rounded-11) containing, each section only when its key
  is present:
  - summary paragraphs (13.5px, line-height 1.6);
  - check items — 15px rounded-4 green ✓ chips (`background: oklch(0.95 0.03 155)`) beside
    12.5px text;
  - an image row — thumbnails (~96px tall, rounded-8; the `url` as the image source) with
    11px captions, wrapping;
  - a footer link row — green dot + `View deployment · {label} ↗` style (`oklch(0.46 0.13
    250)`), opening `url` in a new tab (href sanitized to http/https).
- **SUB-TASKS checklist** (only when the card has subtasks): mono `SUB-TASKS` label + mono
  progress count `done/total` + a slim 4px progress bar (max-width 120px), then one row per
  item — full-row click target (rounded-8, `background: oklch(0.992 0.002 255)`) with a
  checkbox chip and the title struck/dimmed when done. Clicking toggles via
  `toggle_subtask` as the signed-in user; count and bar update immediately and persist.
- Result and subtask changes made via the API appear in an open drawer live (MMF 18); a
  toggle made in the UI is visible to the agent on its next `GET`.
- Cards without result/subtasks render neither section — the drawer is unchanged for them.

## Testing

- `set_result` round-trips each key; unknown keys or malformed shapes are rejected; `nil`
  clears; `:result_updated` is logged.
- The drawer renders each result section only when present (assert on section element IDs),
  and no AI RESULT block when `result` is nil.
- `PUT /subtasks` replaces the checklist in order; `GET /api/cards/:ref` returns result +
  subtasks; `PATCH /subtasks/:id` flips `done` (404 for another card's subtask id — board
  scoping holds through the card ref).
- Checklist renders with correct `done/total` progress; clicking an item toggles it, updates
  the count/bar, persists across reload, and logs `:subtask_toggled`.
- An API-written result appears in a concurrently open drawer without reload (MMF 18).
- `set_subtasks` with a fresh list replaces the old items (no orphans, positions 1..n).

## Acceptance criteria (from the MMF)

- [ ] A card can hold a structured AI-result block (paragraphs, checks, image refs, link)
      that renders in the drawer per the mockup.
- [ ] Sub-tasks render with a progress count; toggling one (UI or API) updates the count and
      persists.
- [ ] Results and sub-tasks are writable via the API (agent-attributed) so the agent
      populates them, and readable back via `GET /api/cards/:ref`.

## Out of scope

File/screenshot **uploads** and any attachment storage (images are URL refs only — full file
management later), rich-text/manual editing of results in the UI (render + API-write only),
adding/renaming individual subtasks from the UI (agent-authored via replace; UI is
toggle-only for now), surfacing subtask progress on the board card, review actions (MMF 15),
members (MMF 17), multi-board (MMF 19), landing (MMF 20), MCP (MMF 21).
