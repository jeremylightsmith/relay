# MMF 04 — Card detail drawer — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/04-card-drawer.md`](../../mmfs/04-card-drawer.md)
**Status:** Draft for review → `/write-plan`
**Branch:** `mmf-02-04-board` (with MMF 02 + 03)
**Shared files (02–04):** see MMF 02 spec
**Depends on:** MMF 03

## Overview

Clicking a card opens a right-side detail drawer where a person reads and edits the full card —
the place a spec lives. This MMF adds the drawer to `BoardLive`, an editable title +
description, a properties rail, and a deep-linkable URL.

## Decisions

- **Drawer lives in `BoardLive`** (daisyUI `drawer drawer-end` + scrim), driven by a
  `?card=<ref>` URL param via `handle_params` — deep-linkable and shareable, not a separate
  route.
- **Description is plain multiline text** (whitespace preserved on display, `textarea` to
  edit). Markdown/rich editing and AI-result blocks are deferred to MMF 16.
- Title edits inline in the drawer header; changes reflect on the board card immediately.

## Data model

`Relay.Cards.Card` gains `description` :text (nullable).

## Behaviour / UI

- Clicking a card sets `?card=<ref>`; `handle_params` loads the card into `@selected_card` and
  opens the drawer. `✕` or scrim click clears the param and closes it.
- **Header:** stage chip (current stage name + owner color), card ref, **editable title**.
- **Description:** view (whitespace-preserved) + edit (`textarea`) + save via
  `Cards.update_card/2`.
- **Properties rail:** current STAGE, TAGS (the `tag`), DATES (created/updated).
- Editing title/description persists and updates the board card without a full reload.
- Visiting `/board?card=<ref>` directly opens the drawer for that card; an unknown/foreign ref
  is ignored (no drawer).

## Testing

- Clicking a card opens the drawer showing its title, ref, stage, tag, dates.
- Editing + saving the title and description persists (`Cards.update_card/2`) and reflects on
  the board card.
- `/board?card=<ref>` deep-link opens the drawer; `✕`/scrim closes it and clears the param.
- A card ref from another user's board does not open (authorization via the current board).

## Acceptance criteria (from the MMF)

- [ ] Clicking a card opens the drawer for that card; ✕ or scrim closes it.
- [ ] Editing and saving the title/description persists and reflects on the board card.
- [ ] The rail shows stage, tags, and created/updated dates.
- [ ] Visiting the deep-link URL opens the drawer directly.

## Out of scope

Comments/activity (MMF 07), AI result & sub-tasks (16), owner/status action panels
(06/14/15), rich-text/markdown editing.
