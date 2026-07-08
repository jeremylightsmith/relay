# MMF 12c — Auto-collapse empty stages & lanes — Design Spec

**Date:** 2026-07-08  **MMF:** board-rendering enhancement (extends [10b](../../mmfs/10b-substages.md) / MMF 12)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 05 (move/DnD), 10b (sub-lanes), 12 (stage card) — build after 12; works live via 18
**Development:** trunk-based on `main`

> **Shared files:** touches the board render + `stage_column/1` in `lib/relay_web/components/core_components.ex`
> and `RelayWeb.BoardLive` — the same files MMF 12 restyles and MMF 11 adds the WIP badge to. Build
> after 12 so it layers on the restyled stage card. The fidelity pass deliberately deferred this
> ("empty sub-lanes show a placeholder instead of collapsing to a strip") — this closes that gap.

## Overview

A board with many stages gets wide fast. The mockup keeps it scannable by **auto-collapsing any
stage with no cards** into a thin vertical strip, and likewise **any empty sub-lane** — so a
board reads as "where the work actually is." Collapsed strips are still drop targets and expand
on demand.

## Decisions

- **Collapse is derived from card counts, not stored.** A stage collapses when it holds **zero
  cards across its main lane and all its sub-lanes** (mockup `collapsed = all.length === 0`,
  line ~1007); a sub-lane collapses when it is empty (mockup `laneCollapsed = isSub &&
  laneCards.length === 0`, line ~1020). Because it derives from the same counts MMF 18 keeps
  live, collapse/expand happens in real time as the last card leaves or the first card arrives —
  no extra realtime work.
- **Per-session "force open" override.** Clicking a collapsed strip expands that stage/lane for
  the current session (a `MapSet` of force-opened ids in the socket) even while empty — matching
  the mockup's `forceOpen`. Not persisted, not broadcast.
- **Collapsed strips are drop targets.** A collapsed stage/lane strip keeps its
  `data-stage-id` + drop handlers, so a card can be dragged straight onto it (it moves there and
  the stage/lane expands because it now has a card). This preserves the MMF 05 move contract.
- **Never collapse the last visible thing to nothing.** If *every* stage on the board is empty,
  they all render as strips (that's fine — the board is empty); there is always at least the
  strips to drop onto.

## Data model

None — no schema/migration. Pure rendering + a `:force_open` assign (`MapSet` of stage/lane ids)
in `BoardLive`.

## Behaviour / UI (mockup)

- **Empty stage → 44px dashed strip** (`docs/designs/Relay Board.dc.html` lines ~75–81):
  `width:44px; border:1px dashed oklch(0.90 0.006 255); border-radius:11px;
  background:oklch(0.965 0.004 255)`, vertically stacked: a **9px owner square swatch**
  (`ownerColor`), the **stage name rotated** (`writing-mode:vertical-rl; transform:rotate(180deg)`,
  12px semibold), and the **count** (mono 10px). `cursor:pointer`.
- **Empty sub-lane → 34px strip** (lines ~1028–1037): a **6px dot** in the lane's colour
  (`laneMeta.color`, review=amber / done=green) at 0.6 opacity, the **lane label rotated**
  vertically (mono 10px, lane colour), and the **count** (mono 10px). Sits inside the expanded
  parent stage, to the side of the main lane, with the same left divider as an expanded lane.
- **Expand:** clicking a strip force-opens it (renders the full 240px stage / 178px lane with its
  empty state) until the session ends; dragging a card onto a strip moves the card there and it
  expands naturally (now non-empty).
- **Live:** when the last card leaves a stage/lane (drag, move, API, or another session via
  MMF 18), it collapses to the strip; when a card arrives at a collapsed stage/lane, it expands —
  all without reload, since collapse is recomputed from the live counts.

## Testing

- A stage seeded with zero cards renders the collapsed strip (assert the strip element + rotated
  name + `0`); a stage with a card renders the full column.
- An empty Review/Done sub-lane renders its 34px strip; a sub-lane with a card renders expanded.
- Moving the last card out of a stage (drag/`move_card`) collapses it; moving a card into a
  collapsed stage (drop on the strip) expands it and the card renders there.
- Clicking a collapsed strip expands it (force-open) even while empty; it stays expanded.
- With MMF 18: emptying a stage in one session collapses it in another open session.
- A collapsed strip is a working drop target (`data-stage-id` present; a move event onto it
  succeeds).

## Acceptance criteria

- [ ] A stage with no cards (main + sub-lanes) auto-collapses to the mockup's dashed vertical
      strip; a non-empty stage renders full.
- [ ] An empty sub-lane auto-collapses to its 34px strip; a non-empty one renders expanded.
- [ ] Collapsed strips accept drops (a card dragged/moved onto one relocates there and expands).
- [ ] Clicking a strip force-expands it for the session; the change is not persisted.
- [ ] Collapse/expand tracks live count changes (including MMF 18 cross-session updates).

## Out of scope

Collapsing whole *category groups*; a persisted per-user "always expand this stage" preference;
animating the collapse (a CSS transition is fine but not required); collapsing non-empty stages.
