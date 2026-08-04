# Design mockups

High-fidelity mockups for Relay's core UI, pulled from the **Claude Design** project
[8062faff](https://claude.ai/design/p/8062faff-4bcd-4ddd-a160-25ec64cec793). These are the
visual source of truth — build the LiveView UI to match them, and re-pull if the design
project changes.

| File | What it is |
| --- | --- |
| `Relay Stage & Card Model.dc.html` | **The stage & card model — source of truth** (despite its "for discussion" badge). Five stage types (Queue · Work · Planning · Review · Done) alongside categories, AI-enabled stages, the ownership claim rule, the four card sub-states (ambient vs. needs-you), and the buttons-only-for-decisions doctrine. Read this before touching card/stage behavior. |
| `Relay Board.dc.html` | The core kanban/baton board — columns owned by human vs. AI, cards (working / blocked / done), WIP limits, handoffs, detail drawer. **This is the primary screen.** |
| `Relay Card Detail v5.dc.html` | **The card drawer, v5** — v2 chrome plus a terminal **Talk** session pane, the ask as a card-level task, Notes as a card field, presence in the header, a hoisted blocked strip, and the stage chip as the Move-to control. Ships its own numbered changelog of 23 changes stated against the capture at `@b312da1`. **Fidelity source for `CoreComponents.card_drawer/1`** (sliced into [RE268 AC0] → [RE286 AC10]). |
| `Relay Story Map.dc.html` | The **Story Map** — a second lens on the board: an Activities→Tasks backbone × Release swimlanes (MVP / Fast follow / Later) grid, real board cards in each cell, zoom (Map/Compact/Full), owner/needs filters + focus/hide-tasks, drag-to-assign, an **UNMAPPED** tray + "No task yet" column for unplaced cards, AI "Relay suggests", and live presence. **Fidelity source for the Story Map cards (RE265 → RE257).** |
| `Relay Landing.dc.html` | Marketing landing page — hero, "how it works", the flow, configurable stages. |
| `Relay Design System.dc.html` | The design system — typography, palette, actors/avatars, controls, board components, and an **implementation map to daisyUI/Tailwind primitives**. Read this first. |
| `Relay Flow Metrics.dc.html` | The per-flow Metrics tab — stat band (total runs, completed %, total spend, median end-to-end), per-node table (runs, duration, cost, attempts, verdict split, loop-laps), empty state, and the deep-link banner from a card's Run panel. **Fidelity source for `RelayWeb.FlowMetricsLive`.** |
| `Relay Mobile Brief.dc.html` | **Mobile platform brief** — what Relay is/isn't on a phone, the surfaces (Inbox/Board keep, Stream drop), the two primary actions, the hybrid native-shell architecture, and the ship plan. Read alongside [ADR 0005](../adr/0005-mobile-app-scope-and-architecture.md). |
| `Relay Mobile.dc.html` | **Mobile screen flow (for build)** — the tappable Inbox & Board prototype: login, core review loop, needs-input, board, settings, comments/screenshot viewer. Source for the mobile cards. |
| `Relay Docs.dc.html` | The public documentation site — top nav, sectioned left sidebar, "on this page" TOC, and the content styles (callouts, numbered steps, code blocks, tables). **Fidelity source for the `/docs` pages.** |
| `Relay API Reference.dc.html` | The REST API reference page styling — endpoint/method treatment and code samples. **Fidelity source for `/docs/api`.** |
| `support.js` | The Claude design-canvas runtime the `.dc.html` files load. |

## Design language (from the Design System file)

- **Actors are colors.** Human = blue `oklch(0.60 0.14 250)` (daisyUI `--color-primary`);
  AI = violet `oklch(0.56 0.16 292)` (`--color-secondary`). This is the core visual signal
  for *who holds the baton*.
- **Status:** Done = green `oklch(0.60 0.13 155)`, Blocked/"needs your input" = amber
  `oklch(0.70 0.13 65)`, Over-WIP = rose `oklch(0.62 0.16 15)`, Accent = teal.
- **Type:** Helvetica Neue for interface; **JetBrains Mono** for data/labels (WIP counts,
  tags, %, owner pills).
- **Stack target:** Phoenix LiveView + Tailwind 4 + daisyUI 5. The Design System file maps
  each element to a daisyUI primitive (`card` + `border-l-3`, `badge badge-soft`,
  `progress progress-secondary`, `drawer drawer-end`, `toggle`, `steps`, …). Set the palette
  above as the daisyUI theme in `assets/css/app.css`.

## Viewing

The `.dc.html` files are Claude design-canvas documents (they load `support.js`, which
expects the canvas React runtime). View them in the design project for the full interactive
render; opened directly in a browser they degrade to their static inline-styled HTML, which
is enough to read layout and color. They reference no external images.

## Re-pulling

Authorize with `/design-login`, then have Claude Code read the project by its ID above and
overwrite these files (see the design-sync capability). Keep the original filenames so the
mockups' cross-links keep working.

## The other direction — `docs/designs-as-is/`

Everything in *this* directory is **drawn first and built to**: the design leads, and
[`/slicing-mockups`](../../.claude/skills/slicing-mockups/SKILL.md) files the gaps where the
app drifted from it.

[`docs/designs-as-is/`](../designs-as-is/README.md) is the mirror image — `.dc.html` files
**generated from the running app** by `bin/design-capture.mjs`, so the design project can
iterate from what actually shipped rather than from memory. They are snapshots with no
authority: when one disagrees with the app, the *file* is stale.

Keep the two apart. A capture written into this directory would quietly promote itself to
visual source of truth. The loop is documented in
[`/design-capture`](../../.claude/skills/design-capture/SKILL.md).
