# MMF 03 — Create & title cards — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/03-create-cards.md`](../../mmfs/03-create-cards.md)
**Status:** Draft for review → `/write-plan`
**Branch:** `mmf-02-04-board` (with MMF 02 + 04)
**Shared files (02–04):** see MMF 02 spec
**Depends on:** MMF 02

## Overview

Let users add work to the board: a stage's compose control creates a card in that stage, and
cards persist and render in position order. Introduces the `Cards` context + `Card` schema and
per-board card refs.

## Decisions

- **Card ref = `<board.key>-<n>`** (e.g. `RLY-12`), where `n` is a **per-board sequence**
  starting at 1.
- **Ref allocation is serialized** to avoid duplicates under concurrency: allocate inside a
  transaction that locks the board row (`SELECT … FOR UPDATE`) and reads/bumps a
  `Board.card_seq` counter. (A Postgres sequence per board is the alternative; the counter
  column keeps refs gap-free and simple.)
- New cards are appended to the **bottom** of their stage.

## Data model

New context **`Relay.Cards`** (own `Boundary`).

`Relay.Cards.Card`:
- `board_id`, `stage_id` (required)
- `title` :string (required)
- `position` :integer (order within stage)
- `tag` :string (nullable)
- `ref_number` :integer (per board; assigned on create)
- timestamps

`Relay.Boards.Board` gains `card_seq` :integer (default 0) for ref allocation.

Derived: `Card.ref/1` → `"#{board.key}-#{ref_number}"`.

## Behaviour / UI

- Each stage column gets a **compose control** (`+`/"New card"): clicking reveals an inline
  title input; submitting calls `Cards.create_card(stage, %{title: …})` and clears the input;
  Cancel/blur closes it.
- `create_card/2`: allocates the next ref (serialized), sets `position` = end of stage, inserts.
- Cards render as a **card component** (title, `#tag` if present, ref) in `position` order; the
  stage empty-state shows only when the stage has no cards.

## Boundary

- `Relay.Cards` → `use Boundary, deps: [Relay.Repo, Relay.Boards], exports: [Card]`.
- Add `Cards` to `Relay`'s `exports`.

## Testing

- `create_card/2`: assigns sequential per-board refs (`RLY-1`, `RLY-2`, …); independent
  sequences across two boards; appends at the stage's end.
- Concurrency: two near-simultaneous creates on one board get distinct, gap-free refs.
- `BoardLive`: composing a card adds it to the correct stage and clears the input; it persists
  and re-renders in order on reload.

## Acceptance criteria (from the MMF)

- [ ] Using a stage's compose CTA creates a card in that stage and clears the input.
- [ ] Cards persist and re-render in position order on reload.
- [ ] Each card shows its title and ref; an empty stage shows its empty state.
- [ ] Creating a card assigns a per-board incrementing ref (e.g. `RLY-12`).

## Out of scope

Description/detail drawer (MMF 04), moving between stages (05), status/owner badges (06),
sub-tasks/comments (07/16).
