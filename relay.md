# Working with Relay from your agent

Relay is an AI-first kanban board you drive from an agent. Work moves back and forth between
humans and AI as cards flow **left → right** through a board's stages — Relay decides which card
is ready, which flow runs it, and what each step does. You talk to it through one tool,
`bin/relay` (zero-dependency Python 3 — runs anywhere your agent does):

- **Drive a card** — `bin/relay board`, `card`, `move`, `comment`, … (this doc).
- **Run work** — `bin/relay execute` claims jobs from the server and runs them, passing the
  baton between human and AI. It's a separate role; setup lives at `$RELAY_URL/docs/agent-integration`.

**Dispatch is entirely server-side.** Which cards are ready, which flow they run, and what each
step does are decided by Relay and configured per-board in **Settings › Flows** — never in a
runner config file. `bin/relay` knows the REST API and nothing about any board's columns or agents.

## Setup

1. **Mint a board API key:** Relay → `/board/settings` → **API keys** → Generate (shown once).
   Every write is attributed to the board's AI agent ("Relay AI").
2. **Set the environment** the agent's shell uses (e.g. gitignored `.envrc.local`):
   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```
3. **Confirm:** `./bin/relay board` should print your board.

Full reference for any of the below: `$RELAY_URL/docs` (CLI, API, auth, statuses).

## Mental model — where state lives, where it drops

**Everything about a card travels *on the card*, not in the working tree.** Many cards are in
flight at once; a card may be specced now and planned days later while others pass through. So:

| The card carries | CLI to read/write |
|---|---|
| **spec** (the description) | `describe` |
| **acceptance criteria** | `criteria` |
| **plan** + **sub-task checklist** | `plan`, `sub-tasks` / `check` / `uncheck` |
| **branch**, **PR url**, **result** blob | `branch`, `pr`, `result` |

**Stages and substages.** Cards move left→right through stages. A stage may have two substages:
`*:Review` is a **human checkpoint** (an AI stage finishes here and stops for a human to
`approve` → `*:Done`); `*:Done` **auto-continues** (the next AI stage pulls it). A card is
"ready to pull" positionally when the column to its right is AI-owned.

**Status is a small closed set:** `ready | working | needs_input | in_review`. There is **no
`done` status** — Done is *derived*: a `ready` card parked at the terminal (rightmost) stage
reports `done: true`. Payloads also carry a `needs_you` fact, and the board rolls it up
(`needs_input` / `in_review` / `awaiting_human` / `agent_stalled`). Full vocabulary:
`$RELAY_URL/docs/statuses-and-outcomes`.

**Where cards get dropped** (all surfaced by `bin/relay why`):
- **Blocked on a human** — status `needs_input`; waits until a human answers.
- **Review gate** — sitting in a `*:Review` substage waiting for `approve`/`reject`.
- **No flow / nothing connected** — no enabled flow for that stage, or no executor connected.
- **Run failed or stranded** — a node failed, or a job's executor went away.

## Driver cheatsheet

Human output by default; add `--json` for machine output (`--field PATH` prints one value —
no `jq`). Non-zero exit on any error. Long text args accept `-` (stdin) or `@path` (file).

| Command | What it does |
|---|---|
| `bin/relay board` | The board: stages with their cards |
| `bin/relay card RLY-12` | One card: spec, plan, branch, timeline |
| `bin/relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `bin/relay runs RLY-12` | The card's runs + node executions, full failure detail |
| `bin/relay executors` | Who's connected, their capacity, the jobs they hold |
| `bin/relay flow-stats code` | Per-node metrics for a flow (duration, cost, attempts, verdicts); `--window` |
| `bin/relay version` | The git SHA the deployed app was built from |
| `bin/relay create "Fix login" --stage Backlog` | Create a card (`--stage`/`--description`/`--tag`) |
| `bin/relay move RLY-12 Code` | Move to a stage (by name, e.g. `"Code:Review"`) |
| `bin/relay status RLY-12 working` | Set status (`ready`\|`working`\|`needs_input`\|`in_review`) |
| `bin/relay describe` · `bin/relay criteria` · `bin/relay plan` · `bin/relay sub-tasks RLY-12 @file` | Set spec / criteria / plan / checklist |
| `bin/relay check` · `bin/relay uncheck RLY-12 42` | Toggle one sub-task done by id |
| `bin/relay branch` · `bin/relay pr` · `bin/relay result RLY-12 …` | Record branch / PR url / AI result blob |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `bin/relay own` · `bin/relay release RLY-12` | Claim for the AI / hand back |
| `bin/relay approve` · `bin/relay reject RLY-12 ["note"]` | Gate: advance / send back |
| `bin/relay retry RLY-12 [--at NODE]` | Retry the failed run — last node, or `--at NODE` |

Full table with every flag: `$RELAY_URL/docs/cli`.

## Playbooks

**Create & place a card.** `create` drops it in `--stage` (default Backlog). Placement is
positional: put it left of where the work starts; it becomes pullable when an AI column sits to
its right. Add a `--tag` to group it.

**Dig / find / reorganize.** There is no search verb yet — query with `--json`:
`bin/relay board --json` for the whole board, `bin/relay card RLY-12 --json --field plan` for one
field. Reorganize with `move` (stage), `tag`, and `comment`. (A first-class `search` is a known gap.)

**Diagnose a stuck card.** Start with `bin/relay why RLY-12` — it names the cause in a sentence.
Then `runs` for the untruncated failure, `executors` to see what's connected, `version` for the
deployed SHA. For *flow-level* time/cost bottlenecks, `bin/relay flow-stats <flow> --window 30d`.

**Hand-drive a card through any state.** You can move a card through its whole lifecycle by hand:
`own` it, `move` it stage to stage, set `status`, `approve`/`reject` at gates, `retry` a failed
run, `release` when done. The board reacts the same as if a flow drove it.

## Working inside a flow (for skills & agents that run as nodes)

If your skill runs *as a node* (e.g. a Spec, Plan, or Code step), two things matter:

**When to update the spec / plan / criteria is board-defined — discover it, don't assume.**
Whether a stage authors the spec, consumes the plan, or writes criteria is flow configuration,
and it changes per board and over time. Read the **installed skills**, **Settings › Flows**, and
`bin/relay why` to learn what the current flow expects of your step, rather than hard-coding a
hand-off. Write results with the CLI verbs above so they travel on the card.

### The `RELAY_NODE_SCRATCH` contract

Before running **every** node the executor sets `RELAY_NODE_SCRATCH` to a git-ignored temp file
inside the node's own worktree. It is **one file per card per node** — the path derives from
`(ref, node)`, so it is stable across retries and never collides with another run. Use it for
`outcome failed --detail @$RELAY_NODE_SCRATCH`, and put any sibling payload (e.g. a
`--questions` file for `needs-input`) next to it: `$(dirname "$RELAY_NODE_SCRATCH")/<name>.json`.
**Never invent your own absolute scratch path.**

The full node/outcome/`RELAY_PLAN` contract, the executor, and the operating invariants live at
`$RELAY_URL/docs/agent-integration`.

## Customizing a board's flows

A board's flows — which stages are AI-enabled, what each node does, model/effort, retry/loop
budgets — are edited in **Settings › Flows**, not in a repo config file. Two rules keep custom
nodes safe: a node's command should start by checking out the card's branch (from `vars.branch`)
and end by committing; and the Code flow's first node (`branch`, in the shipped `code.jsonc`)
materializes the card's `plan` into the per-card `$RELAY_PLAN` path for later nodes to work through.
