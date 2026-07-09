# Card branch + plan fields — Design Spec

**Date:** 2026-07-08  **Card:** (dogfood infra — fixes the runner's branch/plan collisions)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 09 (REST API), 18 (broadcasts), 04 (card drawer)
**Development:** trunk-based on `main`

## Overview

The autonomous board runner drives each card through stages that each touch the git repo. Today
a card carries no memory of *which branch* its work lives on, and the plan lives in a shared
repo-root `plan.md` — so parallel/interleaved cards **overwrite each other's branches and plan**.
This adds two fields **to the card itself** so the work travels with it: `branch` (which branch
this card's work belongs to — so each flow step can `git checkout` it first) and `plan` (the
implementation plan, rendered collapsed in the card drawer). Both must be **read + writable via
the REST API** (the runner is an API client).

> **Consumer (separate follow-up, not this spec):** `relay_config.json` / `bin/relay` will read a
> card's `branch` and `git checkout` it before each stage's steps, and the Plan stage will write
> the plan to the card's `plan` field instead of a shared `plan.md`. This spec ships the fields +
> API + drawer they depend on.

## Decisions

- **Two new nullable `Schemas.Card` fields:** `branch :string` and `plan :text`. One migration.
- **Read + write via the API.** `PATCH /api/cards/:ref` accepts `branch` and `plan` (alongside
  the existing title/description/tag/status/owners); `GET /api/cards/:ref` and `GET /api/board`
  include `branch` and `plan` in the card JSON. Set through `Relay.Cards.update_card/2` (cast the
  two new fields — they are agent/user-set, like description). Every write broadcasts
  `{:card_upserted, card}` (MMF 18) so open boards update live.
- **Drawer: `plan` renders in a collapsible section, collapsed by default** (daisyUI `collapse`
  with a "Plan" title; the plan body is plain preformatted text, whitespace preserved — plans are
  long, so it must not dominate the drawer). Empty `plan` → the section does not render.
- **Drawer: `branch` renders as a small git-branch chip** in the properties rail (mono, with a
  branch icon) when set; nothing when unset. Read-only in the UI (the runner writes it via API).
- These are structural/agent fields, not free-form user content beyond what the API sets — no
  extra validation beyond types (branch is a short string, plan is text).

## Data model

- Migration: `add :branch, :string` + `add :plan, :text` (both null: true) to `cards`.
- `Schemas.Card.changeset/2` casts `:branch` and `:plan` (in addition to `:title/:description/:tag`).
- No new context functions — `Relay.Cards.update_card/2` already routes through the changeset;
  it now persists `branch`/`plan` and broadcasts.

## Behaviour / UI

- `PATCH /api/cards/:ref {"branch": "rly-14-...", "plan": "..."}` persists both; a follow-up
  `GET` returns them; the change reflects live on an open board/drawer (MMF 18).
- Card drawer: a **collapsed** "Plan" `collapse` section shows the plan when present (click to
  expand); the properties rail shows a **branch chip** when `branch` is set.
- The board card is unchanged (branch/plan are drawer-level detail, not board-card chrome).

## Testing

- `Cards.update_card/2` persists `branch` and `plan`; they survive a reload; never touch
  programmatic fields (board_id/stage_id/position/ref_number).
- `PATCH /api/cards/:ref` with `branch`/`plan` persists and appears in `GET /api/cards/:ref` and
  `GET /api/board` card JSON.
- Drawer: a card with a `plan` renders the collapsed "Plan" section (assert the `collapse`
  element + that it's collapsed by default); a card with a `branch` renders the branch chip; a
  card with neither renders neither.
- A PATCH to `branch`/`plan` updates an open drawer/board in another session (MMF 18).

## Acceptance criteria

- [ ] `Card` has `branch` + `plan`; both are settable and readable via `PATCH`/`GET` on the API.
- [ ] The card drawer shows `plan` in a section that is **collapsed by default** (expandable).
- [ ] The drawer shows the `branch` when set; nothing when unset.
- [ ] Writes broadcast so open boards reflect them live; programmatic fields stay protected.

## Out of scope

The runner/`relay_config.json` changes that *use* `branch` (checkout-per-step) and write `plan`
to the card (the consuming follow-up); board-card rendering of branch/plan; git-worktree
isolation (a later option); editing branch/plan from the drawer UI (API-set only for now).
