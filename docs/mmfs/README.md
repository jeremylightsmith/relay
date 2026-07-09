# Relay MMF Backlog

**MMF = Minimal Marketable Feature.** Each MMF is a vertical slice that delivers observable
value and is sized to run through **one** `/brainstorm` → `/write-plan` → `/exec-plan` →
`/finish` loop. They are extracted from the mockups in [`../designs/`](../designs/README.md).

## The backlog now lives in Relay

We hit the dogfood milestone: **Relay manages its own development inside Relay.** The live
backlog is the board itself (`relayboard.fly.dev`), driven by `bin/relay` — Claude Code pulls a
card, does the work, and hands it back. So the remaining MMFs have been **pulled in as cards**;
this folder is no longer the source of truth for open work.

### Shipped (MVP 01–10, then Post-MVP)

- **MVP (01–10):** Google login, board + seeded stages, create/title cards, card drawer, move
  cards, the human↔AI baton (ownership + status), comments/activity, board API keys, REST API,
  and the Relay CLI.
- **Post-MVP shipped:** substages (Review/Done sub-lanes), WIP limits, stage configuration,
  approval gates & reject routing, needs-input question↔answer, review gate actions, and
  real-time board sync.

### Open — tracked as cards on the board

- **Members & roles**, **Multiple boards & general settings** (incl. the new "Your boards"
  switcher in the board mockup), **Landing page**, and **AI result & sub-tasks in the drawer**
  (progress = sub-tasks done) are now Relay cards in the backlog.
- **[MMF 21 — MCP server](21-mcp-server.md)** remains here as an *optional* spec (an alternative
  to the CLI, which already works); pull it in as a card if/when wanted.

## Modeling decisions (durable — apply across features)

- **Ownership is per-card.** A card carries a settable **list of owner actors** (users and/or
  the single Relay AI agent — the AI is just one owner among many). The **active owner** is
  derived from that list (AI active if present, else humans; others show "paused"); nothing
  changes automatically. A **stage** keeps an `owner` too, but only as a **"meant for"**
  designation — when a card's active-owner type conflicts with its stage's owner the card shows
  a **red mismatch warning** (both directions), never an auto-correction.
- **Stages sit in categories** — Unstarted / Planning / In progress / Complete (à la Linear) —
  so a stage's *meaning* is unambiguous. Owner (Human/AI) is orthogonal to category.
- **MVP boards are single-owner.** One user owns a board; sharing/roles arrive with Members &
  roles. Org/workspace is deferred.
- **Claude Code talks to Relay via the CLI** (`bin/relay`) over the REST API, authed with a
  board API key. MCP (MMF 21) is an optional ergonomic alternative, not required.
- **Seeded default pipeline:** `Backlog` (Human) → `Spec` (Human) → `Plan` (AI) → `Code` (AI)
  → `Deploy` (AI) → `Done`, with per-stage Review/Done sub-lanes.

## MMF file template

```
# MMF NN — Title
**Milestone:** ⭐ MVP | Post-MVP        **Depends on:** NN
**Design:** ../designs/<file> (§section)   **Size:** ~1 loop

## Value           — who gets what, in one or two sentences
## In scope        — the slice
## Out of scope    — pushed to later MMFs (named)
## Acceptance criteria — behavioral, testable (feeds the TDD pipeline)
## Notes           — schema/architecture hints
```
