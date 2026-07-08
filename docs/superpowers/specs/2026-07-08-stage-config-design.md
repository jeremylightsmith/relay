# MMF 12 — Stage configuration UI — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/12-stage-config.md`](../../mmfs/12-stage-config.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 06, 08 (`/board/settings`), 10b (lane toggles), 18 (broadcasts — land first)
**Development:** trunk-based on `main`

> **Shared files:** MMFs 11, 12, and 13 all touch `Schemas.Stage`, `Relay.Boards`, and the
> same stage settings card in `RelayWeb.BoardSettingsLive` — plan them coherently. This MMF
> owns the settings shell + stage card chrome; 11 adds the WIP row, 13 the gate controls.

> **Related board-render behaviour:** empty stages (and empty sub-lanes) **auto-collapse** to the
> mockup's dashed vertical strip — specced separately in
> `2026-07-08-collapse-empty-columns-design.md` (build after this MMF; it layers on the stage
> card/column restyled here).

## Overview

`/board/settings` grows from MMF 08's simple API-key page into the mockup's two-pane Board
Settings, whose Stages section lets a team reshape the pipeline: rename, describe, reorder,
add, delete stages, set each stage's meant-for owner, and flip the existing (10b) Review/Done
sub-lane toggles — all live on the board.

## Decisions

- **Two-pane shell per the mockup** (`docs/designs/Relay Board.dc.html` lines ~173–360): a
  210px left rail headed `BOARD` (mono 10px) with nav buttons, and a scrollable content pane,
  `max-width: 760px`. Nav renders **Stages** and **API keys** only — the mockup's *General*
  and *Members* items arrive with MMFs 19 and 17. The existing MMF 08 API-key pane moves
  under "API keys" **unchanged** (it deliberately does not match the mockup's keys design;
  restyling it is not this MMF).
- **Ownership reconciliation:** `Stage.owner` is the **meant-for** designation only. Changing
  it re-tints the column, flips the settings swatch/segmented control, and changes which cards
  show the red mismatch treatment — it **never mutates any card's owner list**
  (`card_owners` is per-card, MMF 06). The backlog AC "changing a stage's owner updates its
  cards' owner" is stale and corrected below.
- **Reorder = ↑/↓ arrow buttons** (primary, matching the mockup's 26px `↑` `↓` buttons, lines
  ~234–235). A stage moving past a category boundary **adopts that category** — the mockup's
  own copy: "cross into another category and it takes on that meaning" (line ~218).
  Drag-and-drop reordering is out of scope unless it falls out nearly free.
- **New `Stage.description`** (nullable text) — the mockup's per-stage description input;
  shown in settings now (board-side display can come later).
- **Guard rails in `Relay.Boards`:** deleting a stage that holds cards (in its main lane *or*
  its sub-lanes) is blocked with an explanatory error — no silent card loss, no force-move UI
  yet; a board keeps **≥ 1 main stage**; sub-lane children are never directly deletable
  (only via the 10b toggles, which already guard non-empty lanes).
- **Context surface** (all in `Relay.Boards`, reused by 11/13's fields):
  `update_stage(stage, attrs)` (name, description, owner — plus 11's `wip_limit`, 13's gate
  fields), `reorder_stage(stage, :up | :down)`, `create_stage(board, category)` (default name
  "New stage", owner `:human`, appended within the category), `delete_stage(stage)`
  (→ `{:error, :not_empty | :last_stage}` when guarded). Every change broadcasts
  `{:stages_changed, board_id}` (MMF 18).

## Data model

- Migration: `add :description, :text, null: true` to `stages`; cast in `Stage.changeset/2`.
- Reordering rewrites `position` across the board's main stages (sub-lane children keep
  trailing positions as today); category adoption updates `category` in the same transaction.

## Behaviour / UI (Stages section, mockup lines ~215–278)

- Heading "Stages" + the mockup's explanatory paragraph; stages grouped under **category
  headers** (dot + mono uppercase label + count — the same idiom as the board).
- Each main stage renders as a **white rounded-13 card** containing, per the mockup:
  - Row 1: 9px square **owner swatch** (blue/violet), borderless editable **name input**
    (15px semibold), then `↑` / `↓` **move buttons** and a rose-tinted `×` **delete** button.
  - A **description input**, placeholder "Describe what happens in this stage…".
  - A controls row: `OWNER` mono label + **Human / AI segmented** buttons; MMF 11's `WIP`
    toggle + stepper; `DONE COLUMN` toggle (drives 10b `enable_lane/disable_lane(:done)`).
  - Below a **dashed divider**: `REVIEW SUB-LANE` toggle (10b `:review`) with, when on, the
    mockup's explanation ("Finished work waits in Review for a human to approve…").
- Under each group: the dashed full-width **"+ Add stage to {category}"** button.
- Edits persist on change (no save button) and reflect on the board immediately — rename,
  owner tint, order, and new/removed columns — in the acting session and, via MMF 18, every
  other open session.
- Deleting a non-empty stage, disabling a non-empty sub-lane, or deleting the last stage
  shows an inline error/flash naming why.

## Testing

- Settings renders the two-pane shell with Stages + API keys nav; the API-key pane's existing
  element IDs still work under the "API keys" nav item.
- Rename / description edits persist and the new name shows on the board.
- `↑`/`↓` swap stage order on the board; moving a stage past a category boundary changes its
  `category` (assert the stage renders under the new category band).
- Changing owner Human↔AI re-tints the column and flips mismatch flags on its cards, and
  **does not change any card's owner list** (assert `card_owners` rows untouched).
- "+ Add stage" creates a renamable stage in that category; delete removes an empty stage.
- Deleting a stage with cards (main or sub-lane) errors and deletes nothing; deleting the
  only remaining stage errors.
- Review/Done toggles create/remove child lanes (existing 10b behaviour, now driven from the
  restyled card).

## Acceptance criteria (corrected from the MMF)

- [ ] Add/rename/describe/reorder/delete/move-category persist and reflect on the board.
- [ ] Changing a stage's owner changes the meant-for designation and mismatch warnings only —
      it never mutates card owners. *(Corrects the stale backlog criterion, which assumed the
      pre-MMF-06 derived-owner model.)*
- [ ] Deleting a non-empty stage is blocked with an explanatory error; a board keeps ≥1 stage.
- [ ] The settings page matches the mockup's two-pane shell, with the MMF 08 API-key pane
      under "API keys" unchanged.

## Out of scope

Drag-and-drop stage reordering (optional later enhancement — only if it falls out of the
arrow-button work nearly free), force-moving cards on delete, the General pane (MMF 19),
Members pane (MMF 17), restyling the API-keys pane to the mockup, WIP field semantics
(MMF 11), approval-gate controls (MMF 13), landing page (MMF 20), MCP (MMF 21).
