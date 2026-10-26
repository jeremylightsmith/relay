# CLI (`./hamaca`)

`./hamaca` is a single, zero-dependency tool (Python 3 stdlib only) that drives a board over
its REST API. Human-readable output by default; add `--json` for machine output. Any error
exits non-zero.

> [!NOTE]
> Every write is attributed to the board's AI agent, **"Hamaca AI"**. Set `HAMACA_URL` and
> `HAMACA_API_KEY` first — see [Authentication & API access](/docs/authentication). The one
> exception is `./hamaca update`, which needs only `HAMACA_URL`: the board serves the scaffold
> unauthenticated, because it runs before a board key exists.

## Commands

| Command | What it does |
| --- | --- |
| `./hamaca update [--check \| --starter-only] [--base REF]` | Install or refresh the Hamaca-owned files from the board (`./hamaca`, the three `hamaca-*` skills, `hamaca.md`, and the old-name shim and alias skills kept for the [upgrade window](#upgrading-from-relay)). `--check` reports the served vs. local version and which files would change, and writes nothing. `--starter-only` writes only a missing `.hamaca/runner.json` and `.hamaca/prepare-worktree.sh`, offline. `--base REF` sets the `base` of a runner.json it creates. Add `--json` for machine output. It also removes a leftover Hamaca-owned `bin/relay` (the CLI moved to `./hamaca`). Prefer the `/hamaca-update` skill, which wraps it. See [Getting started](/docs) |
| `./hamaca setup status` | **The board's guided-setup checklist** (the one `/hamaca-onboard` loops over): a `Setup checklist for <board>: N of 7 done. Next is <step> (<title>).` line, then each step and its indented sub-steps with a status glyph (`✓` done, `–` skipped, `!` failed, `◌` waiting, `▸` active, `○` pending) and its evidence — or its error, for a failed step. `--json` prints the whole checklist (`current` is the one step a report may move); `--field current` prints that id alone. Exits **3** with `relay: no guided setup on this board` on a board that has no checklist |
| `./hamaca setup report 5.1 --status done [--evidence TEXT] [--error TEXT] [--data JSON]` | **Report one guided-setup step.** `--status` is `waiting`, `done`, `failed` or `skipped`; `--data` is a JSON object (text, `-` for stdin, or `@path`) and anything else is refused before the request. Prints `✓ 5.1 done · <evidence>` then `Next is <step> (<title>).` (or `Setup checklist done.`). A step that isn't the current one is refused — `relay: not_current: … the current step is 5.3`, exit 1. Exits **3** on a board with no checklist |
| `./hamaca board` | The board: stages with their cards |
| `./hamaca card RLY-12` | One card: description, plan, branch, timeline |
| `./hamaca stages` | The board's stages in board order — position, name, category, type, `ai:`, `wip:` and `substages:` per main stage, each substage indented beneath it. A main stage whose enabled flow is paused by a broken board shape ends with `PAUSED (flow <key>)`. `--json` prints the list |
| `./hamaca stage add "Triage" --after Spec` | **Add a main stage.** Exactly one of `--before STAGE` / `--after STAGE` (it adopts the anchor's category) or `--category C` (appended to that category's end). Optional `--type`, `--description`, `--wip N` |
| `./hamaca stage set Code --wip 3` | **Change a main stage's settings**: `--name`, `--description`, `--type` (re-snaps its cards' statuses), `--wip N` or `none`, `--collapsed`/`--no-collapsed`, `--reject-to STAGE` or `none`. At least one option |
| `./hamaca stage move Code --before Spec` | **Place a main stage** just before/after another; it adopts the anchor's category |
| `./hamaca stage lane Code review on` | Turn a main stage's `review` or `done` substage `on` or `off` |
| `./hamaca stage rm Triage` | **Remove a main stage** and its substages. Refused (409, nothing written) while the stage or a substage holds live or archived cards, an enabled flow uses it, it is the public intake stage, or it is the last stage. Stages are addressed by exact name or numeric id; an ambiguous name is refused with the ids |
| `./hamaca search "words"` | **Find a card** by ref or title. A ref or bare number (`RLY-12`, `12`) is an exact hit ranked first; otherwise every whitespace-separated word must appear in the title, in any order. Done cards are included. `--archived` widens it to archived cards, `--limit N` caps it (default 20). No match prints a message and exits 0 |
| `./hamaca why RLY-12` | **Why isn't this card moving?** One plain-language answer. For a `flow_paused` verdict it also prints the broken shape's **What / Why / Fix** block verbatim |
| `./hamaca runs RLY-12` | The card's runs and node executions (failure detail in full) |
| `./hamaca runners` | Who is connected, their capacity, and the jobs they hold |
| `./hamaca version` | The git SHA the deployed app was built from |
| `./hamaca create "Fix login" --stage Backlog` | Create a card (optional `--stage`/`--description`/`--tag`/`--depends-on RE12,RE13`) |
| `./hamaca depends RLY-12 RLY-13 RLY-14` | **Replace the card's blocker set** — the card stays undispatchable until every blocker reaches a top-level Done column (`./hamaca why` reports `blocked_by_dependencies`). Passing no BLOCKERs clears the set. Refs may be separate arguments or comma-separated. A ref this board does not have, or an edge that would close a cycle, is refused and nothing is written |
| `./hamaca comment RLY-12 "…"` | Post a comment (as Hamaca AI) |
| `./hamaca move RLY-12 Code` | Move to a stage by name |
| `./hamaca archive RLY-12` | **Archive the card** — it leaves the board and the timeline records it against Hamaca AI. Prints the card line ending in `(archived)`. A card with a live run is refused (`409 active_run`) and nothing is written: `./hamaca cancel RLY-12` first. Archiving an archived card is harmless |
| `./hamaca unarchive RLY-12` | **Restore an archived card** to its stage. Harmless on a card that is not archived |
| `./hamaca status RLY-12 working` | Set status (any card status, e.g. `working` — see [Statuses & outcomes](/docs/statuses-and-outcomes); it snaps to one the stage allows) |
| `./hamaca title RLY-12 "New title"` | Retitle the card (accepts `-` / `@file` like other text arguments). A blank title is refused |
| `./hamaca describe RLY-12 @description.md` | Set the card's description — the ask as stated. **Not** the same field as `spec` |
| `./hamaca spec RLY-12 @spec.md` | Set the card's spec — the design spec authored at the Spec stage |
| `./hamaca criteria RLY-12 @criteria.md` | Set the card's acceptance criteria (numbered; read at the review gate) |
| `./hamaca plan RLY-12 @plan.md` | Set the card's plan header (tasks go through `tasks add`) |
| `./hamaca branch RLY-12 rly-12-…` | Record the branch this card's work lives on |
| `./hamaca pr RLY-12 <url>` | Record the card's PR URL |
| `./hamaca tasks add RLY-12 --task "Title" @body.md [--task "Title" @body.md …]` | **Append tasks** — a title and a body each — in one atomic call, after the card's last task, in argument order. Bodies are raw files (`@path`, `-` for stdin at most once, or literal text): no JSON escaping |
| `./hamaca tasks list RLY-12` | The card's tasks as `[x]/[ ] #id  title` — titles and metadata, never bodies |
| `./hamaca task show RLY-12 42` | One task with its full body — the only way to read a body |
| `./hamaca task update RLY-12 42 --title T --body @file` / `task rm RLY-12 42` | Edit one task's title/body (`done` stays with `check`/`uncheck`) / remove one (later tasks move up; other ids and done flags are untouched) |
| `./hamaca check RLY-12 42` / `uncheck RLY-12 42` | Toggle one task done/undone by id |
| `./hamaca sub-tasks RLY-12 @tasks.md` | Legacy: replace the card's whole task list in one call — prefer `tasks add` |
| `./hamaca result RLY-12 @result.json` | Set the card's AI result blob — one fixed shape, see [The AI result blob](#the-ai-result-blob) |
| `./hamaca attach RLY-12 shot.png` | Upload a file to the card and print its markdown; `--field url` prints the `/attachments/<id>` path alone |
| `./hamaca mockups RLY-12 empty.html full.html --caption "Empty state" --caption "Full"` | Upload mockups and **replace** the card's list in one call (captions pair with files in order; default = filename). A mockup is **HTML or an image** — `.html .png .jpg .jpeg .webp .gif`; any other file is refused before anything uploads. `--clear` empties the list. HTML mockups must be **self-contained static HTML** — inline `<style>`/`<script>`, `data:` images/fonts; the one network exception is **Google Fonts** (`fonts.googleapis.com` / `fonts.gstatic.com`): they run in a sandbox with scripts on and every other request blocked. Humans review them in the drawer's **Mockups** section |
| `./hamaca mockups RLY-12 --pull [DIR]` | Download every mockup byte-for-byte as `DIR/NN-<caption-slug>.<ext>` in card order (default `tmp/RLY-12/mockups/`). `--json` prints `[{caption, url, path}]`; a card with none prints `RLY-12: no mockups` and exits 0. Can't be combined with files, `--caption` or `--clear` |
| `./hamaca needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `./hamaca own RLY-12` / `release RLY-12` | Claim for the AI / hand back |
| `./hamaca approve RLY-12` / `reject RLY-12 "note"` | Gate: advance / send back |
| `./hamaca retry RLY-12 [--at NODE]` | Retry the failed run — from the last node, or from `--at NODE` |
| `./hamaca cancel RLY-12 [--reason "…"]` | Cancel the card's active run — the stop half of `retry`. Never moves the card; follow with `move` |
| `./hamaca advance RLY-12` | The current task is already done — check it off and continue with the next one |
| `./hamaca audit [FLOW]` | **Board health:** run-history findings plus CI parity. Advisory; always exits 0. `--window` |
| `./hamaca flow-stats code` | Per-node metrics for a flow — duration, cost, attempts, verdicts. `--window` |
| `./hamaca flow` / `flow code` | The board's flows, or one flow's definition. A flow paused by a broken board shape is marked `PAUSED` (an enabled flow only) and `flow code` prints the server's **What / Why / Fix** block under its header — a disabled flow's problem prints too, without `PAUSED`. `--json` is the pull — see [Flows as data](#flows-as-data) |
| `./hamaca flow-push code code.json` | Push an edited flow document back (`-` reads stdin) |

## The AI result blob

`./hamaca result` takes a JSON object with three optional keys, and **nothing else** — the card
drawer renders exactly these:

```json
{
  "summary": "- **One door** for everyone…",
  "changes": ["Adds a summary to the card drawer"],
  "screens": [
    { "url": "/attachments/135e5539-e4e9-4fd6-aa7a-5863ec683e4c",
      "caption": "Sign in — one email field" }
  ]
}
```

`summary` is markdown; `changes` is a list of **strings** (short verb phrases); `screens` is a
list of objects with `url` and an optional `caption`.

A screen's **`url` is the image itself, not the page it was taken on.** Upload the screenshot
and use the path `attach` prints:

```bash
url=$(./hamaca attach RLY-12 tmp/smoke/01-door.png --field url)   # → /attachments/<uuid>
```

Any other key — `deploy_url` at the top level, `image` / `shot` / `path` / `name` inside a
screen — is refused with `422 invalid_ai_result` naming what you wrote and what exists. The
refusal is the point: a blob the drawer can't read renders an empty Screenshots strip, silently.

## Depending one card on another

Dependencies exist to head off *parallel implementations of the same thing*, which land as bad
merges. Two shapes make one:

1. **Producer → consumer.** Card A creates a thing; card B uses it: `./hamaca depends B A`.
2. **Co-creation.** Two cards both need a thing that doesn't exist yet. Left alone, each builds its
   own version. Name one card the producer and point the other at it — or split the thing into its
   own card and depend both on it.

Touching the same file with no shared new thing is **not** a dependency; leave those parallel. A
blocked card is undispatchable until every blocker reaches a top-level Done column, so link only
what you mean.

## Long arguments

Text arguments accept `-` to read from **stdin** or `@path` to read from a **file**, so specs
and plans can be piped in:

```bash
./hamaca spec RLY-12 @spec.md
git log -1 --format=%B | ./hamaca comment RLY-12 -
```

Every `--json` command also takes `--field PATH` to print a single dotted-path value bare —
`./hamaca card RLY-12 --field status` prints `working`, with no quotes and no `jq`.

## Keeping `./hamaca` current

Hamaca owns a few files in your project — `./hamaca`, the three `hamaca-*` skills, and `hamaca.md`,
plus the old-name shim and alias skills kept for the [upgrade window](#upgrading-from-relay) — and
your board serves them at `GET /api/scaffold`. They are Hamaca's, never yours, so an update
overwrites them unconditionally; nothing else in `.claude/` is ever touched.

```bash
./hamaca update --check    # served vs. local version, and what would change. Writes nothing.
./hamaca update            # apply
./hamaca update --starter-only --base origin/trunk   # only the starter runner.json + prepare hook
```

The `./hamaca` your board serves has the board's URL baked into its `BOARD_URL` line, so it needs
no `HAMACA_URL`; an exported `HAMACA_URL` overrides it, and `./hamaca update` (and auto-update)
keep a project's baked URL.

The manifest's `version` is derived from the files' content, so it moves exactly when they do.
**What gets written is decided by content, not by that version:** `./hamaca update` hashes every
file against the manifest on every run and writes the ones that differ, so "this project is
current" means "nothing needs writing". A deleted skill comes back, and so does an **edited** one
— these files are Hamaca-owned, so a local change to them is damage to repair, not a customisation
to keep. A version that has moved while the bytes already match writes nothing but the recorded
version itself (the normal state after `./hamaca start` self-updates).

`./hamaca start` also keeps itself up to date (RE185). Each heartbeat reply names
`latest_runner_version` — the `RUNNER_VERSION` of the `./hamaca` the board actually serves —
and when the runner is behind it downloads that file, verifies it parses, writes it over its own
`./hamaca`, and restarts **at a job boundary**, so a running node is never interrupted. A
download that will not compile is refused and the previous version keeps running, and a
`./hamaca` with local modifications this runner did not write is never overwritten.

Two `.hamaca/runner.json` keys control it:

| Key | Default | What it does |
| --- | --- | --- |
| `auto_update` | `true` | Set `false` to pin this machine's CLI. It then falls back to RLY-184's behaviour: once the board's minimum passes it by, it stops claiming and says so loudly. |
| `auto_update_min_interval` | `300` | Seconds between update attempts. |

Publishing is now **coupled to deploying**: the scaffold is built into the app's image, so a
skill or CLI fix reaches projects when the app ships, and there is nothing to publish by hand.

For the autonomous runner and its operating rules, see [the runner](/docs/architecture-runner).

## Upgrading from ./relay

Before RE478 the CLI was called `./relay`. A repo set up then moves to the new names in two steps:

1. Run `./relay update`. It installs the new runner as `./relay`, so the repo keeps working
   under the old name.
2. Run `./relay update` again. This time the next `./relay update` renames the repo: `./relay`
   becomes `./hamaca` (a small `./relay` shim stays and runs it), `.relay/` becomes `.hamaca/`,
   `relay.md` becomes `hamaca.md`, the `relay-*` skills become `hamaca-*`, and the pointer line
   in your `CLAUDE.md` or `AGENTS.md` points at `hamaca.md`. It lists what it renamed and what it
   skipped. Commit the result.

Then stop the runner and restart it with `./hamaca start`.

Nothing breaks in between. `./relay`, the `RELAY_*` environment variables, `.relay/` and the
`relay-*` skills keep working until RE482 ends the compatibility window. Rename `RELAY_URL` and
`RELAY_API_KEY` in your shell setup to `HAMACA_URL` and `HAMACA_API_KEY` when it suits you.

## Usage limits

`./hamaca start` reads Claude subscription usage from the jobs it already runs. When usage passes a
configured fraction of a window, it stops claiming. Jobs in flight finish. The runner reports
itself **RATE LIMITED** to the board and resumes when the window resets. It also resumes earlier
if a probe every 15 minutes shows usage has dropped. If Claude refuses a call outright, the
runner pauses until the reset even with no limits configured.

| Key | Default | What it does |
| --- | --- | --- |
| `limits.max_five_hour` | none (no limit) | Fraction (0–1) of the five-hour window at which to stop claiming. |
| `limits.max_seven_day` | none (no limit) | Fraction (0–1) of the seven-day window at which to stop claiming. |

Any other key inside `limits`, or a value outside 0–1, makes `./hamaca start` refuse to start and
name the key.

## Runner config

`./hamaca update` creates `.hamaca/runner.json` when it is missing, documented inline: every key
carries a comment, and the `worktrees` block starts commented out. A line whose first
non-whitespace characters are `//` is a full-line comment; a trailing `//` after a value and
`/* */` block comments are not supported. The file is yours to tune and commit — `update` never
overwrites it.

**Worktree hooks.** `"worktrees": {"prepare": ".hamaca/prepare-worktree.sh", "cleanup":
".hamaca/cleanup-worktree.sh"}` (those are also the defaults). `prepare` warms a new per-card
worktree, and a failure fails the run. `cleanup` runs right before the runner deletes one, to stop
per-worktree servers or databases; it is best-effort (a failure is logged and the tree is removed
anyway), times out after 120s, and must be safe to run twice. A flat top-level `"prepare"` still
works but is deprecated.

## Flows as data

A board's flows — which stages are AI-enabled, what each node does, model/effort, retry and loop
budgets — are edited in **Settings › Stages** (the stage's FLOW band), or pulled and pushed as data:

```bash
./hamaca flow code --json > code.json   # nodes, edges, trigger as stage names, isolation, version
./hamaca flow-push code code.json
```

An unchanged push bumps nothing; an edited one bumps the version like an editor save. Include the
pulled `version` to get compare-and-swap (a `409` means the flow moved under you — re-pull,
re-apply, push again); omit it for last-write-wins.

Two rules keep custom nodes safe: a node's command should start by checking out the card's branch
(from `vars.branch`) and end by committing. A task loop (`foreach: card.tasks`) binds one task per
iteration; each loop node fetches its task's body with `{relay} task show {ref} {task_id}`
(`{task}` is its title). Legacy `card.sub_tasks` / `sub_tasks` / `{sub_task_id}` names are
normalized to `tasks` when a flow is loaded or pushed.
