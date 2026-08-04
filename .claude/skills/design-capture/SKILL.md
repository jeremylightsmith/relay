---
name: design-capture
description: Use when the user wants a Claude Design mockup regenerated FROM the shipped app — "get Claude Design up to date", "make a .dc.html from the real code", "the mockup is stale, rebuild it from the app". The reverse of slicing-mockups. Keywords: design capture, dc.html, designs-as-is, artboard from code, refresh mockup, upload to Claude Design.
---

# Design Capture

## Overview
Regenerate a `docs/designs-as-is/*.dc.html` mockup **from the running LiveView** so the
Claude Design project can keep iterating from what actually shipped. Core principle: **the
app is the source, the mockup is the output** — never hand-edit the generated file, change
the LiveView (or the frame list) and re-capture.

Captures land in `docs/designs-as-is/`, **never** `docs/designs/`. That split is the whole
point of the directory: `docs/designs/` is pulled from Claude Design and the app is built to
match it; `docs/designs-as-is/` is generated from the app and has no authority over it. A
capture written into `docs/designs/` would silently become "source of truth" for whatever it
happened to snapshot.

This is the mirror image of [`slicing-mockups`](../slicing-mockups/SKILL.md), which flows
the other way (design → app). Reach for that one when the *design* changed; this one when
the *app* changed and the mockup fell behind.

## When to Use
The user wants a design doc that matches the current app, or wants to upload the current
app back into Claude Design. **Not** for: designing a change, or reconciling the app to a
mockup someone else edited.

## Inputs
Which screen. `node bin/design-capture.mjs --list` prints the ones already defined
(`card-detail` today). A screen the script doesn't know yet needs a new entry in `SCREENS`
— see *Adding a screen* below.

## Procedure

1. **Start a dev server on a port of its own.** Other worktrees leave servers on 4003, and
   a half-broken one produces a half-broken mockup.
   ```
   PORT=4021 mix phx.server        # in the background
   curl -s -o /dev/null -w '%{http_code}\n' http://localhost:4021/     # want 200
   ```
   `mix ecto.migrate` first if the schema moved.

2. **Capture.** `--seed` re-seeds the demo board first; always pass it, because the engine
   keeps advancing the seeded runs and two captures otherwise disagree on attempt counts
   and elapsed times.
   ```
   node bin/design-capture.mjs --base http://localhost:4021 --seed --screen card-detail
   ```
   It prints one line per artboard with its pixel size. **Every artboard must say `ok`** —
   a `FAILED` line means that state is missing from the mockup, not that it degraded
   gracefully. Iterate on one with `--only <id>[,<id>]`, writing the probe to scratch —
   `--out "$(dirname "$RELAY_NODE_SCRATCH")/probe.dc.html"` — so a half-built capture never
   lands in `docs/designs-as-is/`.

3. **Look at it.** Open the output and compare a couple of artboards against the live app
   side by side — screenshot the artboard (`#<frame-id> > div:last-child`) and the live
   element, and read them next to each other. Layout bugs in the inliner are obvious this
   way and invisible in the console output. Check at minimum: borders (phantom black
   edges), text overlap (a pinned height that should have been `auto`), and that nothing
   escapes its frame (a `position:fixed` that did not get re-anchored).

4. **A crash in the app is a finding, not an obstacle.** Capturing walks states nobody
   clicks through by hand, so it surfaces real bugs — an unhandled status, a missing
   pattern-match clause. Fix the app (with a test), do not work around it in the seed.

5. **Verify and report.** `mix precommit`, then tell the user the output path, the artboard
   count, and anything you had to fix in the app along the way.

## Adding a screen or a state

Both live in `bin/design-capture.mjs`:

- **A new state of an existing screen** — add a `drawer({...})` entry to that screen's
  `frames`. Give it `id`, `group`, `name`, `note`, and the `card` ref to open; add
  `tab: "run" | "activity"` for a non-Detail tab, `prepare` for a click-through state
  (open a panel, fill a field), `hide` for dev-only chrome, `viewport` for a narrow shot.
  If no seeded card produces the state, add one to `priv/repo/design_seeds.exs` — **append
  at the end**, since refs are assigned in creation order and the frame list addresses
  cards by ref.
- **A whole new screen** — add a key to `SCREENS` with `title`, `tagline`, `intro`, and
  `frames`. The title becomes the default output filename, so match the existing
  `Relay <Thing>.dc.html` naming and keep it stable — the mockups cross-link by filename.

Then add a row to the table in `docs/designs-as-is/README.md`.

## How the inliner works (read before debugging it)

Each artboard is the real DOM subtree with every computed style written back as an inline
`style=`, diffed twice so the output stays readable: against a per-tag baseline measured
under the **same reset** the artboard carries, and against the parent's value for inherited
properties. Four things it does that are easy to break:

- **The reset is inherit-safe.** `*{list-style:none}` in the reset would out-specify the
  cascade and eat every value the diff skipped as "the parent already has it".
- **Sizes come from the Typed OM**, not `getComputedStyle` — the latter returns the *used*
  width, which pins every block to the pixel and stops it reflowing.
- **Borders are emitted as a trio or not at all.** Tailwind's preflight sets
  `border-style:solid` everywhere; a lone style with no width paints a 3px black box.
- **`position:fixed` becomes `absolute`**, pinned against its containing block, so the
  overlay lands inside the artboard frame instead of over the whole page.

## Common Mistakes
- Writing a capture into `docs/designs/`. It belongs in `docs/designs-as-is/`.
- Hand-editing the generated `.dc.html`. It is overwritten on the next capture.
- Shipping a run with a `FAILED` artboard because the file still got written.
- Capturing without `--seed` and wondering why the diff is noisy.
- Trusting the console. It reports what serialized, not what it looks like — step 3 is the
  actual check.
