---
name: design
description: Use when a card sits in the board's Design stage, or a human asks for HTML mockups of a card before it is specced — the Design flow's `mockup` node, re-run on every Design:Review rejection. Also invocable as /design <ref>. Keywords: mockup, design stage, Design:Review, wireframe, UI options, rejected mockup.
---

# Design

Turn a card's ask into **mockups a human can look at** — uploaded to the card, never written
to the repo.

This skill takes a **card ref** as its first argument (`$ARGUMENTS`), e.g. `/design RE42`. The
**card is the home for this work**: mockups live in its `mockups` field (`./relay mockups`),
the reasoning lives in its comments, the decisions live in a `## Design` section of its
description, and nothing survives in the working tree.

<HARD-GATE>
This skill NEVER writes to the repository. The Design flow runs `shared_clean` — one worktree
shared with other cards' runs, held clean for them. No file under the repo, no commit, no
branch, no git command that changes anything, no other card. Every artifact you produce lives
in `$RELAY_NODE_SCRATCH`'s directory (`S` below) and reaches the human by **upload**.
</HARD-GATE>

Reading the repo is encouraged. Looking at the running app is encouraged. Writing to either is
not.

```bash
S="$(dirname "$RELAY_NODE_SCRATCH")"   # interactively: S="$(mktemp -d)"
```

## The round model

**Every invocation is one round.** A rejection at `Design:Review` re-runs this skill from
scratch, with no memory of what you did last time except what is *on the card*. Expect several
rounds on a real card — that is the design working, not failing.

The cardinal rule: **converge.** A round that redesigns from zero throws away everything the
previous rounds bought. Move one step closer to what the human wants, and leave enough of a
trail that the *next* round can do the same.

## 0. Read the situation

Always, before anything else: `./relay card <ref> --json`.

- **`description`** — the ask. Design sits *before* Spec on this board, so there is usually
  **no `spec` and no acceptance criteria** (if `spec` is populated, read it — it outranks your
  assumptions). A `## Design` section at its end is the previous rounds' decisions (§5).
- **`rejection.note`** — on a re-entry this is the **single most important input**: the human
  telling you exactly what is wrong. Read it before you form any other opinion.
- **Comments** (`timeline`) — every prior round logged what it tried and why (§5), and a
  `needs-input` answer is there too. **Read all of them** — this is what stops round 7 from
  re-proposing the layout killed in round 2.
- **`mockups`** — the artifacts being critiqued. Pull them back byte-for-byte:

      ./relay mockups <ref> --pull "$S/prev" --json

  **Always pass an explicit DIR** — the default `tmp/<REF>/mockups/` is inside the repo.
  `--json` returns `[{caption, url, path}]`. A card with none prints `<ref>: no mockups` and
  exits 0 — that is round 1, not an error. **Skip the inlined `<style>` block when reading**: a
  built mockup is ~190 KB of generated CSS carrying no design intent; the body markup is the
  content.

## 1. Ground in the real app — before designing, not after

A mockup that ignores what exists is a fantasy.

- **Look at the running app.** The dev server is normally on `http://localhost:4003`; if
  `curl -sf -o /dev/null http://localhost:4003/` fails, **skip this step**, say so in the round
  comment, and work from the code and artboards — never start, restart or seed a server.
  Otherwise use Playwright (recipe in §4): visit `/dev/login` first (it signs you in as the dev
  user), then the nearest existing screen. Screenshot it and **lift the markup** of the region
  you are changing — that makes your mockup a *diff from what exists* rather than a
  reimagining. **Read-only:** that server is the human's, on their database. Navigate and
  look; never submit a form, drag a card, or click anything that writes.
- **Read the design intent.** `docs/designs/README.md` indexes the hi-fi artboards
  (`docs/designs/*.dc.html`); the Design System artboard maps elements to daisyUI primitives.
  Never treat a `docs/designs-as-is/` capture as intent — it is generated from the app.
- **Read the components.** `lib/relay_web/components/` and `storybook/` show what already
  exists; reuse those patterns before inventing new ones.

## 2. Ask — a lot, and all at once

**Round 1 normally ends here, with no mockup.** A mockup built on a wrong assumption costs a
whole round to unwind.

Collect **every** question into a **single** `needs-input` call carrying a structured array,
then stop. The outcome contract appended to your prompt carries the exact command and
questions-JSON shape for this run (file beside `$RELAY_NODE_SCRATCH`) — follow it. How to write
a good question: one decision per array item; bold the subject in `prompt`, then ask plainly;
each option a full self-contained sentence (the human sees it alone on a button); mark your
pick `— RECOMMENDED`; leave `allow_text` true unless the options are exhaustive.

**Worth asking about:** the job the screen does and for whom; what is on it at the decisive
moment; what must be visible without scrolling; the empty, loading and error states; what it
replaces; which existing screen it should feel like; mobile (Relay ships a thin native wrapper
around these same pages); which parts are fixed requirements versus your call; whose baton the
UI is showing (human = blue `primary`, AI = violet `secondary`).

**Never ask what you can observe.** How the current screen works, what the data looks like,
what components exist — look. Spend the human's attention on *judgment*.

## 3. Build

Relay serves mockups under a sandbox CSP: inline `<style>`/`<script>` and `data:` images and
fonts only, plus Google Fonts — no CDN scripts, no remote images, no `fetch`. **Relay's own type
is system Helvetica Neue + JetBrains Mono with no font request**, so add no font `<link>`: the
mockup then renders exactly as the app does.

Write each option as `$S/opt-a.html` with `<html data-theme="light">`, a viewport meta, and
`<style>/*INLINE_CSS*/</style>` in the head, using the app's own daisyUI + Tailwind classes and
semantic tokens (`bg-base-100`, `text-base-content/65`, `btn-primary` — never raw colors, the
same rule as `AGENTS.md`). Give `<body>` `min-h-screen` with its background class, or the
background stops at the content and leaves a bare band.

Then build that mockup's stylesheet from the app's real one and inline it:

```bash
TWV="$(awk '/^config :tailwind/{f=1} f&&/version:/{gsub(/[^0-9.]/,"");print;exit}' config/config.exs)"
TW="$(ls -1 _build/tailwind-*-"$TWV")"     # the pinned standalone binary
printf '@import "%s/assets/css/app.css";\n@source "%s/opt-a.html";\n' "$(pwd)" "$S" > "$S/opt-a.css"
"$TW" --input="$S/opt-a.css" --output="$S/opt-a.built.css" --minify
python3 - "$S/opt-a.html" "$S/opt-a.built.css" <<'PY'
import sys; h, c = sys.argv[1], sys.argv[2]
open(h, "w").write(open(h).read().replace("/*INLINE_CSS*/", open(c).read(), 1))
PY
```

The `@import` brings the real daisyUI build and the real `light`/`dark` themes; the `@source`
makes classes used *only* in the mockup get generated. ~100 ms, writes only to `$S`. If the
binary is missing (`_build` not warm), say so in the round comment and stop with `failed` —
don't hand-write CSS that only approximates the app.

## 4. Self-check before upload — do not skip this

Render what you built and **actually look at it**. Playwright lives in the main checkout's
`assets/node_modules` (this worktree has none):

```bash
MAIN_ROOT="$(git rev-parse --path-format=absolute --git-common-dir | sed 's#/\.git/*$##')"
cat > "$S/shot.cjs" <<'JS'
const { chromium } = require('playwright');
const [file, out] = process.argv.slice(2);
(async () => {
  const browser = await chromium.launch({ headless: true });
  try {
    for (const [w, h, tag] of [[1500, 1000, 'desktop'], [390, 844, 'mobile']]) {
      const page = await browser.newPage({ viewport: { width: w, height: h } });
      await page.goto('file://' + file);
      await page.screenshot({ path: `${out}-${tag}.png`, fullPage: true });
      await page.close();
    }
  } finally { await browser.close(); }
})().catch((e) => { console.error('ERR', e.message); process.exit(1); });
JS
NODE_PATH="$MAIN_ROOT/assets/node_modules" node "$S/shot.cjs" "$S/opt-a.html" "$S/opt-a"
```

Then **read both PNGs** and fix what you see: overflow, collisions, unreadable contrast, a
mobile layout that never got designed, text that wraps into nonsense with real content.
Uploading something you never looked at burns a round on a defect you could have seen. (For
the app screenshots in §1, the same script with `page.goto('http://localhost:4003/dev/login')`
first works.)

## 5. Upload, and log the round

```bash
./relay mockups <ref> "$S/opt-a.html" "$S/opt-b.html" \
  --caption "A — one list, filter at top" \
  --caption "B — two panes, no filter"
```

`mockups` **replaces the card's whole list** — the card shows the current round, not a museum.
The history lives in comments, so **every round posts one** (`./relay comment <ref>
@"$S/round.md"`) recording briefly: **what the rejection note or answers asked for**, **what
you changed and why**, **what you deliberately left alone**, and **what you tried and
rejected**. A round without one is incomplete work.

### Record the decisions in the description

The comments are for *this skill's* future rounds. The **decisions** go where the Spec stage
reads them — a `## Design` section at the end of `description`, **replaced in place** every
round, never appended twice, never touching the human's text:

```bash
./relay card <ref> --field description > "$S/desc.md"
python3 - "$S/desc.md" "$S/design-section.md" <<'PY'
import re, sys
desc, section = open(sys.argv[1]).read(), open(sys.argv[2]).read().strip()
# Drop the old section: from its own heading line to the next #/## heading (or the end).
desc = re.sub(r'(?ms)^## Design[ \t]*\n.*?(?=^#{1,2} |\Z)', '', desc).strip()
open(sys.argv[1], 'w').write((desc + "\n\n" if desc else "") + section + "\n")
PY
./relay describe <ref> @"$S/desc.md"
```

**Decisions, not description.** Bullets. Record what was *decided* and anything a later stage
would otherwise get wrong — never a tour of the mockup, which the human can simply look at.
Name mockups by their **caption**: that is how `/brainstorm` and the Code flow refer to them.

```markdown
## Design
- Mockups on this card are the design of record: "A — one list, filter at top".
- Rejected two panes (too wide for the drawer).
- Empty state: inline, no illustration.
- Mobile: filter collapses to a select; rows stay full-width.
- Not designed: bulk actions (out of scope, follow-up).
```

## 6. End the round: ask, or land

- **Several options on the table** → upload them all, then `needs-input` asking which wins,
  with the trade-off named. The review gate only speaks approve/reject, so it cannot express
  "B, but smaller" — a question can.
- **Converged on one direction** → succeed. The card lands on `Design:Review` and the human
  approves (→ `Ready for Spec`) or rejects (→ another round). **Landing there is the job.**

**A card in this stage is a request for a mockup.** Non-visual work skips Design entirely, so
"this card doesn't need a design" is not a conclusion available to you. If the ask seems to
have no visual surface, you misread it or it is underspecified — **ask**. Never succeed without
mockups: the node declares `writes: ["mockups"]`, so an empty list turns `succeeded` into
`failed` anyway.

## Convergence rules

- **A rejection note naming a specific change means: make that change and keep everything else
  identical.** With the previous HTML pulled (§0) this is a targeted edit to that markup —
  rebuild the CSS (§3) and re-upload.
- **Only a note that questions the direction reopens option-generation.** "Too cramped" is a
  fix; "I'm not sure a list is right here" is a reopening.
- **Never silently drop something the human liked.** If a change forces it, say so in the
  round comment and explain the trade.
- **Two consecutive rejections for the same reason → stop guessing.** You have misunderstood
  something structural; ask with `needs-input` instead of shipping a third variation.

**Options discipline.** Each option embodies a **different decision**, not the same layout at
three paddings. The caption names the decision ("one list, filter at top"), never the pixels
("version A"). If you cannot name two real decisions, ship one mockup and a question.

## Hard rules

- **No repo writes** (see the hard gate). Gitignored build caches like `_build` are fine;
  tracked content is not.
- **This card only.** Never touch another card, never move this one, never create one.
- **Terminal.** Stop after uploading, describing and commenting. Do not write the spec, run
  `/brainstorm` or `/write-plan`, or start implementation. `Design:Review` is the gate.
- **The work is pre-authorized** when a flow node invokes this — never ask for confirmation to
  begin. Headless changes *how* you ask questions, never *whether*.
