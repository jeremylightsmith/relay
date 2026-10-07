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

1. **Mint a board API key:** Relay → `/board/<slug>/settings?section=keys` → **+ Create new key**, named for the machine that will use it (e.g. `Mac mini`) — one key per machine; the token is shown once.
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

**Runner config.** `./relay update` creates `.relay/runner.json` when it is missing,
documented inline: every key carries a comment, and the `worktrees` block starts commented out.
A line whose first non-whitespace characters are `//` is a full-line comment and is ignored; a
trailing `//` after a value and `/* */` block comments are not supported. The file is yours to
tune and commit — `update` never overwrites it.

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
| **plan** + **tasks** | `plan`, `tasks add` / `task show` |
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
| `./relay stages` | The board's stages in board order: position, name, category, type, `ai:`, `wip:`, `substages:` — substage rows indented beneath their main stage |
| `./relay stage add "Triage" --after Spec [--type queue] [--description D] [--ai] [--wip N]` | Add a main stage beside an anchor (`--before`/`--after`, adopting the anchor's category) or at the end of a `--category` — exactly one of the three |
| `./relay stage set Code [--name N] [--description D] [--type T] [--ai\|--no-ai] [--wip N\|none] [--collapsed\|--no-collapsed] [--reject-to STAGE\|none]` | Change a main stage's settings; at least one option. A `--type` change re-snaps its cards' statuses |
| `./relay stage move Code --before Spec` | Place a main stage beside another (`--before`/`--after`); it adopts the anchor's category |
| `./relay stage lane Code review on` · `./relay stage lane Code done off` | Turn a main stage's `review`/`done` substage on or off |
| `./relay stage rm Triage` | Remove a main stage and its substages — refused (409, the server's sentence) when it can't be done safely; see *Restructuring a board* |
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
| `./relay describe` · `./relay spec` · `./relay criteria` · `./relay plan RLY-12 @file` | Set description / spec / criteria / plan header (tasks go through `tasks add`, below) — `describe` and `spec` are **separate fields**, not synonyms |
| `./relay check` · `./relay uncheck RLY-12 42` | Toggle one task done by id |
| `./relay tasks add RLY-12 --task "Title" @body.md [--task "Title" @body.md …]` | Append tasks (a title + a body each) in ONE atomic call, after the card's last task, in argument order. Bodies are raw files (`@path`, `-` for stdin — at most once — or literal text): no JSON escaping |
| `./relay tasks list RLY-12` | The card's tasks as `[x]/[ ] #id  title` — titles and metadata, **never bodies** |
| `./relay task show RLY-12 42` | One task with its full body — the only way to read a body |
| `./relay task update RLY-12 42 --title T --body @file` · `./relay task rm RLY-12 42` | Edit one task's title/body (`done` stays with `check`/`uncheck`) · remove one (later tasks move up; other tasks' ids and done flags are untouched) |
| `./relay sub-tasks RLY-12 @file` | Legacy verb: replace the card's whole task list in one call — prefer `tasks add` |
| `./relay branch` · `./relay pr` · `./relay result RLY-12 …` | Record branch / PR url / AI result blob — the blob has one shape, below |
| `./relay attach RLY-12 shot.png` | Upload a file to the card and print its markdown; `--field url` gives the `/attachments/…` path for a `screens` entry |
| `./relay mockups RLY-12 empty.html full.html --caption "Empty state" --caption "Full"` | Upload mockups and **replace** the card's list in one call (captions pair with files in order; default = filename). A mockup is **HTML or an image** — `.html .png .jpg .jpeg .webp .gif` (RE390; any other file dies before anything is uploaded), e.g. `./relay mockups RLY-12 shot.png --caption "Empty state"`. `./relay mockups RLY-12 --clear` empties it. HTML mockups must be **self-contained static HTML** — inline `<style>`/`<script>`, `data:` images/fonts; the one network exception is **Google Fonts** (a `<link>` to `fonts.googleapis.com`, font files from `fonts.gstatic.com`): they run in a sandbox with scripts on and every other request blocked. Humans review them in the drawer's **Mockups** section;any session with the board key downloads them with `./relay mockups RLY-12 --pull [DIR]` — every mockup byte-for-byte as `DIR/NN-<caption-slug>.<ext>` in card order, the extension from its stored type (`.html`, `.png`, `.jpg`, `.webp`, `.gif`) (default `tmp/RLY-12/mockups/`; `--json` prints `[{caption, url, path}]`; a card with none prints `RLY-12: no mockups` and exits 0). `--pull` can't be combined with files, `--caption` or `--clear` |
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

**Restructuring a board.** Start from `./relay stages`. Every `stage` verb addresses a
**main** stage by its **exact name or numeric id** — a name two main stages share is refused
with both ids (pass the id), and substages are reached only through `stage lane`. `stage add`
and `stage move` place a stage `--before`/`--after` an anchor main stage and **adopt the
anchor's category**; `stage add --category C` appends to the end of that category instead. A
`stage set --type` change on a stage that holds cards is allowed and **re-snaps** their
statuses to ones the new type allows. `stage rm` (and `stage lane … off`) refuses with the
server's sentence and a non-zero exit — nothing is written — when the stage, or any of its
substages:
- holds cards, **live or archived** (the refusal counts both — move them out first);
- is used by an **enabled** flow (pulls from, works in or lands on it — the refusal names the
  flows; disable or re-point them first);
- is the board's **public intake** stage (pick another in Public settings first);
- is the board's **last** main stage.

A stage that is another stage's **reject-to** target *may* be removed: the reject falls back to
the previous main stage.

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
materializes only the plan **header** into the per-card `$RELAY_PLAN` path. The tasks are not in that file: the
`implement` loop (`foreach: card.tasks`) binds one task per iteration, and each loop node fetches
its task's body with `{relay} task show {ref} {task_id}` (`{task}` is its title). A flow written
with the legacy `card.sub_tasks` / `sub_tasks` / `{sub_task_id}` names still runs — it is
normalized to `tasks` when it is loaded or pushed.

A flow is also readable and writable as data: `./relay flow code --json > code.json` pulls the
canonical document (nodes, edges, trigger as stage **names**, isolation, version), and
`./relay flow-push code code.json` pushes it back. An unchanged push bumps nothing; an edited
one bumps the version like an editor save. Include the pulled `version` to get compare-and-swap
(a `409` means the flow moved under you — re-pull, re-apply, push again); omit it for
last-write-wins. The same document shape is what `docs/designs/flows/*.json` ships.

## Deploying

On the RE board a card doesn't deploy from CI. The Code flow squashes the card's branch into one
`<REF> <title>` commit, pushes it fast-forward to `main` (`bin/ship_to_main.sh`, no PR), and lands
the card on **Code:Done**. The **Deploy** stage (WIP 1) then runs the `deploy` flow on a runner:
`checkout` → `fly` → `ios` → `android` → Review. Fly always deploys. TestFlight and Play deploy only
when the card's commit touched `flutter/`. Any failed step parks the card for a human. Both flows
are checked in under `.relay/flows/` and pushed with `./relay flow-push <key> <file>`.

Secrets come from 1Password. `.relay/deploy.env` is checked in and holds only `op://Relay
Deploy/…` references; its header lists the vault items. To deploy by hand from the repo root
(signed in with `op signin`, or with `OP_SERVICE_ACCOUNT_TOKEN` on a headless runner), run:

```bash
bin/op_deploy.sh bin/deploy_fly.sh
# equivalently:
op run --env-file=.relay/deploy.env -- bin/deploy_fly.sh
```

`bin/op_deploy.sh bin/deploy_ios.sh <REF>` and `bin/op_deploy.sh bin/deploy_android.sh <REF>` do
the same for the stores.
