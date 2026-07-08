# RLY-10 — Change the name of a board — Design Spec

**Date:** 2026-07-08  **Card:** RLY-10 (dogfood — first card worked through the Relay board)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP (slice of MMF 19)
**Depends on:** MMF 12 (two-pane settings shell), 18 (broadcasts)
**Development:** trunk-based on `main`

> **Scope (from the human, via needs-input on RLY-10):** *"put it in board / settings, and just do
> the name for now."* → a **board-name** editor in `/board/settings`. Name only — the URL slug,
> danger zone, and inline header rename are out of scope (they're the rest of MMF 19).

## Overview

A board owner can rename their board from settings. Today `Schemas.Board` has a `name` (default
"My board") but nothing exposes editing it. This adds a **General** section to the settings
two-pane shell (MMF 12) with a single **Board name** field, and updates the board title live.

## Decisions

- **New "General" nav item + pane** in `RelayWeb.BoardSettingsLive`, added to the left rail
  above "Stages" (matching the mockup's Board Settings order: General → Stages → … → API keys,
  `docs/designs/Relay Board.dc.html` lines ~179–182). For now the General pane contains **only
  the Board name field** — the mockup's Board URL input and Danger zone are deferred (MMF 19).
- **Board name field:** an `<.input>` bound to a form; **save on submit** (a small "Save" button)
  — simpler/clearer than save-on-change for a single field, and avoids a rename per keystroke.
  Validation: required, trimmed, 1–80 chars.
- **`Relay.Boards.update_board/2`** casts `:name` (never `slug`/`key`/`owner_id`), returns
  `{:ok, board} | {:error, changeset}`, and **broadcasts** so an open board's title updates live.
  Reuse the MMF 18 seam: broadcast a `{:board_updated, board}` event on `"board:<id>"`;
  `BoardLive.handle_info/2` re-assigns `@board` (the `#board-title` reflects the new name). (If a
  dedicated event is overkill, `{:stages_changed, board_id}` already triggers a board reload —
  acceptable, but `:board_updated` is cleaner; pick one at plan time.)

## Data model

- No migration — `Schemas.Board.name` already exists.
- `Schemas.Board.changeset/2` casts `:name` with `validate_required` + `validate_length(max: 80)`
  (create path already sets defaults; this makes `name` user-editable).
- `Relay.Boards.update_board(board, attrs)` — casts `:name` only, persists, broadcasts.

## Behaviour / UI

- `/board/settings?section=general` (default the shell to General, or keep Stages default — plan
  time) renders the General pane: heading "General" + a **Board name** input + **Save**.
- Saving a valid name persists it and flashes success; a blank name shows a validation error.
- The board header (`#board-title` in `BoardLive`) shows the new name **immediately** in the
  acting session and, via the broadcast, in any other open session on that board (no reload).
- The existing Stages + API keys panes are unchanged; General is an added nav item + pane.

## Testing

- `Boards.update_board/2` persists a new name; rejects blank; never changes `slug`/`key`.
- Settings General pane: submitting a new name persists it; the settings + board reflect it.
- A blank name submit shows the validation error and does not change the name.
- Two-session (MMF 18): renaming in settings updates the `#board-title` on an open board in
  another session without reload.

## Acceptance criteria

- [ ] A board owner can edit the board **name** from a **General** pane in `/board/settings` and
      save it; it persists.
- [ ] The board title (`#board-title`) reflects the new name, live (acting + other open sessions).
- [ ] Blank/invalid names are rejected with a message; `slug`/`key` are never touched.

## Out of scope

Board **URL slug** editing, the **Danger zone** / archive, **inline rename** from the board
header, and **multiple boards** — all the rest of MMF 19; and any board-name history/audit
beyond the normal activity feed.
