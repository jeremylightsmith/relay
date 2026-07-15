# CLI (`bin/relay`)

`bin/relay` is a single, zero-dependency tool (Python 3 stdlib only) that drives a board over
its REST API. Human-readable output by default; add `--json` for machine output. Any error
exits non-zero.

> [!NOTE]
> Every write is attributed to the board's AI agent, **"Relay AI"**. Set `RELAY_URL` and
> `RELAY_API_KEY` first — see [Setup](/docs/setup).

## Commands

| Command | What it does |
| --- | --- |
| `bin/relay board` | The board: stages with their cards |
| `bin/relay card RLY-12` | One card: description, plan, branch, timeline |
| `bin/relay create "Fix login" --stage Backlog` | Create a card (optional `--stage`/`--description`/`--tag`) |
| `bin/relay pull` | (advisory) the next ready card per the config |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay move RLY-12 Code` | Move to a stage by name |
| `bin/relay status RLY-12 working` | Set status (`ready`, `working`, `needs_input`, `in_review`) |
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

For the autonomous runner and its operating rules, see [Agent integration](/docs/agent-integration).
