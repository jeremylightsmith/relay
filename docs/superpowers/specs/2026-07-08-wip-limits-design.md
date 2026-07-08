# MMF 11 — WIP limits — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/11-wip-limits.md`](../../mmfs/11-wip-limits.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 06 (status), 10b (sub-lanes), 18 (broadcasts — land first)
**Development:** trunk-based on `main`

> **Shared files:** MMFs 11, 12, and 13 all touch `Schemas.Stage`, `Relay.Boards`, and the
> same stage settings card in `RelayWeb.BoardSettingsLive` — plan them coherently. This MMF
> owns the `wip_limit` field + board display; the settings card shell it renders into is
> MMF 12's.
>
> **Related:** empty stages auto-collapse to a strip that shows only the count
> (`2026-07-08-collapse-empty-columns-design.md`) — a collapsed (empty) stage is never over-WIP,
> so the over-limit treatment only applies to expanded stages.

## Overview

A stage can carry an optional WIP limit. The stage header shows `wip used/limit`, going rose
when over; moving a card into a full stage is allowed but visibly warned — soft enforcement
that keeps the human↔AI relay from silting up without ever blocking the baton.

## Decisions

- **`Stage.wip_limit`** — nullable positive integer on `Schemas.Stage`. `nil` = no limit
  (counter hidden, no enforcement). Only meaningful on `lane: :main` stages.
- **The count is the stage's main-lane (ongoing) cards only.** Review/Done sub-lane cards sit
  in their own child `Stage` rows (MMF 10b), so a main stage's own card count *is* its WIP
  count — matching the mockup, which counts `cardsBy.ongoing` for `wipLabel`
  (`docs/designs/Relay Board.dc.html` line ~1008). This supersedes the backlog note "if that
  concept lands": it has landed, and the exclusion is structural.
- **Soft enforcement.** `Cards.move_card/4` never rejects a move for WIP; the UI (and API
  response, unchanged) succeed, and the board surfaces the over-limit state. A hard-block
  toggle is a later enhancement, not built now.
- **Settings control = the mockup's WIP row** (rendered inside MMF 12's stage settings card):
  a mono `WIP` label, an On/Off toggle button, and — when on — a `− / value / +` stepper
  (mockup lines ~248–257). Enabling defaults the limit to **3**, stepping floors at **1**
  (mockup `onToggleLimit` / `bumpWip`). Persisted via `Relay.Boards.update_stage/2` (MMF 12).
- Changing/removing a limit broadcasts `{:stages_changed, board_id}` (MMF 18) so open boards
  re-render counters live.

## Data model

- Migration: `add :wip_limit, :integer, null: true` to `stages`.
- `Schemas.Stage.changeset/2` casts `wip_limit`, validating `greater_than: 0` when present.
- No new context functions of its own — reads use the existing per-stage counts; writes go
  through MMF 12's `Boards.update_stage/2`.

## Behaviour / UI

- **Stage header** (`stage_column` in `BoardLive`): when `wip_limit` is set, render the
  mockup's WIP chip after the count — mono 11px, `wip {used}/{limit}` (mockup lines ~88–89,
  ~1061). Within limit: neutral chip (`background: oklch(0.96 0.006 255)`, text
  `oklch(0.48 0.02 255)`); over limit: the rose over-WIP treatment (`background:
  oklch(0.96 0.03 15)`, text `oklch(0.55 0.16 15)`) — mockup line ~1010. No chip when
  `wip_limit` is `nil`.
- **Over-WIP warning on move:** dropping (or drawer-moving, or API-moving) a card into a stage
  already at its limit completes the move, flips the header chip to the rose treatment, and
  the acting web session gets a non-blocking warning flash ("Code is over its WIP limit —
  4/3"). The API move response is unchanged (soft = no contract change).
- Counters stay correct on create/move/broadcast because they derive from the existing
  `stage_counts` assign, which already recomputes on those paths.
- Sub-lane (Review/Done) columns never render a WIP chip.

## Testing

- A stage with `wip_limit: 3` and 2 main-lane cards renders `wip 2/3` in the neutral style;
  a 4th card renders `wip 4/3` in the rose style (assert on the chip element + style class).
- Cards in the stage's Review/Done sub-lanes do not count toward `used`.
- A stage with `wip_limit: nil` renders no WIP chip.
- Moving a card into an at-limit stage succeeds (card renders in the target stage) and the
  acting session receives the warning flash.
- Toggling the limit off in settings hides the chip on the board (via the `stages_changed`
  broadcast); toggling on defaults to 3; the stepper cannot go below 1.
- `wip_limit` persists through `Boards.update_stage/2` and rejects zero/negative values.

## Acceptance criteria (from the MMF)

- [ ] A stage with a limit shows `wip used/limit`; exceeding it renders the rose over-limit
      style. `used` counts main-lane cards only (sub-lane cards excluded).
- [ ] Toggling the limit off hides the counter and disables enforcement.
- [ ] Moving a card into an at-limit stage completes (soft) and surfaces the over-WIP warning.
- [ ] Limit changes reflect live on open boards (MMF 18 broadcast).

## Out of scope

Hard-block enforcement (a later per-stage toggle), per-sub-lane WIP limits, WIP on Review/Done
lanes, the settings card chrome itself (MMF 12), gate config (MMF 13), members (MMF 17),
multi-board/general settings (MMF 19).
