# CLI (`./relay`)

`./relay` is a single, zero-dependency tool (Python 3 stdlib only) that drives a board over
its REST API. Human-readable output by default; add `--json` for machine output. Any error
exits non-zero.

> [!NOTE]
> Every write is attributed to the board's AI agent, **"Relay AI"**. Set `RELAY_URL` and
> `RELAY_API_KEY` first — see [Authentication & API access](/docs/authentication). The one
> exception is `./relay update`, which needs only `RELAY_URL`: the board serves the scaffold
> unauthenticated, because it runs before a board key exists.

## Commands

| Command | What it does |
| --- | --- |
| `./relay update [--check]` | Install or refresh the six Relay-owned files from the board (`./relay`, the four `relay-*` skills, and `relay.md`). `--check` reports the served vs. local version and which files would change, and writes nothing. Add `--json` for machine output. It also removes a leftover Relay-owned `bin/relay` (the CLI moved to `./relay`). Prefer the `/relay-update` skill, which wraps it. See [Getting started](/docs) |
| `./relay board` | The board: stages with their cards |
| `./relay card RLY-12` | One card: description, plan, branch, timeline |
| `./relay stages` | The board's stages in board order — position, name, category, type, `ai:`, `wip:` and `substages:` per main stage, each substage indented beneath it. `--json` prints the list |
| `./relay stage add "Triage" --after Spec` | **Add a main stage.** Exactly one of `--before STAGE` / `--after STAGE` (it adopts the anchor's category) or `--category C` (appended to that category's end). Optional `--type`, `--description`, `--wip N` |
| `./relay stage set Code --wip 3` | **Change a main stage's settings**: `--name`, `--description`, `--type` (re-snaps its cards' statuses), `--wip N` or `none`, `--collapsed`/`--no-collapsed`, `--reject-to STAGE` or `none`. At least one option |
| `./relay stage move Code --before Spec` | **Place a main stage** just before/after another; it adopts the anchor's category |
| `./relay stage lane Code review on` | Turn a main stage's `review` or `done` substage `on` or `off` |
| `./relay stage rm Triage` | **Remove a main stage** and its substages. Refused (409, nothing written) while the stage or a substage holds live or archived cards, an enabled flow uses it, it is the public intake stage, or it is the last stage. Stages are addressed by exact name or numeric id; an ambiguous name is refused with the ids |
| `./relay search "words"` | **Find a card** by ref or title. A ref or bare number (`RLY-12`, `12`) is an exact hit ranked first; otherwise every whitespace-separated word must appear in the title, in any order. Done cards are included. `--archived` widens it to archived cards, `--limit N` caps it (default 20). No match prints a message and exits 0 |
| `./relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `./relay runs RLY-12` | The card's runs and node executions (failure detail in full) |
| `./relay runners` | Who is connected, their capacity, and the jobs they hold |
| `./relay version` | The git SHA the deployed app was built from |
| `./relay create "Fix login" --stage Backlog` | Create a card (optional `--stage`/`--description`/`--tag`/`--depends-on RE12,RE13`) |
| `./relay depends RLY-12 RLY-13 RLY-14` | **Replace the card's blocker set** — the card stays undispatchable until every blocker reaches a top-level Done column (`./relay why` reports `blocked_by_dependencies`). Passing no BLOCKERs clears the set. Refs may be separate arguments or comma-separated. A ref this board does not have, or an edge that would close a cycle, is refused and nothing is written |
| `./relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `./relay move RLY-12 Code` | Move to a stage by name |
| `./relay archive RLY-12` | **Archive the card** — it leaves the board and the timeline records it against Relay AI. Prints the card line ending in `(archived)`. A card with a live run is refused (`409 active_run`) and nothing is written: `./relay cancel RLY-12` first. Archiving an archived card is harmless |
| `./relay unarchive RLY-12` | **Restore an archived card** to its stage. Harmless on a card that is not archived |
| `./relay status RLY-12 working` | Set status (any card status, e.g. `working` — see [Statuses & outcomes](/docs/statuses-and-outcomes); it snaps to one the stage allows) |
| `./relay title RLY-12 "New title"` | Retitle the card (accepts `-` / `@file` like other text arguments). A blank title is refused |
| `./relay describe RLY-12 @description.md` | Set the card's description — the ask as stated. **Not** the same field as `spec` |
| `./relay spec RLY-12 @spec.md` | Set the card's spec — the design spec authored at the Spec stage |
| `./relay criteria RLY-12 @criteria.md` | Set the card's acceptance criteria (numbered; read at the review gate) |
| `./relay plan RLY-12 @plan.md` | Set the card's plan header (tasks go through `tasks add`) |
| `./relay branch RLY-12 rly-12-…` | Record the branch this card's work lives on |
| `./relay pr RLY-12 <url>` | Record the card's PR URL |
| `./relay tasks add RLY-12 --task "Title" @body.md [--task "Title" @body.md …]` | **Append tasks** — a title and a body each — in one atomic call, after the card's last task, in argument order. Bodies are raw files (`@path`, `-` for stdin at most once, or literal text): no JSON escaping |
| `./relay tasks list RLY-12` | The card's tasks as `[x]/[ ] #id  title` — titles and metadata, never bodies |
| `./relay task show RLY-12 42` | One task with its full body — the only way to read a body |
| `./relay task update RLY-12 42 --title T --body @file` / `task rm RLY-12 42` | Edit one task's title/body (`done` stays with `check`/`uncheck`) / remove one (later tasks move up; other ids and done flags are untouched) |
| `./relay check RLY-12 42` / `uncheck RLY-12 42` | Toggle one task done/undone by id |
| `./relay sub-tasks RLY-12 @tasks.md` | Legacy: replace the card's whole task list in one call — prefer `tasks add` |
| `./relay result RLY-12 @result.json` | Set the card's AI result blob — one fixed shape, see [The AI result blob](#the-ai-result-blob) |
| `./relay attach RLY-12 shot.png` | Upload a file to the card and print its markdown; `--field url` prints the `/attachments/<id>` path alone |
| `./relay mockups RLY-12 empty.html full.html --caption "Empty state" --caption "Full"` | Upload mockups and **replace** the card's list in one call (captions pair with files in order; default = filename). A mockup is **HTML or an image** — `.html .png .jpg .jpeg .webp .gif`; any other file is refused before anything uploads. `--clear` empties the list. HTML mockups must be **self-contained static HTML** — inline `<style>`/`<script>`, `data:` images/fonts; the one network exception is **Google Fonts** (`fonts.googleapis.com` / `fonts.gstatic.com`): they run in a sandbox with scripts on and every other request blocked. Humans review them in the drawer's **Mockups** section |
| `./relay mockups RLY-12 --pull [DIR]` | Download every mockup byte-for-byte as `DIR/NN-<caption-slug>.<ext>` in card order (default `tmp/RLY-12/mockups/`). `--json` prints `[{caption, url, path}]`; a card with none prints `RLY-12: no mockups` and exits 0. Can't be combined with files, `--caption` or `--clear` |
| `./relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `./relay own RLY-12` / `release RLY-12` | Claim for the AI / hand back |
| `./relay approve RLY-12` / `reject RLY-12 "note"` | Gate: advance / send back |
| `./relay retry RLY-12 [--at NODE]` | Retry the failed run — from the last node, or from `--at NODE` |
| `./relay cancel RLY-12 [--reason "…"]` | Cancel the card's active run — the stop half of `retry`. Never moves the card; follow with `move` |
| `./relay advance RLY-12` | The current task is already done — check it off and continue with the next one |
| `./relay audit [FLOW]` | **Board health:** run-history findings plus CI parity. Advisory; always exits 0. `--window` |
| `./relay flow-stats code` | Per-node metrics for a flow — duration, cost, attempts, verdicts. `--window` |
| `./relay flow` / `flow code` | The board's flows, or one flow's definition. `--json` is the pull — see [Flows as data](#flows-as-data) |
| `./relay flow-push code code.json` | Push an edited flow document back (`-` reads stdin) |

## The AI result blob

`./relay result` takes a JSON object with three optional keys, and **nothing else** — the card
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
url=$(./relay attach RLY-12 tmp/smoke/01-door.png --field url)   # → /attachments/<uuid>
```

Any other key — `deploy_url` at the top level, `image` / `shot` / `path` / `name` inside a
screen — is refused with `422 invalid_ai_result` naming what you wrote and what exists. The
refusal is the point: a blob the drawer can't read renders an empty Screenshots strip, silently.

## Depending one card on another

Dependencies exist to head off *parallel implementations of the same thing*, which land as bad
merges. Two shapes make one:

1. **Producer → consumer.** Card A creates a thing; card B uses it: `./relay depends B A`.
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
./relay spec RLY-12 @spec.md
git log -1 --format=%B | ./relay comment RLY-12 -
```

Every `--json` command also takes `--field PATH` to print a single dotted-path value bare —
`./relay card RLY-12 --field status` prints `working`, with no quotes and no `jq`.

## Keeping `./relay` current

Relay owns six files in your project — `./relay`, the four `relay-*` skills, and `relay.md` — and your
board serves them at `GET /api/scaffold`. They are Relay's, never yours, so an update overwrites
them unconditionally; nothing else in `.claude/` is ever touched.

```bash
./relay update --check    # served vs. local version, and what would change. Writes nothing.
./relay update            # apply
```

The manifest's `version` is derived from the files' content, so it moves exactly when they do.
**What gets written is decided by content, not by that version:** `./relay update` hashes all
six files against the manifest on every run and writes the ones that differ, so "this project is
current" means "nothing needs writing". A deleted skill comes back, and so does an **edited** one
— these six are Relay-owned, so a local change to them is damage to repair, not a customisation
to keep. A version that has moved while the bytes already match writes nothing but the recorded
version itself (the normal state after `./relay start` self-updates).

`./relay start` also keeps itself up to date (RE185). Each heartbeat reply names
`latest_runner_version` — the `RUNNER_VERSION` of the `./relay` the board actually serves —
and when the runner is behind it downloads that file, verifies it parses, writes it over its own
`./relay`, and restarts **at a job boundary**, so a running node is never interrupted. A
download that will not compile is refused and the previous version keeps running, and a
`./relay` with local modifications this runner did not write is never overwritten.

Two `.relay/runner.json` keys control it:

| Key | Default | What it does |
| --- | --- | --- |
| `auto_update` | `true` | Set `false` to pin this machine's CLI. It then falls back to RLY-184's behaviour: once the board's minimum passes it by, it stops claiming and says so loudly. |
| `auto_update_min_interval` | `300` | Seconds between update attempts. |

Publishing is now **coupled to deploying**: the scaffold is built into the app's image, so a
skill or CLI fix reaches projects when the app ships, and there is nothing to publish by hand.

For the autonomous runner and its operating rules, see [the runner](/docs/architecture-runner).

## Usage limits

`./relay start` reads Claude subscription usage from the jobs it already runs. When usage passes a
configured fraction of a window, it stops claiming. Jobs in flight finish. The runner reports
itself **RATE LIMITED** to the board and resumes when the window resets. It also resumes earlier
if a probe every 15 minutes shows usage has dropped. If Claude refuses a call outright, the
runner pauses until the reset even with no limits configured.

| Key | Default | What it does |
| --- | --- | --- |
| `limits.max_five_hour` | none (no limit) | Fraction (0–1) of the five-hour window at which to stop claiming. |
| `limits.max_seven_day` | none (no limit) | Fraction (0–1) of the seven-day window at which to stop claiming. |

Any other key inside `limits`, or a value outside 0–1, makes `relay start` refuse to start and
name the key.

## Runner config

`./relay update` creates `.relay/runner.json` when it is missing, documented inline: every key
carries a comment, and the `worktrees` block starts commented out. A line whose first
non-whitespace characters are `//` is a full-line comment; a trailing `//` after a value and
`/* */` block comments are not supported. The file is yours to tune and commit — `update` never
overwrites it.

**Worktree hooks.** `"worktrees": {"prepare": ".relay/prepare-worktree.sh", "cleanup":
".relay/cleanup-worktree.sh"}` (those are also the defaults). `prepare` warms a new per-card
worktree, and a failure fails the run. `cleanup` runs right before the runner deletes one, to stop
per-worktree servers or databases; it is best-effort (a failure is logged and the tree is removed
anyway), times out after 120s, and must be safe to run twice. A flat top-level `"prepare"` still
works but is deprecated.

## Flows as data

A board's flows — which stages are AI-enabled, what each node does, model/effort, retry and loop
budgets — are edited in **Settings › Stages** (the stage's FLOW band), or pulled and pushed as data:

```bash
./relay flow code --json > code.json   # nodes, edges, trigger as stage names, isolation, version
./relay flow-push code code.json
```

An unchanged push bumps nothing; an edited one bumps the version like an editor save. Include the
pulled `version` to get compare-and-swap (a `409` means the flow moved under you — re-pull,
re-apply, push again); omit it for last-write-wins.

Two rules keep custom nodes safe: a node's command should start by checking out the card's branch
(from `vars.branch`) and end by committing. A task loop (`foreach: card.tasks`) binds one task per
iteration; each loop node fetches its task's body with `{relay} task show {ref} {task_id}`
(`{task}` is its title). Legacy `card.sub_tasks` / `sub_tasks` / `{sub_task_id}` names are
normalized to `tasks` when a flow is loaded or pushed.
