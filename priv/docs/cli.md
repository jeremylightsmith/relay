# CLI (`bin/relay`)

`bin/relay` is a single, zero-dependency tool (Python 3 stdlib only) that drives a board over
its REST API. Human-readable output by default; add `--json` for machine output. Any error
exits non-zero.

> [!NOTE]
> Every write is attributed to the board's AI agent, **"Relay AI"**. Set `RELAY_URL` and
> `RELAY_API_KEY` first — see [Authentication & API access](/docs/authentication). The one
> exception is `bin/relay init`, which needs neither: it pulls scaffolding from the
> `relay-config` repo over plain HTTPS and runs before a board key exists (it does need an
> interactive terminal).

## Commands

| Command | What it does |
| --- | --- |
| `bin/relay init` | Interactively scaffold this project from the `relay-config` repo: `relay.md`, `.claude/` agents + skills, `AGENTS.md`/`CLAUDE.md`. Flags: `--config-url` (relay-config base, else `RELAY_CONFIG_URL`), `--url` (board host for the closing checklist, else `RELAY_URL`), `--no-self-update` (skip the upgrade-only, verified `bin/relay` refresh). See [Getting started](/docs) |
| `bin/relay board` | The board: stages with their cards |
| `bin/relay card RLY-12` | One card: description, plan, branch, timeline |
| `bin/relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `bin/relay runs RLY-12` | The card's runs and node executions (failure detail in full) |
| `bin/relay executors` | Who is connected, their capacity, and the jobs they hold |
| `bin/relay version` | The git SHA the deployed app was built from |
| `bin/relay create "Fix login" --stage Backlog` | Create a card (optional `--stage`/`--description`/`--tag`) |
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

`bin/relay execute` keeps itself up to date (RE185). Each heartbeat reply names
`latest_executor_version` — the newest CLI the public `relay-config` repo actually serves — and
when the executor is behind it downloads that file, verifies it parses, writes it over its own
`bin/relay`, and restarts **at a job boundary**, so a running node is never interrupted. A
download that will not compile is refused and the previous version keeps running, and a
`bin/relay` with local modifications this executor did not write is never overwritten.

Two `.relay/executor.json` keys control it:

| Key | Default | What it does |
| --- | --- | --- |
| `auto_update` | `true` | Set `false` to pin this machine's CLI. It then falls back to RLY-184's behaviour: once the board's minimum passes it by, it stops claiming and says so loudly. |
| `auto_update_min_interval` | `300` | Seconds between update attempts. |

`RELAY_CONFIG_URL` overrides where the CLI is fetched from.

Publishing stays a human step: `mix relay.publish_config` regenerates the `relay-config` tree and
records what it published in `.relay/published.json`. `mix relay.publish_config --check` exits
non-zero when `bin/relay` is ahead of that marker (i.e. executors cannot yet fetch your change);
`mix precommit` runs the `--check --warn` form, which prints the same warning without failing.

For the autonomous runner and its operating rules, see [the runner](/docs/architecture-runner).
