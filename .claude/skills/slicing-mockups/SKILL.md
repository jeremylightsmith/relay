---
name: slicing-mockups
description: Use when the user says one or more mockups (artboards) were updated and wants the live app reconciled to them — walking the app to find where it drifted from the design and filing the gaps as Backlog cards. Keywords: mockup, artboard, design drift, docs/designs, redesign, Claude Design, reconcile.
---

# Slicing Mockups

## Overview
Turn updated mockups into a reviewed list of app-vs-design differences, then file the
approved ones as Backlog intake cards. Core principle: **detect and file only** — never
design or implement here (that is `/brainstorm` → `/write-plan` → `/exec-plan`), and never
card a difference the human has not confirmed is the *app's* bug (mockups drift from the
shipped app just as often as the app drifts from them).

## When to Use
The user reports one or more updated mockups and wants the app brought back in line.
**Not** for: designing a fix, editing UI, or touching mockups not named as changed.

## Inputs
The name(s) of the changed artboard(s). If not given, ask which — one at a time.

## Procedure

1. **Pull the updated mockups.** Re-sync only the named artboards into `docs/designs/` via
   the design-sync capability (`/design-login`, then sync per `docs/designs/README.md` →
   "Re-pulling"). Keep the original filenames.

2. **Map each mockup → app route + states.** For every updated artboard, name the screen it
   depicts and each *state* it shows (empty, working, needs-input, in-review, error, …).
   This map is the bounded scope — do **not** walk screens the changed mockups don't cover.

3. **Capture both sides at mobile width.** These are mobile mockups, and the app is the same
   LiveView the native wrapper hosts (ADR 0001) — so drive the LiveView, not a separate
   client. For each screen/state:
   - Drive the running app into that state with the Playwright browser at a mobile viewport
     (~390×844), using seed data or scripted interactions to reach each state, and screenshot
     it. (See the `run` skill to launch the app.)
   - Open the artboard's `.dc.html` in the browser (it degrades to static inline-styled HTML,
     enough for layout and color) and screenshot it.
   Save each app/mockup pair under the scratchpad and keep the paths.

4. **Diff and build the list.** Compare each pair across: layout/spacing, typography,
   color/theme tokens, component states, copy, icons, and affordances. Produce a list where
   every item has: **name**, a **2–3 sentence description**, the **screen + state**,
   **severity** (trivial copy vs. structural), and its **screenshot pair**.

5. **Review with the human — one question at a time.** Present the full list as a readable
   document (not a picker — nothing hidden). Then walk it to set each item's disposition:
   **fix-app / drop (mockup stale) / discuss** — asking the human **one question at a time,
   never batched**. Let them edit, merge, split, or drop items. Only **fix-app** items
   proceed.

6. **Dedupe against open cards.** Run `bin/relay board` and compare the survivors against all
   **non-Done** cards by *meaning*, not exact title. Surface each likely duplicate to the
   human to confirm (one at a time) rather than silently skipping — a near-match may be a
   genuinely different diff.

7. **File the cards.** For each remaining item:
   `bin/relay create "<name>" --stage Backlog --tag design`, then set its description
   (`bin/relay describe <ref> @file`) to: the 2–3 sentence description + screen/state +
   artboard filename + saved screenshot paths. These are intake — point the user to
   `/brainstorm <ref>` for design.

## Common Mistakes
- Carding a diff without human confirmation — the mockup may be the stale side.
- Batching questions to the human instead of one at a time.
- Screenshotting the app at desktop width for a mobile mockup.
- Walking the whole app instead of only the changed mockups' screens and states.
- Designing or fixing here instead of stopping at filed Backlog cards.
