# MMF 15 — Review gate actions — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/15-review-gate-actions.md`](../../mmfs/15-review-gate-actions.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 04 (drawer), 06 (owners), **13 (gate routing — must land first)**, 18 (broadcasts)
**Development:** trunk-based on `main`

## Overview

The human side of the hand-off: a card sitting in `:in_review` gets an action panel in the
drawer — **Approve** it forward, **Request changes** back with a note, **Mark done**, or
**Pull** it to claim the baton. Every button drives the same context transitions MMF 13
built and the API exposes, so the UI is affordance only, never a second code path.

## Decisions

- **Panel trigger = card status `:in_review`.** Stage-agnostic: whether the card sits in a
  review sub-lane (10b) or anywhere else, `:in_review` is the signal a human's judgement is
  wanted (the mockup keys its panel off the review lane; status is our equivalent since
  status is first-class and lane-independent).
- **Four actions, all thin over existing context functions:**
  - **Approve** → `Cards.approve(card, {:user, id})` (MMF 13): next main stage, status by the
    target's meant-for owner. When the card's stage isn't a gate, the Approve button is not
    rendered — approval is a gate concept (MMF 13 returns `{:error, :not_gated}` otherwise).
  - **Request changes** → `Cards.reject(card, note, {:user, id})` (MMF 13): routes to the
    reject target with the note attached. Same gate-only visibility as Approve.
  - **Mark done** → `Cards.set_status(card, %{status: :done}, {:user, id})` — always
    available in the panel (gated or not).
  - **Pull** → `Cards.add_owner(card, {:user, id}, {:user, id})` — the signed-in human claims
    the card (takes the baton per the MMF 06 owner model). Hidden when they already own it.
- **Activity & realtime for free:** each function already logs (`:approved`, `:rejected`,
  `:status_changed`, `:owners_changed`) and broadcasts (MMF 18). This MMF adds handlers +
  markup in `BoardLive` / `card_drawer` only — no new context or API surface (the API already
  exposes approve/reject via MMF 13 and status/owners via MMF 09).

## Data model

None. No migrations; no new schema fields.

## Behaviour / UI (per `docs/designs/Relay Board.dc.html`, lines ~408–437)

- The drawer's action slot (above DESCRIPTION, where the working/blocked panels live) renders
  the green review panel for an `:in_review` card: `background: oklch(0.975 0.02 155)`,
  border `oklch(0.88 0.05 155)`, rounded-10, with:
  - mono 10px label **`READY FOR YOUR REVIEW`** (`oklch(0.46 0.10 155)`) and a one-line hint;
  - a two-button row (gated stages): solid green **Approve** (`background:
    oklch(0.60 0.13 155)`, label may name the destination, e.g. "Approve → Deploy") and
    outlined white **Request changes**.
- **Request changes expands in place** (mockup lines ~419–428) into a white sub-panel:
  "Sending back to **{target}** for the AI to address." (target = MMF 13's resolved reject
  destination), a textarea placeholder *"What needs to change? This note goes to the AI…"*,
  an amber **"Send back →"** button (`oklch(0.70 0.13 65)`) and a Cancel link. The note is
  required — Send back with an empty note is a no-op with an inline prompt.
- Below the panel, per the mockup's standalone buttons (lines ~432–437): a green **Mark
  done** button and a blue **Pull** button (`oklch(0.60 0.14 250)`) labelled to claim the
  card (e.g. "Pull — take this card").
- After any action the drawer stays open on the card: stage chip, status, owner cluster, and
  timeline refresh; the board columns re-stream (approve/reject reuse the existing move
  application; all sessions update via MMF 18).
- On a non-gated `:in_review` card the panel renders with hint + Mark done + Pull only.

## Testing

- A card set to `:in_review` shows the review panel in the drawer; other statuses don't.
- On a gated stage: Approve moves the card to the next main stage with the right status, logs
  `:approved`, and the board reflects the move; on a non-gated stage the Approve /
  Request-changes buttons are absent.
- Request changes: expanding shows the resolved target's name; submitting with a note moves
  the card to the reject target, attaches the note as a comment, logs `:rejected`; an empty
  note submits nothing.
- Mark done sets status `:done` (green treatment on the board) and logs the status change.
- Pull adds the signed-in user to the card's owners (avatar joins the cluster; mismatch flag
  updates per meant-for rules) and logs `:owners_changed`; the button hides once they own it.
- All four actions are attributed to the signed-in user in the timeline, and a second open
  session sees each result live (MMF 18).

## Acceptance criteria (from the MMF)

- [ ] A card in `in_review` shows the review panel; approve / request-changes appear on gated
      stages, mark-done / pull always.
- [ ] Approve advances per the gate config; request-changes routes back per the gate config
      with the note attached to the timeline.
- [ ] Mark done sets `done`; Pull adds the signed-in user as an owner; each action is logged
      in activity with the acting user.
- [ ] All actions reuse MMF 13/06/09's context transitions — no UI-only logic fork.

## Out of scope

Gate configuration (MMF 13 — a hard dependency of this MMF), AI result rendering in the same
drawer (MMF 16), reviewer assignment/permissions (MMF 17 members), batch review, keyboard
shortcuts, multi-board (MMF 19), landing (MMF 20), MCP (MMF 21).
