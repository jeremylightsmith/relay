# MMF 05 — Move cards between stages — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/05-move-cards.md`](../../mmfs/05-move-cards.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 03 (cards exist)  ·  **Development:** trunk-based on `main`

## Overview

Cards move. A user drags a card to another stage or reorders it within a stage, and the move
persists. This is the mechanical half of "passing the baton" — MMF 06 adds the ownership
meaning on top. No schema change: `Card` already carries `stage_id` + `position`.

## Decisions

- **Hand-rolled HTML5 drag-and-drop, no JS dependency.** Native `draggable=true` on each card,
  `dragstart`/`dragover`/`drop` on stage containers, wired through a small colocated/`phx-hook`
  that only reports the dropped card ref, the target stage id, and the drop index. **The server
  owns all state** — the hook never mutates the list; it pushes an event and the LiveView
  re-streams. `phx-update="stream"` on each per-stage container is preserved.
- **One move path, two entry points.** A drag and a drawer **"Move to…"** menu both call the
  same `Cards.move_card/3`, giving keyboard/a11y and future-API parity (MMF 09 reuses it).
- **Positions are re-indexed on the target stage** so ordering stays gap-free and deterministic.

## Data model

No migration. `Cards.move_card(card, target_stage, position)`:

- Sets `card.stage_id = target_stage.id` and inserts it at `position`, shifting the other
  cards in the target stage to keep `position` contiguous.
- Runs in a transaction; returns `{:ok, card}` or `{:error, changeset}`.
- Emits a stage-change side effect. In this MMF the emit is a no-op seam; **MMF 07** hooks
  `Activity.log/2` into it (created/moved timeline entries).

## Behaviour / UI

- Each card is draggable. Dropping it on another stage (or a new slot in its own stage) pushes a
  `"move_card"` event `%{"ref" => ref, "stage_id" => id, "index" => i}`.
- The LiveView resolves the card + target stage from **this board only** (reusing
  `get_card_by_ref/2` scoping), calls `move_card/3`, then `stream_insert`s the card into the
  target stage stream and `stream_delete`s it from the source (re-streams both).
- **Lane counts** update from a per-stage count assign (streams can't be counted) — decremented
  on the source, incremented on the target.
- Drawer **"Move to…"** lists the board's stages and moves on selection via the same event.

## Testing

- Dragging a card to another stage persists `stage_id` and it renders there after reload.
- Reordering within a stage persists `position` (order stable after reload).
- Stage lane counts reflect the card's new location.
- The drawer "Move to <stage>" path produces the same persisted result as a drag.
- A move event naming a card/stage not on the current board is rejected (no cross-board move).

## Acceptance criteria (from the MMF)

- [ ] Dragging a card to another stage persists and re-renders it there after reload.
- [ ] Reordering within a stage persists position.
- [ ] Lane counts reflect the card's new location.
- [ ] A non-drag "Move to <stage>" path produces the same result.

## Out of scope

WIP-limit enforcement (MMF 11), approval gates on move (MMF 13), cross-client live sync
(MMF 18), the owner/stage **mismatch** styling and owner changes on move (MMF 06), sub-lane
move targets (MMF 10b).
