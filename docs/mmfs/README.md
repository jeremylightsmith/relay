# Relay MMF Backlog

**MMF = Minimal Marketable Feature.** Each MMF is a vertical slice that delivers observable
value and is sized to run through **one** `/brainstorm` → `/write-plan` → `/exec-plan` →
`/finish` loop. They are extracted from the mockups in [`../designs/`](../designs/README.md).

## The goal: dogfood MVP

Get Relay to the point where **we manage Relay's own development inside Relay** — these MMFs
become cards, and **Claude Code pulls a card, does the work, and hands it back**. That
milestone needs: Google login, a board with cards, the human↔AI baton, a REST API, and a CLI
Claude Code can drive. Everything after that is enhancement.

## Milestones

| # | MMF | Milestone | Depends on |
|---|-----|-----------|------------|
| [01](01-google-login.md) | Sign in with Google | ⭐ MVP | — |
| [02](02-board-and-stages.md) | Board with stages (seeded pipeline) | ⭐ MVP | 01 |
| [03](03-create-cards.md) | Create & title cards | ⭐ MVP | 02 |
| [04](04-card-drawer.md) | Card detail drawer | ⭐ MVP | 03 |
| [05](05-move-cards.md) | Move cards between stages | ⭐ MVP | 03 |
| [06](06-baton-ownership-status.md) | The baton: stage ownership + card status | ⭐ MVP | 02, 03 |
| [07](07-comments-activity.md) | Comments & activity log | ⭐ MVP | 04 |
| [08](08-board-api-keys.md) | Board API keys | ⭐ MVP | 02 |
| [09](09-rest-api.md) | Relay REST API | ⭐ MVP | 06, 07, 08 |
| [10](10-relay-cli.md) | Relay CLI for Claude Code | ⭐ MVP | 09 |
| [10b](10b-substages.md) | Stage substages (Review/Done sub-lanes) | Post-MVP | 05, 06 |
| [11](11-wip-limits.md) | WIP limits | Post-MVP | 06 |
| [12](12-stage-config.md) | Stage configuration UI | Post-MVP | 06 |
| [13](13-approval-gates.md) | Approval gates & reject routing | Post-MVP | 12 |
| [14](14-needs-input-flow.md) | "Needs input" question ↔ answer | Post-MVP | 06, 07 |
| [15](15-review-gate-actions.md) | Review gate actions | Post-MVP | 06, 13 |
| [16](16-ai-result-subtasks.md) | AI result & sub-tasks in the drawer | Post-MVP | 04 |
| [17](17-members-roles.md) | Members & roles | Post-MVP | 02 |
| [18](18-realtime-sync.md) | Real-time board sync | Post-MVP | 05 |
| [19](19-boards-and-settings.md) | Multiple boards & general settings | Post-MVP | 02 |
| [20](20-landing-page.md) | Landing page | Post-MVP | — |
| [21](21-mcp-server.md) | MCP server (alt to CLI) | Optional | 09 |

**The MVP cut is MMFs 01–10.** After 10, Relay can host its own backlog and Claude Code can
work it; 11+ are pulled in as cards from then on.

## Design refresh (2026-07-07)

Re-pulled the mockups from the Claude Design project and diffed against what's built + planned:

- **Board mockup evolved** (108→116 KB): stages now support optional **Review sub-lane** and
  **Done column** sub-lanes (per-stage toggles in settings; rendered as stacked `lanes` under a
  stage), plus a card **skip** action (`↷`). → **New [MMF 10b](10b-substages.md)** slotted before
  WIP limits; the Review-sub-lane toggle folded into [MMF 12](12-stage-config.md).
- **Design System + Landing mockups: unchanged** (same palette, actors, component→daisyUI map).
- **Built so far (MMF 01–03) still matches** the design at their scope; the drawer sections
  (MMF 04) are unchanged, so MMF 04 stands as specced.

## Modeling decisions (apply across MMFs)

- **Ownership is per-card.** A card carries a settable **list of owner actors** (users and/or
  the single Relay AI agent — the AI is just one owner among many). The **active owner** is
  derived from that list (AI active if present, else humans; others show "paused"); nothing
  changes automatically. A **stage** keeps an `owner` too, but only as a **"meant for"**
  designation — when a card's active-owner type conflicts with its stage's owner the card shows
  a **red mismatch warning** (both directions), never an auto-correction. This corrects an
  earlier "ownership is stage-level / derived" framing — see MMF 06's design spec.
- **Stages sit in three categories** — Unstarted / In progress / Complete (à la Linear) — so a
  stage's *meaning* is unambiguous. Owner (Human/AI) is orthogonal to category.
- **MVP boards are single-owner.** One user owns a board; sharing/roles arrive in MMF 17.
  Org/workspace is deferred.
- **Claude Code talks to Relay via the CLI (MMF 10)** over the REST API (MMF 09), authed with a
  board API key (MMF 08). MCP (MMF 21) is an optional ergonomic alternative, not required.
- **Seeded default pipeline** (MMF 02): `Backlog` (Human·Unstarted) → `Spec` (Human·Unstarted)
  → `Plan` (AI·In progress) → `Code` (AI·In progress) → `Review` (Human·In progress) →
  `Deploy` (AI·In progress) → `Done` (Complete).

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
