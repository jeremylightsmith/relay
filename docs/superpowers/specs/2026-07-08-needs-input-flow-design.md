# MMF 14 — "Needs input" question ↔ answer — Design Spec

**Date:** 2026-07-08  **MMF:** [`docs/mmfs/14-needs-input-flow.md`](../../mmfs/14-needs-input-flow.md)
**Status:** Draft for review → `/write-plan`  ·  **Milestone:** Post-MVP
**Depends on:** MMF 06 (status), 07 (timeline), 09 (needs-input endpoint), 18 (broadcasts — land first)
**Development:** trunk-based on `main`

## Overview

The behaviour that makes Relay trustworthy: when the AI is unsure it **asks instead of
guessing**. The card blocks visibly amber, the human reads the question in the drawer and
answers inline ("Send to AI →"), and the card returns to the AI's queue — with the whole
exchange living permanently in the timeline.

## Decisions

- **The question lives in the timeline, not on the card.** No `Card.question` field. A
  first-class context function `Cards.request_input(card, question, actor \\ :agent)`
  (the existing `POST /api/cards/:ref/needs-input` controller path refactors onto it —
  same behaviour, one seam) does three things atomically: sets status `:needs_input`, sets
  `blocked_since`, and records the question as a comment from `actor` **plus** a
  `:needs_input` activity entry with `meta: %{"question" => …}` — the durable, queryable
  record the drawer reads.
- **New `Card.blocked_since`** — nullable `:utc_datetime`. Set on entering `:needs_input`,
  cleared on leaving it (managed inside `Cards.set_status`/`request_input`, whatever path the
  status change takes — UI, API, approve/reject). This is the fast "blocked, and for how
  long" query the design's aging treatment needs; the question itself stays in activity.
- **Answering = `Cards.answer_input(card, answer, actor)`**: posts the answer as a comment
  from `actor`, logs an `:input_answered` activity entry, sets status to **`:working`** when
  the card's stage is meant-for AI (the agent resumes) or **`:queued`** otherwise, and clears
  `blocked_since`. New `Schemas.Activity` types: `:needs_input`, `:input_answered`.
- **The agent consumes the answer via the existing API** — the answer comment appears in
  `GET /api/cards/:ref`'s timeline, and the status flip is visible on `GET /api/cards`. No new
  endpoint; actually acting on the answer is the external agent's job (CLI/Claude Code).
- All three transitions broadcast (`{:card_upserted, …}` + `{:timeline_appended, …}`, MMF 18)
  so the amber state appears/clears live everywhere.

## Data model

- Migration: `add :blocked_since, :utc_datetime, null: true` to `cards`. Never cast from
  user input — set programmatically alongside the status transition.
- `Schemas.Activity` enum gains `:needs_input` and `:input_answered`.

## Behaviour / UI (per `docs/designs/Relay Board.dc.html`)

- **Board card:** a `:needs_input` card keeps its existing amber accent and shows the mono
  10px amber `NEEDS INPUT` badge (mockup lines ~127–130, colour `oklch(0.52 0.11 65)`).
- **Drawer panel** (mockup lines ~398–405): when the selected card is `:needs_input`, an
  amber panel (`background: oklch(0.975 0.025 75)`, border `oklch(0.87 0.07 75)`, rounded-10)
  renders above the description with:
  - mono label **`RELAY AI NEEDS YOUR INPUT`**, plus a small "waiting Xh" aging hint derived
    from `blocked_since`;
  - the **latest question** — the newest `:needs_input` activity entry's `meta["question"]`;
  - a 3-row answer textarea, placeholder *"Type your answer — the AI picks up where it left
    off…"*;
  - the amber **"Send to AI →"** button (`background: oklch(0.70 0.13 65)`), submitting
    `answer_input` as the signed-in user.
- After answering: the panel disappears, the answer shows in COMMENTS, the activity entries
  show in ACTIVITY, the board card drops the badge and re-tints for its new status — in every
  open session (MMF 18).
- A card can be re-blocked with a new question any number of times; the panel always shows
  the latest question, and the full Q&A history stays readable in the timeline.
- Humans can also block a card by setting status `:needs_input` from the existing drawer
  status control — no question entry is created then; the panel renders with the composer but
  an empty question area (edge case, not styled specially).

## Testing

- `request_input/3` sets `:needs_input` + `blocked_since` and produces both the question
  comment and the `:needs_input` activity entry with the question in meta (the API endpoint
  exercises the same function).
- The board flags the card (amber badge element present); the drawer renders the panel with
  the latest question and composer.
- Submitting an answer: comment + `:input_answered` entry logged, status flips to `:working`
  on an AI-meant stage (and `:queued` on a human-meant one), `blocked_since` cleared, panel
  gone.
- Asking again after an answer shows the new question, not the old one.
- `GET /api/cards/:ref` returns the answer in the timeline and the updated status (the
  agent-side round-trip).
- Any path out of `:needs_input` (status control, approve/reject) clears `blocked_since`.

## Acceptance criteria (from the MMF)

- [ ] An agent (via the API) or user can put a card into `needs_input` with a question; the
      board flags it amber with the `NEEDS INPUT` badge.
- [ ] The drawer shows the latest question and an answer composer matching the mockup panel.
- [ ] Submitting an answer logs it (comment + activity), transitions the card out of
      `needs_input`, and clears `blocked_since`.
- [ ] The answer is retrievable via the API timeline so the agent can continue.

## Out of scope

Actually running an AI to consume the answer (external agent via CLI/API), notification/
escalation on aging blocks and any blocked-time analytics (only `blocked_since` storage +
the drawer hint land now), the review action panel (MMF 15), AI result rendering (MMF 16),
members (MMF 17), multi-board (MMF 19), landing (MMF 20), MCP (MMF 21).
