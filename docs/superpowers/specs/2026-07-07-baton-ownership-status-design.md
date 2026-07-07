# MMF 06 — The baton: card ownership + status — Design Spec

**Date:** 2026-07-07  **MMF:** [`docs/mmfs/06-baton-ownership-status.md`](../../mmfs/06-baton-ownership-status.md)
**Status:** Draft for review → `/write-plan`
**Depends on:** MMF 02, 03  ·  **Development:** trunk-based on `main`

## Overview

The heart of Relay: at a glance you see **who holds each card** (human vs AI) and **what state
it's in**. This MMF makes ownership a first-class, settable property of the *card* and adds a
status enum, then renders the design's colour system. It also carries a **foundational
refactor** (folded in here, no separate spec): a shared `Schemas` boundary that every later MMF
builds on.

## Model correction (supersedes the backlog's earlier framing)

The original backlog said *"ownership is stage-level — a card's owner is derived from its
stage's owner."* **That is replaced.** Ownership lives on the **card** and is a **settable list
of actors**. The stage's `owner` is retained but re-scoped to mean **"who this stage is meant
for."** A mismatch between the two is surfaced as a warning, never auto-corrected. `docs/mmfs`
(the MMF 06 file and the README "Modeling decisions") are updated to match.

## Decisions

- **"Actor" is one concept app-wide.** An actor is either a **user** (`user_id`) or the single
  **Relay AI agent** (`:agent`). The same idea drives card owners (here), comment/timeline
  authorship (MMF 07), and API attribution (MMF 09).
- **A card has many owners** (`card_owners` join). The AI is *just one possible owner* in the
  list, alongside human users. MVP boards have one human today (members arrive in MMF 17), so a
  card's owners are in practice a subset of `{that human, AI}` — but the model generalises.
- **Active owner is derived from the list, not stored:** if the agent is among the owners, **AI
  is active** (other, human owners render **paused/inactive**); otherwise the human(s) are
  active.
- **Nothing changes automatically.** Owners and status only change on an explicit action — a
  human in the UI or the AI agent via the API (MMF 09). Dragging a card (MMF 05) does **not**
  change its owners.
- **`Stage.owner` stays** as the "meant for" designation and is set once by the seeded pipeline.

## Foundational refactor: shared `Schemas` boundary (ADR 0002)

Mirrors throughway's ADR 0004. Adds `docs/adr/0002-module-boundaries-and-schemas-peer.md`.

- New top-level **`Schemas`** boundary in `lib/schemas.ex` (`use Boundary, deps: [], exports:
  [...]`) — a peer depended on by both the domain (`Relay.*` contexts) and the web layer.
- **Migrate the 5 existing schemas with no behaviour change:** `Relay.Boards.Board`,
  `Relay.Boards.Stage`, `Relay.Cards.Card`, `Relay.Accounts.User`, `Relay.Accounts.Scope` →
  `Schemas.Board`, `Schemas.Stage`, `Schemas.Card`, `Schemas.User`, `Schemas.Scope`. Contexts
  keep all business logic and add `Schemas` to their `deps` + `alias Schemas.Foo`.
- Update `lib/relay.ex` exports and every reference/alias/test accordingly; `mix precommit`
  (boundary check + full suite) must stay green through the move.
- All **new** schemas in this and later MMFs (`Comment`, `Activity`, `ApiKey`, the
  `card_owners` join schema) live in `Schemas.*` from the start.

## Data model

- **`Schemas.Card`** gains:
  - `status` — `Ecto.Enum`, values `queued | working | needs_input | in_review | done`,
    default `:queued`.
  - `progress` — nullable `:integer` (0–100; just stored/displayed, no automation source yet).
- **`card_owners`** join (`Schemas.CardOwner`): `card_id`, `actor_type` (`:user | :agent`),
  `user_id` (nullable, required iff `:user`). Unique on `(card_id, actor_type, user_id)`.
  `Cards` gets `set_owners/2` / `add_owner/2` / `remove_owner/2` and preloads owners.

## Behaviour / UI — the colour system

The active owner and the card's stage together decide the card's treatment:

- **AI active** → **violet** left border + AI owner pill; human owners shown paused.
- **Human active** → **blue** left border + human owner pill.
- **`needs_input`** status → **amber** "NEEDS INPUT" badge treatment.
- **Mismatch → red (both directions).** When the card's *active-owner type* ≠ the stage's
  `owner`: a human-active card in an AI stage shows red + *"this stage is meant to be used by
  agents"*; an AI-active card in a human stage shows red + *"this stage is meant for humans."*
  This is display only — it never mutates the card.
- **Status badge:** `working·<progress>%`, `in_review`, green `done`, queued (neutral).
- **Drawer properties rail:** ACTIVE WORKER + paused owner(s); a control to set **status** and
  to **add/remove owners** (including claiming/releasing AI). Persists via `Cards`.

## Testing

- A card renders its active-owner colour + pill and its status badge.
- Adding the agent as an owner flips the card to violet and shows the human owner as paused.
- A human-owned card placed in an AI stage renders the red "meant for agents" warning; an
  AI-owned card in a human stage renders the red "meant for humans" warning.
- A `needs_input` card shows the amber treatment on the board.
- Setting status / owners from the drawer persists and reflects on the board card.
- Boundary: after the `Schemas` migration, `mix compile` (boundary check) and the suite pass.

## Acceptance criteria (from the MMF)

- [ ] Each card shows its active owner (Human/AI) colour + pill and its status badge.
- [ ] A card whose owner type conflicts with its stage's owner shows the red mismatch warning
      (both directions).
- [ ] A `needs_input` card shows the amber "NEEDS INPUT" treatment on the board.
- [ ] The drawer rail shows active worker + paused owners and can set status/owners.
- [ ] Existing schemas are migrated to `Schemas.*` with the suite/boundary check green.

## Out of scope

The interactive needs-input Q&A (MMF 14), review-gate actions (MMF 15), progress-%
automation, auto-changing owners/status on move.
