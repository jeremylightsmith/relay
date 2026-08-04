# Design captures — as-is

**Generated from the shipped app. Not design source of truth.**

These `.dc.html` files are produced by `bin/design-capture.mjs`, which drives a headless
browser over the running LiveView and writes each screen's computed styles back out as
inline HTML. They record **what the app looks like today**, so the Claude Design project can
iterate from what exists instead of from memory.

That is the opposite direction from [`docs/designs/`](../designs/README.md), and the reason
the two live apart:

| | [`docs/designs/`](../designs/README.md) | `docs/designs-as-is/` (here) |
| --- | --- | --- |
| Comes from | Claude Design, hand-authored | `bin/design-capture.mjs`, generated |
| Direction | design → app: **the app is built to match** | app → design: **the file is built to match the app** |
| Authority | visual source of truth | none; a snapshot |
| When it disagrees with the app | the app is wrong → [`/slicing-mockups`](../../.claude/skills/slicing-mockups/SKILL.md) | the file is stale → re-capture |
| Editing by hand | yes, via the design project | **never** — it is overwritten on the next capture |

| File | What it is |
| --- | --- |
| `Relay Card Detail.dc.html` | The card drawer, every face. 17 artboards: the Detail tab across ready / working / needs-input (question *and* escalation) / in-review / review-with-reject-open / sent-back / done / archived, the Run tab across mid-flight / parked / breaker-tripped / history / queued, the Activity feed, a 402px narrow shot, and the drawer in context over the board. |

## Regenerating

```sh
PORT=4021 mix phx.server &                                      # a server of its own
node bin/design-capture.mjs --base http://localhost:4021 --seed
```

Example data comes from `priv/repo/design_seeds.exs` — one card per state, on a board named
"Design Capture". `--seed` re-applies it, which is what makes two captures comparable: the
engine keeps advancing the seeded runs, so elapsed times and attempt counts drift otherwise.

`--list` shows the screens the script knows; `--only <id>` iterates on one artboard. The full
loop — including how to add a state or a whole screen, and what the style inliner is doing —
is in [`/design-capture`](../../.claude/skills/design-capture/SKILL.md).

The files are self-contained (remote images are inlined as data URIs) apart from the shared
design-canvas runtime, which they load from `../designs/support.js`.
