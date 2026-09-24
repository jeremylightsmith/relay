# Working with Relay from your agent

Relay is an AI-first kanban board you drive from an agent. Work moves back and forth between
humans and AI as cards flow **left → right** through a board's stages — Relay decides which card
is ready, which flow runs it, and what each step does. You talk to it through one tool,
`./relay` (zero-dependency Python 3 — runs anywhere your agent does):

- **Drive a card** — `./relay board`, `card`, `move`, `comment`, … (this doc).
- **Run work** — `./relay start` claims jobs from the server and runs them, passing the
  baton between human and AI. It's a separate role; setup lives at `$RELAY_URL/docs/architecture-runner`.

**Dispatch is entirely server-side.** Which cards are ready, which flow they run, and what each
step does are decided by Relay and configured per-board in **Settings › Flows** — never in a
runner config file. `./relay` knows the REST API and nothing about any board's columns or agents.

## Setup

1. **Mint a board API key:** Relay → `/board/settings` → **API keys** → Generate (shown once).
   Every write is attributed to the board's AI agent ("Relay AI").
2. **Set the environment** the agent's shell uses (e.g. gitignored `.envrc.local`):
   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```
3. **Confirm:** `./relay board` should print your board.
4. **Wire the repo to a flow:** in Claude Code, run `/relay-onboard`. It reconciles this repo's
   `.claude/` factory against the board's flows — authoring what the flow names and you don't
   have yet, adopting what you already have, or both — until `/relay-doctor` reports zero errors,
   then offers to enable the flows.
   (Already wired and one node broke? Reach for `/relay-doctor` directly.)

**Usage limits.** `.relay/runner.json` can carry `"limits": {"max_five_hour": 0.9,
"max_seven_day": 0.9}`. Once Claude usage passes that fraction of the five-hour or seven-day
window, `relay start` stops claiming new work (running jobs finish), shows as **RATE LIMITED** on
the Runners view, and resumes on its own at the reset, or earlier if a probe shows usage has
dropped. A missing key means no limit. A card waiting only on paused runners shows an amber
`Rate limited · resumes …` chip.

**Worktree hooks.** `.relay/runner.json` can carry `"worktrees": {"prepare":
".relay/prepare-worktree.sh", "cleanup": ".relay/cleanup-worktree.sh"}` (those are also the
defaults). `prepare` warms a new per-card worktree, and a failure fails the run. `cleanup` runs
right before the runner deletes one, to stop per-worktree servers or databases. It is
best-effort (a failure is logged and the tree is removed anyway), times out after 120s, and
must be safe to run twice. A flat top-level `"prepare"` still works but is deprecated.

Full reference for any of the below: `$RELAY_URL/docs` (CLI, API, auth, statuses).

## Mental model — where state lives, where it drops

**Everything about a card travels *on the card*, not in the working tree.** Many cards are in
flight at once; a card may be specced now and planned days later while others pass through. So:

| The card carries | CLI to read/write |
|---|---|
| **description** — the ask as stated | `describe` |
| **spec** — the design spec authored at the Spec stage | `spec` |
| **acceptance criteria** | `criteria` |
| **plan** + **sub-task checklist** | `plan`, `sub-tasks` / `check` / `uncheck` |
| **branch**, **PR url**, **result** blob | `branch`, `pr`, `result` |
| **blockers** — the cards this one waits on | `depends` |

**Stages and substages.** Cards move left→right through stages. A stage may have two substages:
`*:Review` is a **human checkpoint** (an AI stage finishes here and stops for a human to
`approve` → `*:Done`); `*:Done` **auto-continues** (the next AI stage pulls it). A card is
"ready to pull" positionally when the column to its right is AI-owned.

**Status is a small closed set:** `ready | working | needs_input | in_review`. There is **no
`done` status** — Done is *derived*: a `ready` card parked at the terminal (rightmost) stage
reports `done: true`. Payloads also carry a `needs_you` fact, and the board rolls it up
(`needs_input` / `in_review` / `awaiting_human` / `agent_stalled`). Full vocabulary:
`$RELAY_URL/docs/statuses-and-outcomes`.

**Where cards get dropped** (all surfaced by `./relay why`):
- **Blocked on a human** — status `needs_input`; waits until a human answers.
- **Review gate** — sitting in a `*:Review` substage waiting for `approve`/`reject`.
- **No flow / nothing connected** — no enabled flow for that stage, or no runner connected.
- **Run failed or stranded** — a node failed, or a job's runner went away.

## Driver cheatsheet

Human output by default; add `--json` for machine output (`--field PATH` prints one value —
no `jq`). Non-zero exit on any error. Long text args accept `-` (stdin) or `@path` (file).

| Command | What it does |
|---|---|
| `./relay board` | The board: stages with their cards |
| `./relay card RLY-12` | One card: spec, plan, branch, timeline |
| `./relay search "words"` | Find a card by ref or title — ref/bare number first, then title; `--archived`, `--limit` |
| `./relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `./relay runs RLY-12` | The card's runs + node executions, full failure detail |
| `./relay runners` | Who's connected, their capacity, the jobs they hold |
| `./relay audit [code]` | **Board health:** run-history findings + CI parity — advisory, always exits 0; `--window` |
| `./relay flow-stats code` | Per-node metrics for a flow (duration, cost, attempts, verdicts); `--window` |
| `./relay flow` · `./relay flow code` | The board's flows, or one flow's definition; `--json` **is the pull** |
| `./relay flow-push code code.json` | Push an edited flow document back (`-` reads stdin) |
| `./relay version` | The git SHA the deployed app was built from |
| `./relay update [--check]` | Install or refresh the five Relay-owned files (`./relay` + the four `relay-*` skills) from the board's `/api/scaffold`. `--check` reports and writes nothing. Prefer `/relay-update`, which wraps it. |
| `./relay create "Fix login" --stage Backlog` | Create a card (`--stage`/`--description`/`--tag`/`--depends-on`) |
| `./relay move RLY-12 Code` | Move to a stage (by name, e.g. `"Code:Review"`) |
| `./relay title RLY-12 "New title"` | Retitle the card |
| `./relay archive` · `./relay unarchive RLY-12` | Take the card off the board / put it back in its stage. A card with a live run refuses `archive` (409 `active_run`) — `cancel` it first |
| `./relay status RLY-12 working` | Set status (`ready`\|`working`\|`needs_input`\|`in_review`) |
| `./relay describe` · `./relay spec` · `./relay criteria` · `./relay plan` · `./relay sub-tasks RLY-12 @file` | Set description / spec / criteria / plan / checklist — `describe` and `spec` are **separate fields**, not synonyms |
| `./relay check` · `./relay uncheck RLY-12 42` | Toggle one sub-task done by id |
| `./relay branch` · `./relay pr` · `./relay result RLY-12 …` | Record branch / PR url / AI result blob — the blob has one shape, below |
| `./relay attach RLY-12 shot.png` | Upload a file to the card and print its markdown; `--field url` gives the `/attachments/…` path for a `screens` entry |
| `./relay depends RLY-12 RLY-13 RLY-14` | Replace the card's blocker set — it stays undispatchable until every blocker reaches a top-level Done column. No BLOCKERs clears it. Refs may be separate args or comma-separated; `./relay create --depends-on RE12,RE13` sets them at creation |
| `./relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `./relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `./relay own` · `./relay release RLY-12` | Claim for the AI / hand back |
| `./relay approve` · `./relay reject RLY-12 ["note"]` | Gate: advance / send back |
| `./relay retry RLY-12 [--at NODE]` | Retry the failed run — last node, or `--at NODE` |
| `./relay cancel RLY-12 [--reason "…"]` | Cancel the card's active run — the stop half of `retry`. Never moves the card; follow with `move` |
| `./relay advance RLY-12` | The task is already done — check it off and continue with the next one |

Full table with every flag: `$RELAY_URL/docs/cli`.

## Playbooks

**Create & place a card.** `create` drops it in `--stage` (default Backlog). Placement is
positional: put it left of where the work starts; it becomes pullable when an AI column sits to
its right. Add a `--tag` to group it.

**Depend one card on another.** Dependencies exist to head off *parallel implementations of the
same thing*, which land as bad merges. Two shapes make one:

1. **Producer → consumer.** Card A creates a thing; card B uses it. `./relay depends B A`.
2. **Co-creation.** Two cards both need a thing that doesn't exist yet. Left alone, each builds its
   own version and the merge is a fight over which one is real. Fix: name one card the producer and
   point the other at it — or split the thing into its own card and depend both on it.

Touching the same file with no shared new thing is **not** a dependency; leave those parallel. A
blocked card is undispatchable until every blocker reaches a top-level Done column, so link only
what you mean. Set them at creation with `--depends-on`, or later with `depends` (which *replaces*
the whole blocker set; no refs clears it).

**Dig / find / reorganize.** `./relay search "words"` finds a card by ref or title: a ref or a
bare number (`RLY-12`, `12`) is an exact hit ranked first, otherwise every whitespace-separated
word must appear in the title, in any order. Done cards are included — finished work is exactly
what the board's bounded Done column hides. `--archived` widens it to archived cards (marked
`(archived)`), `--limit N` caps it (default 20), and no match is a plain message on stdout with
exit 0. For everything else query with `--json`: `./relay board --json` for the whole board,
`./relay card RLY-12 --json --field plan` for one field. Reorganize with `move` (stage), `title`,
`tag`, and `comment`; `archive` takes a finished or abandoned card off the board and `unarchive`
brings it back. `archive` refuses a card with a live run — `./relay cancel RLY-12` first.

**Diagnose a stuck card.** Start with `./relay why RLY-12` — it names the cause in a sentence.
Then `runs` for the untruncated failure, `runners` to see what's connected, `version` for the
deployed SHA. For *flow-level* time/cost bottlenecks, `./relay flow-stats <flow> --window 30d`.

**Hand-drive a card through any state.** You can move a card through its whole lifecycle by hand:
`own` it, `move` it stage to stage, set `status`, `approve`/`reject` at gates, `retry` a failed
run, `advance` past a task whose work is already committed, `release` when done. The board
reacts the same as if a flow drove it.

## Working inside a flow (for skills & agents that run as nodes)

If your skill runs *as a node* (e.g. a Spec, Plan, or Code step), two things matter:

**When to update the spec / plan / criteria is board-defined — discover it, don't assume.**
Whether a stage authors the spec, consumes the plan, or writes criteria is flow configuration,
and it changes per board and over time. Read the **installed skills**, **Settings › Flows**, and
`./relay why` to learn what the current flow expects of your step, rather than hard-coding a
hand-off. Write results with the CLI verbs above so they travel on the card.

**When your node's work is already committed.** If you are re-entered onto a task whose change is
already on the branch, do not fabricate a commit and do not escalate — declare
`./relay outcome succeeded --no-changes`. The server checks that against this run's history and
refuses it unless this node has already committed for this task.

### The `RELAY_NODE_SCRATCH` contract

Before running **every** node the runner sets `RELAY_NODE_SCRATCH` to a git-ignored temp file
inside the node's own worktree. It is **one file per card per node** — the path derives from
`(ref, node)`, so it is stable across retries and never collides with another run. Use it for
`outcome failed --detail @$RELAY_NODE_SCRATCH`, and put any sibling payload (e.g. a
`--questions` file for `needs-input`) next to it: `$(dirname "$RELAY_NODE_SCRATCH")/<name>.json`.
**Never invent your own absolute scratch path.**

The full node/outcome/`RELAY_PLAN` contract, the runner, and the operating invariants live at
`$RELAY_URL/docs/architecture-runner`.

### The AI result blob (`./relay result`)

`./relay result RLY-12 @result.json` sets the card's **AI result** — the box a human reads in
the card drawer. It has **one shape**, and the drawer renders exactly these keys:

```json
{
  "summary": "- **One door** for everyone…\n- …",
  "changes": ["Adds a summary to the card drawer", "Emails a 6-digit code instead of a link"],
  "screens": [
    { "url": "/attachments/135e5539-e4e9-4fd6-aa7a-5863ec683e4c",
      "caption": "Sign in — one email field, \"Email me a code\"" }
  ]
}
```

- **`summary`** — a string, rendered as markdown. A short bullet list for a product owner.
- **`changes`** — a list of **strings**, each a short verb phrase ("Adds…", "Removes…"). Not
  objects: `{"change": …, "file": …}` is refused.
- **`screens`** — a list of objects with **`url`** (required) and **`caption`** (optional).
  Nothing else.

**`url` is the image itself, not the page it was taken on.** Upload each screenshot first and
use the path `attach` gives back:

```bash
url=$(./relay attach RLY-12 tmp/smoke/01-door.png --field url)   # → /attachments/<uuid>
```

An `http(s)` image URL works too; a path on your machine (`tmp/smoke/01-door.png`) does not —
the browser can't fetch it, and the tile renders as a blank placeholder.

Every key is optional (a summary-only result is fine), but **anything else is refused**: an
unrecognised key — `deploy_url` at the top level, `image` / `shot` / `path` / `name` inside a
screen — comes back `422 invalid_ai_result` naming the key you used and the ones that exist.
That refusal is deliberate. A blob that merely *looks* plausible renders an empty Screenshots
strip and nobody finds out for days.

## Customizing a board's flows

A board's flows — which stages are AI-enabled, what each node does, model/effort, retry/loop
budgets — are edited in **Settings › Flows**, not in a repo config file. Two rules keep custom
nodes safe: a node's command should start by checking out the card's branch (from `vars.branch`)
and end by committing; and the Code flow's first node (`branch`, in the shipped `code.json`)
materializes the card's `plan` into the per-card `$RELAY_PLAN` path for later nodes to work through.

A flow is also readable and writable as data: `./relay flow code --json > code.json` pulls the
canonical document (nodes, edges, trigger as stage **names**, isolation, version), and
`./relay flow-push code code.json` pushes it back. An unchanged push bumps nothing; an edited
one bumps the version like an editor save. Include the pulled `version` to get compare-and-swap
(a `409` means the flow moved under you — re-pull, re-apply, push again); omit it for
last-write-wins. The same document shape is what `docs/designs/flows/*.json` ships.
