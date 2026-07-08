# MMF 12d — Category model: add Planning + fix cross-category reorder — Design Spec

**Date:** 2026-07-08  **MMF:** board model fix/enhancement (extends [12](2026-07-08-stage-config-design.md))
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 12 (stage config / reorder), 18 (broadcasts)  ·  build **before** 11/13
**Development:** trunk-based on `main`

> **Shared files:** `Schemas.Stage` (category enum), `Relay.Boards` (`@category_order`, `reorder_stage`,
> seed), `RelayWeb.BoardLive` (`@category_order`, `category_label`, category dot), `RelayWeb.BoardSettingsLive`
> (category grouping). MMFs 11/13 add fields to the same stage settings card — land this first so
> they build on the corrected category model.

## Overview

Two coupled changes to the stage-category model: (1) **fix a reorder bug** — moving a stage across a
category boundary currently swaps categories *bidirectionally*, dragging the neighbour into the wrong
category; it should be a **one-directional** move into the adjacent category. (2) **add a new
`:planning` category** between `unstarted` and `in_progress`.

## The bug (reproduce first)

`Relay.Boards.reorder_stage/2` → `swap_stages/2` swaps **position and category** between the moved
stage and its board-order neighbour ("a true exchange"). At a category edge the neighbour is in a
*different* category, so the swap moves the neighbour into the moved stage's old category. Concretely:
moving the **last `unstarted` stage down**, the neighbour is the **first `in_progress` stage** — the
swap makes the moved stage `in_progress` (correct) **but also makes the neighbour `unstarted`**
(wrong — it "comes up" into Unstarted). Same defect symmetrically on move-up across a boundary.

## Decisions

- **Reorder is category-order-aware and one-directional across boundaries.**
  `@category_order = [:unstarted, :planning, :in_progress, :complete]`.
  - **Same-category neighbour** in the move direction → **swap positions** only (unchanged behaviour;
    keep category).
  - **No same-category neighbour** (the stage is first/last in its category) → **move to the adjacent
    category in `@category_order`** (the *immediately* next/previous category, even if empty), adopting
    it and landing at that category's **edge**: moving **down** → the **top** of the next category;
    moving **up** → the **bottom** of the previous category. **The neighbour's category never changes.**
  - No adjacent category (already in the first category moving up, or last moving down) → no-op.
  - Implement by rebuilding the board's main-stage order and re-numbering `position` 1..n in one
    transaction (park-then-assign to respect the `stages_board_id_position_index` unique index), setting
    only the moved stage's `category`. This uniformly handles empty categories (incl. a fresh empty
    Planning) and multi-step crossings.
- **New `:planning` category** added to the `Schemas.Stage` `category` `Ecto.Enum`
  (`[:unstarted, :planning, :in_progress, :complete]`). No migration — `category` is a string enum.
- **Category chrome:** add the "Planning" label and a category **dot colour** wherever the other three
  are defined (board category band, settings category header). Pick a violet-leaning planning hue
  distinct from the others (planning is where AI planning tends to live) — cite/mirror the existing
  category dot styling; if the mockup defines a planning colour use it, else a sensible token.
- **Board shows non-empty categories only** (existing `group_stages` behaviour — an empty Planning band
  does not appear on the board); **settings shows all four categories always** (so a user can add a
  stage to Planning), each with its "+ Add stage to PLANNING" button.
- **Seed:** move the seeded default pipeline's **`Plan`** stage from `:in_progress` into the new
  `:planning` category (it is literally the planning stage), so a new board demonstrates the category;
  the rest of the seed is unchanged. *(Flag for review — if undesired, add the category without
  touching the seed.)* Existing boards are unaffected (no data migration).

## Data model

- `Schemas.Stage.category` enum gains `:planning` (order: unstarted, planning, in_progress, complete).
  No DB migration.
- `Relay.Boards.reorder_stage/2` rewritten per the decision above (replaces the bidirectional
  `swap_stages` at category boundaries; same-category still swaps). `@category_order` updated in
  `Relay.Boards` **and** `RelayWeb.BoardLive` (and any category list in settings).

## Behaviour / UI

- Moving the last `unstarted` stage **down** makes it the **top of Planning** (or, once Planning has
  stages, moves within Unstarted first); the previous first-Planning/in_progress stage **stays put**.
- Moving a stage **down** into an **empty Planning** lands it in Planning (not skipped into In progress).
- Moving a stage **up** from the top of In progress lands it at the **bottom of Planning**.
- The board renders a **Planning** category band (dot + "PLANNING" + count) when it has stages; the
  settings Stages pane always shows the Planning group with its add-stage button.
- All reorders broadcast `{:stages_changed, board_id}` (MMF 18) so open boards re-render live.
- Owner/`card_owners` are never touched by a reorder (unchanged from MMF 12).

## Testing

- **Bug repro:** with the seeded board, `reorder_stage(last_unstarted, :down)` → the stage's category
  becomes the next category and it is that category's first stage; **assert the previous first stage of
  that category is unchanged** (category + relative order). Symmetric move-up test.
- Moving a stage down into an **empty Planning** puts it in `:planning` (not `:in_progress`).
- Same-category reorder still swaps positions (no category change).
- No-op at the board's first/last category edge.
- Reorder leaves every card's `card_owners` untouched; positions stay contiguous + unique.
- `:planning` renders: a board with a planning stage shows the PLANNING band; settings shows all four
  category groups; the Planning dot/label render.
- A new board's seed places `Plan` in `:planning` (if the seed decision holds).

## Acceptance criteria

- [ ] Moving a stage across a category boundary moves **only that stage** into the adjacent category at
      the correct edge; the neighbour's category is unchanged. *(Fixes the reported bug.)*
- [ ] Reorder into an **empty** category (e.g. a fresh Planning) works (no skipping).
- [ ] `:planning` exists between `:unstarted` and `:in_progress`; the board (when non-empty) and the
      settings pane render it with a label + dot.
- [ ] Same-category reorder still swaps positions; owners/`card_owners` untouched; positions stay valid.

## Out of scope

Arbitrary user-defined categories (the set stays the fixed four), per-category colour customization,
drag-reorder (still ↑/↓ per MMF 12), moving stages between boards.
