# MMF 13 — Approval gates & reject routing — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/13-approval-gates.md`](../../mmfs/13-approval-gates.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 10b (review lanes), 12 (stage settings card), 18 (broadcasts — land first)
**Development:** trunk-based on `main`

> **Shared files:** MMFs 11, 12, and 13 all touch `Schemas.Stage`, `Relay.Boards`, and the
> same stage settings card in `RelayWeb.BoardSettingsLive` — plan them coherently. This MMF
> is **config + routing rules only**; the human-facing approve/reject UX is MMF 15, which
> depends on this landing first.

## Overview

A stage can act as a checkpoint: work there must be explicitly approved to advance, and
rejected work routes back to a configured stage with a note for the AI to address. This makes
"nothing ships without a person" structural — the routing lives in the contexts so the drawer
(MMF 15) and the REST API drive the exact same transitions.

## Decisions

- **Two new `Schemas.Stage` fields:** `approval_gate` (boolean, default `false`) and
  `reject_to_stage_id` (nullable FK to a **main-lane stage on the same board**).
- **Default reject target = the gated stage's own main lane.** The mockup ships no explicit
  `APPROVAL GATE` / `SEND REJECTS TO` controls (grep of `docs/designs/Relay Board.dc.html`
  confirms neither string appears); its review-lane copy fixes the default semantics —
  "Rejected work returns to this stage's In progress lane" (line ~270) — and its
  `requestChanges` handler moves the card back to the stage's ongoing lane (line ~874).
  `reject_to_stage_id = nil` on a gated stage means exactly that; setting it overrides where
  rejects land.
- **Settings controls follow the mockup's toggle-row idiom** (since no literal gate controls
  exist to copy): inside MMF 12's stage settings card, below the REVIEW SUB-LANE row, an
  `APPROVAL GATE` mono label + toggle, and — when on — a `SEND REJECTS TO` select listing the
  board's main stages, defaulting to "This stage" (`nil`). Styled like the card's other
  mono-label + control rows (lines ~240–272).
- **Routing lives in `Relay.Cards`** (board/stage resolution via `Relay.Boards`), reused by
  MMF 15's drawer and the API:
  - `Cards.approve(card, actor)` — allowed when the card's stage (or its parent, for a card
    sitting in a review sub-lane) is a gate. Moves the card to the **next main stage by
    position** (sub-lane children are never "next"; from a review sub-lane, next = the first
    main stage after the parent). Arrival status: `:working` if the target is meant-for AI,
    `:queued` if meant-for human — mirroring the mockup's approve flow (line ~863). At the
    last main stage, approve sets status `:done` in place.
  - `Cards.reject(card, note, actor)` — moves the card to the resolved reject target
    (`reject_to_stage_id` or the gate's main lane), sets status the same way
    (`:working` AI-meant / `:queued` human-meant), and attaches `note` as a comment from
    `actor` plus the rejection activity entry.
  - Both return `{:error, :not_gated}` when the stage isn't a gate.
- **New activity types** `:approved` and `:rejected` on `Schemas.Activity` (meta snapshots
  from/to stage display names, and the note for rejects), logged by the functions above.
- Config changes broadcast `{:stages_changed, …}`; approve/reject broadcast the existing
  `{:card_moved, …}` / `{:timeline_appended, …}` events (MMF 18).

## Data model

- Migration on `stages`: `add :approval_gate, :boolean, default: false, null: false` and
  `add :reject_to_stage_id, references(:stages, on_delete: :nilify_all)`.
- `Stage.changeset/2` casts both; validation (context-level, where the board is known):
  the target must be a main-lane stage on the same board. Deleting the target stage
  (MMF 12) nilifies the FK — the gate falls back to its default.

## Behaviour / UI

- Settings: toggling `APPROVAL GATE` on/off and picking `SEND REJECTS TO` persist via
  `Boards.update_stage/2` (MMF 12) and reflect live.
- Enabling a review sub-lane (10b) does **not** implicitly set the gate; the two compose —
  the common pattern is a review lane + gate on the same stage, but each is independent.
- API (extends the existing `RelayWeb.Api.CardController` over the same context functions —
  no logic fork): `POST /api/cards/:ref/approve` and `POST /api/cards/:ref/reject`
  (body: `{"note": "..."}`, required for reject). Errors: 404 unknown ref, 422 when
  `{:error, :not_gated}` or the note is missing. `GET /api/board` stage payloads gain
  `approval_gate` + `reject_to_stage_id`.
- This MMF ships no drawer buttons — a gated card's approve/reject affordances are MMF 15.
  Until then the routing is exercisable via API and tests only.

## Testing

- A stage can be marked as a gate with a chosen reject target; persisting and re-listing
  stages round-trips both fields; a cross-board or sub-lane target is rejected.
- `approve/2` on a gated stage's card (main lane and review sub-lane cases) moves it to the
  next main stage with the right status (`:working` for an AI-meant target, `:queued` for
  human-meant); at the last main stage it sets `:done` in place.
- `reject/3` moves the card to the configured target; with `reject_to_stage_id: nil` it lands
  in the gate's own main lane; the note appears in the timeline as a comment and the
  `:rejected` activity entry is logged with from/to meta.
- `approve`/`reject` on a non-gated stage returns `{:error, :not_gated}` (API: 422).
- API approve/reject round-trip: agent-attributed, reflected on an open LiveView (MMF 18).
- Deleting the reject-target stage nilifies the FK and rejects fall back to the default.

## Acceptance criteria (from the MMF)

- [ ] A stage can be marked as an approval gate with a chosen reject-target stage (default:
      its own main lane, per the mockup's review-lane copy).
- [ ] Rejecting a card on a gated stage moves it to the configured target, sets
      `:working`/`:queued` by the target's meant-for owner, and attaches the note.
- [ ] Approving advances the card to the next main stage (sub-lanes skipped).
- [ ] Both transitions are context functions exposed identically to the UI (MMF 15) and API.

## Out of scope

The in-drawer review action panel — approve/request-changes/mark-done/pull buttons — is
**MMF 15** (which depends on this MMF). Also out: hard "cards cannot leave a gate except via
approve" move-blocking (moves stay free; the gate is the affordance, not a lock), gate
analytics, members/permissions on who may approve (MMF 17), multi-board (MMF 19), MCP (MMF 21).
