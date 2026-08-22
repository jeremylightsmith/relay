# CLI (`bin/relay`)

`bin/relay` is a single, zero-dependency tool (Python 3 stdlib only) that drives a board over
its REST API. Human-readable output by default; add `--json` for machine output. Any error
exits non-zero.

> [!NOTE]
> Every write is attributed to the board's AI agent, **"Relay AI"**. Set `RELAY_URL` and
> `RELAY_API_KEY` first — see [Authentication & API access](/docs/authentication). The one
> exception is `bin/relay update`, which needs only `RELAY_URL`: the board serves the scaffold
> unauthenticated, because it runs before a board key exists.

## Commands

| Command | What it does |
| --- | --- |
| `bin/relay update [--check]` | Install or refresh the six Relay-owned files from the board (`bin/relay`, the four `relay-*` skills, and `relay.md`). `--check` reports the served vs. local version and which files would change, and writes nothing. Add `--json` for machine output. Prefer the `/relay-update` skill, which wraps it. See [Getting started](/docs) |
| `bin/relay board` | The board: stages with their cards |
| `bin/relay card RLY-12` | One card: description, plan, branch, timeline |
| `bin/relay search "words"` | **Find a card** by ref or title. A ref or bare number (`RLY-12`, `12`) is an exact hit ranked first; otherwise every whitespace-separated word must appear in the title, in any order. Done cards are included. `--archived` widens it to archived cards, `--limit N` caps it (default 20). No match prints a message and exits 0 |
| `bin/relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `bin/relay runs RLY-12` | The card's runs and node executions (failure detail in full) |
| `bin/relay executors` | Who is connected, their capacity, and the jobs they hold |
| `bin/relay version` | The git SHA the deployed app was built from |
| `bin/relay create "Fix login" --stage Backlog` | Create a card (optional `--stage`/`--description`/`--tag`/`--depends-on RE12,RE13`) |
| `bin/relay depends RLY-12 RLY-13 RLY-14` | **Replace the card's blocker set** — the card stays undispatchable until every blocker reaches a top-level Done column (`bin/relay why` reports `blocked_by_dependencies`). Passing no BLOCKERs clears the set. Refs may be separate arguments or comma-separated. A ref this board does not have, or an edge that would close a cycle, is refused and nothing is written |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay move RLY-12 Code` | Move to a stage by name |
| `bin/relay status RLY-12 working` | Set status (any card status, e.g. `working` — see [Statuses & outcomes](/docs/statuses-and-outcomes); it snaps to one the stage allows) |
| `bin/relay describe RLY-12 @spec.md` | Set the card's description (the spec) |
| `bin/relay criteria RLY-12 @criteria.md` | Set the card's acceptance criteria (numbered; read at the review gate) |
| `bin/relay plan RLY-12 @plan.md` | Set the card's plan |
| `bin/relay branch RLY-12 rly-12-…` | Record the branch this card's work lives on |
| `bin/relay pr RLY-12 <url>` | Record the card's PR URL |
| `bin/relay sub-tasks RLY-12 @tasks.md` | Set the sub-task checklist |
| `bin/relay check RLY-12 42` / `uncheck RLY-12 42` | Toggle one sub-task done/undone by id |
| `bin/relay result RLY-12 @result.json` | Set the card's AI result blob |
| `bin/relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `bin/relay own RLY-12` / `release RLY-12` | Claim for the AI / hand back |
| `bin/relay approve RLY-12` / `reject RLY-12 "note"` | Gate: advance / send back |

## Long arguments

Text arguments accept `-` to read from **stdin** or `@path` to read from a **file**, so specs
and plans can be piped in:

```bash
bin/relay describe RLY-12 @spec.md
git log -1 --format=%B | bin/relay comment RLY-12 -
```

Every `--json` command also takes `--field PATH` to print a single dotted-path value bare —
`bin/relay card RLY-12 --field status` prints `working`, with no quotes and no `jq`.

## Keeping `bin/relay` current

Relay owns six files in your project — `bin/relay`, the four `relay-*` skills, and `relay.md` — and your
board serves them at `GET /api/scaffold`. They are Relay's, never yours, so an update overwrites
them unconditionally; nothing else in `.claude/` is ever touched.

```bash
bin/relay update --check    # served vs. local version, and what would change. Writes nothing.
bin/relay update            # apply
```

The manifest's `version` is derived from the files' content, so it moves exactly when they do.
**What gets written is decided by content, not by that version:** `bin/relay update` hashes all
six files against the manifest on every run and writes the ones that differ, so "this project is
current" means "nothing needs writing". A deleted skill comes back, and so does an **edited** one
— these six are Relay-owned, so a local change to them is damage to repair, not a customisation
to keep. A version that has moved while the bytes already match writes nothing but the recorded
version itself (the normal state after `bin/relay execute` self-updates).

`bin/relay execute` also keeps itself up to date (RE185). Each heartbeat reply names
`latest_executor_version` — the `EXECUTOR_VERSION` of the `bin/relay` the board actually serves —
and when the executor is behind it downloads that file, verifies it parses, writes it over its own
`bin/relay`, and restarts **at a job boundary**, so a running node is never interrupted. A
download that will not compile is refused and the previous version keeps running, and a
`bin/relay` with local modifications this executor did not write is never overwritten.

Two `.relay/executor.json` keys control it:

| Key | Default | What it does |
| --- | --- | --- |
| `auto_update` | `true` | Set `false` to pin this machine's CLI. It then falls back to RLY-184's behaviour: once the board's minimum passes it by, it stops claiming and says so loudly. |
| `auto_update_min_interval` | `300` | Seconds between update attempts. |

Publishing is now **coupled to deploying**: the scaffold is built into the app's image, so a
skill or CLI fix reaches projects when the app ships, and there is nothing to publish by hand.

For the autonomous runner and its operating rules, see [the runner](/docs/architecture-runner).
