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
| `./relay plan RLY-12 @plan.md` | Set the card's plan |
| `./relay branch RLY-12 rly-12-…` | Record the branch this card's work lives on |
| `./relay pr RLY-12 <url>` | Record the card's PR URL |
| `./relay sub-tasks RLY-12 @tasks.md` | Set the sub-task checklist |
| `./relay check RLY-12 42` / `uncheck RLY-12 42` | Toggle one sub-task done/undone by id |
| `./relay result RLY-12 @result.json` | Set the card's AI result blob |
| `./relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `./relay own RLY-12` / `release RLY-12` | Claim for the AI / hand back |
| `./relay approve RLY-12` / `reject RLY-12 "note"` | Gate: advance / send back |

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

