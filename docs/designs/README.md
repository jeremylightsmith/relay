# Design mockups

High-fidelity mockups for Relay's core UI, pulled from the **Claude Design** project
[8062faff](https://claude.ai/design/p/8062faff-4bcd-4ddd-a160-25ec64cec793). These are the
visual source of truth — build the LiveView UI to match them, and re-pull if the design
project changes.

| File | What it is |
| --- | --- |
| `Relay Stage & Card Model.dc.html` | **The stage & card model — source of truth** (despite its "for discussion" badge). Five stage types (Queue · Work · Planning · Review · Done) alongside categories, AI-enabled stages, the ownership claim rule, the four card sub-states (ambient vs. needs-you), and the buttons-only-for-decisions doctrine. Read this before touching card/stage behavior. |
| `Relay Board.dc.html` | The core kanban/baton board — columns owned by human vs. AI, cards (working / blocked / done), WIP limits, handoffs, detail drawer. **This is the primary screen.** |
| `Relay Landing.dc.html` | Marketing landing page — hero, "how it works", the flow, configurable stages. |
| `Relay Design System.dc.html` | The design system — typography, palette, actors/avatars, controls, board components, and an **implementation map to daisyUI/Tailwind primitives**. Read this first. |
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
