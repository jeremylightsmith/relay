# MMF 07 — Comments & activity (single timeline) — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/07-comments-activity.md`](../../mmfs/07-comments-activity.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 04 (drawer), 05 (move emits), 06 (status/owner emits + `Schemas`)
**Development:** trunk-based on `main`

## Overview

A card becomes a conversation and a record. Humans and the AI post comments, and every
meaningful change is logged — and the two are shown as **one interleaved timeline** in the
drawer (comments + events chronologically together, GitHub-style), not two separate panes.

## Decisions

- **New `Relay.Activity` context** (its own boundary, added to `lib/relay.ex` exports) owns
  both schemas. Keeps comment/log concerns out of `Cards`/`Boards`.
- **Single interleaved timeline.** The drawer renders comments and activity entries merged and
  ordered by `inserted_at`, with a comment composer. (Supersedes the mockup's separate
  COMMENTS / ACTIVITY sections — confirmed in brainstorm.)
- **Author = actor** (the MMF 06 concept): `:user` + `user_id`, or `:agent` (renders as "Relay
  AI"). So an API-posted comment (MMF 09) renders with the Relay AI identity.
- **Domain emits activity, not the web layer.** `Cards.move_card/3` and the status/owner
  setters call `Activity.log/2`, so both the LiveView and the API produce identical log
  entries. `Cards` gains a boundary dep on `Relay.Activity` (no cycle — Activity never calls
  Cards).

## Data model (both in `Schemas.*`)

- **`Schemas.Comment`** — `card_id`, `actor_type` (`:user | :agent`), `user_id` (nullable),
  `body` :text, timestamps.
- **`Schemas.Activity`** — `card_id`, `type` `Ecto.Enum`
  (`created | moved | status_changed | owners_changed | commented`), `meta` :map (jsonb; e.g.
  `%{from_stage, to_stage}`, `%{from_status, to_status}`), `actor_type`, `user_id` (nullable),
  timestamps.

`Relay.Activity` API: `add_comment/2`, `log/2` (type + meta + actor), `list_timeline/1`
(comments + activity for a card, merged, chronological, actor preloaded).

## Behaviour / UI

- Drawer shows the **timeline**: each entry renders author (initials/name or "Relay AI"),
  timestamp, and either the comment body or a system phrase ("moved Spec → Code", "set status
  to in_review", "added AI as owner").
- Composer posts a comment (`add_comment/2`), which appends to the timeline live.
- Card **create** (MMF 03), **move** (MMF 05), and **status/owner change** (MMF 06) each append
  an activity entry automatically via `Activity.log/2`.

## Testing

- Posting a comment persists it and shows it in the timeline with author + timestamp.
- Moving a card and changing its status/owners each append an activity entry automatically.
- Comments and activity interleave in chronological order in one list.
- A comment authored by the agent renders with the "Relay AI" identity.

## Acceptance criteria (from the MMF)

- [ ] Posting a comment persists it and shows it with author + timestamp.
- [ ] Moving a card or changing its status/owners appends an activity entry automatically.
- [ ] Timeline entries (comments + activity) render merged in chronological order.
- [ ] A comment authored by the agent renders with the Relay AI identity.

## Out of scope

Rich AI result blocks / sub-tasks (MMF 16), @-mentions/notifications, comment edit/delete.
