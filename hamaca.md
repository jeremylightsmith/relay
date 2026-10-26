# Working with Hamaca from your agent

Hamaca is an AI-first kanban board. Work passes back and forth between humans and AI as cards flow
**left → right** through a board's stages. You drive it with one tool, `./hamaca` (zero-dependency
Python 3). `./hamaca start` runs as a runner and claims jobs from the server; setup lives at
`$HAMACA_URL/docs/architecture-runner`.

**Dispatch is server-side.** Which cards are ready, which flow runs them, and what each step does
are configured per board in **Settings › Stages** (the stage's FLOW band), never in this repo.

**Full reference:** `$HAMACA_URL/docs/cli` (every command and flag, runner config, flows as data),
`$HAMACA_URL/docs/api`, `$HAMACA_URL/docs/statuses-and-outcomes`.

## Setup

1. Mint a board API key at `/board/<slug>/settings?section=keys`, one per machine. Writes are
   attributed to the board's AI agent ("Hamaca AI").
2. Export `HAMACA_URL` and `HAMACA_API_KEY` in the agent's shell (e.g. a gitignored `.envrc.local`).
3. Confirm: `./hamaca board` prints your board.
4. Wire the repo to a flow: run `/hamaca-onboard` in Claude Code. If the repo is already wired and
   one node broke, use `/hamaca-doctor`.
5. `/hamaca-onboard` works the board's guided-setup checklist with `./hamaca setup status` (the
   checklist and its current step) and `./hamaca setup report STEP --status …` (one step at a
   time). Both exit 3 on a board with no checklist.

## Mental model

**Everything about a card travels on the card**, not in the working tree: description, spec,
criteria, plan + tasks, branch, PR, result, blockers. `describe` and `spec` are separate fields.

**Stages and substages.** `*:Review` is a human checkpoint (`approve` → `*:Done`); `*:Done`
auto-continues into the next AI stage.

**Status** is `ready | working | needs_input | in_review`. There is no `done` status: a `ready` card
in the rightmost stage reports `done: true`.

**Stuck cards** are blocked on a human (`needs_input`), waiting at a review gate, missing a flow or
runner, or have a failed/stranded run. `./hamaca why` names which.

## Cheatsheet

Add `--json` for machine output and `--field PATH` for one value. Long text args take `-` (stdin)
or `@path`.

| Command | What it does |
|---|---|
| `./hamaca board` · `./hamaca card RLY-12` | The board · one card (each note image prints as an `[image] <filename> <url>` line under its note; an image note from an answer or a rejection prints `· from answer Q<n>` / `· from rejection` after its author) |
| `./hamaca search "words"` | Find a card by ref or title |
| `./hamaca why RLY-12` | **Why isn't this card moving?** |
| `./hamaca runs RLY-12` · `./hamaca runners` · `./hamaca version` | Run detail · connected runners · deployed SHA |
| `./hamaca create "Fix login" --stage Backlog [--depends-on RE12,RE13]` | Create a card |
| `./hamaca move RLY-12 Code` · `./hamaca title RLY-12 "…"` | Move to a stage · retitle |
| `./hamaca archive RLY-12` · `./hamaca unarchive RLY-12` | Take off the board / restore (`cancel` a live run first) |
| `./hamaca status RLY-12 working` | Set status |
| `./hamaca describe` · `./hamaca spec` · `./hamaca criteria` · `./hamaca plan RLY-12 @file` | Set those fields |
| `./hamaca tasks add RLY-12 --task "Title" @body.md` · `./hamaca tasks list RLY-12` | Append tasks · list them |
| `./hamaca task show RLY-12 42` | Read one task's body |
| `./hamaca check` · `./hamaca uncheck RLY-12 42` | Toggle a task done |
| `./hamaca sub-tasks RLY-12 @file` | Legacy: replace the whole task list |
| `./hamaca branch` · `./hamaca pr` · `./hamaca result RLY-12 …` | Record branch / PR url / AI result |
| `./hamaca attach RLY-12 shot.png` | Upload a file; `--field url` gives its `/attachments/…` path |
| `./hamaca mockups RLY-12 a.html b.png` · `--pull` | Replace the card's mockups · download them |
| `./hamaca images RLY-12 --pull [DIR]` | Download the images attached to the card's notes (default `tmp/<REF>/images/`) |
| `./hamaca depends RLY-12 RLY-13` | Replace the card's blocker set |
| `./hamaca comment RLY-12 "…"` · `./hamaca needs-input RLY-12 "…"` | Comment · ask a human (blocks) |
| `./hamaca own` · `./hamaca release RLY-12` | Claim for the AI · hand back |
| `./hamaca approve` · `./hamaca reject RLY-12 ["note"]` | Review gate |
| `./hamaca retry RLY-12 [--at NODE]` · `./hamaca cancel RLY-12` | Retry · stop the active run |
| `./hamaca stages` · `./hamaca stage add …` | List · edit the board's stages |
| `./hamaca flow code --json` · `./hamaca flow-push code code.json` | Pull · push a flow |
| `./hamaca setup status` · `./hamaca setup report 5.1 --status done --evidence "…"` | Guided-setup checklist · report its current step (`--error`, `--data JSON`) |
| `./hamaca update` | Refresh `./hamaca`, its skills and this file (prefer `/hamaca-update`) |
| `./hamaca update --skill-dir DIR --pointer-file FILE` | Switch this project to another LLM: move its skills to `DIR`, point `FILE` at this guide, record both in `.hamaca/runner.json` |

## Working inside a flow

If your skill runs as a flow node, learn what your step should write (spec, plan, criteria) from
the installed skills, **Settings › Stages** (the stage's FLOW band) and `./hamaca why`. Don't hard-code it. Write results
with the verbs above so they travel on the card.

If your node's work is already committed on the branch, don't fake a commit or escalate:
`./hamaca outcome succeeded --no-changes`.

### Adding a harness

A board runs agent nodes on any agent CLI. A **harness** is a name, a **command template** and
its closed list of **models**, plus three optional fields: a **resume command** (how to continue
a session; without one a node re-entered after `needs_input` starts fresh), a **session id path**
(a dot path such as `.session_id` into the CLI's JSON output naming that session) and a
**signed-in check** (a command that exits 0 when the CLI is logged in). Add and edit them in
**Settings › Agents**.

A template is shell-style: the runner splits it like a shell would, then fills these
placeholders — `{prompt}` (required), `{model}`, `{worktree}`, `{ref}`, `{effort}`, `{subagent}`
(the node's `agent`) and `{session}` (resume command only). Each placeholder becomes exactly one
argument, however many spaces or quotes its value holds, and nothing passes through a shell.
Wrap an optional part in `[ … ]`: `[--effort {effort}]` is dropped whole when `{effort}` has no
value. Outside brackets, a placeholder without a value fails the node.

Worked example — the `pi` CLI:

```
pi -p {prompt} --model {model} --cwd {worktree}
```

A runner only claims nodes whose harness it has installed: it reports, per harness, whether the
template's executable is on its `PATH`, its `--version`, and the signed-in check's result. API
keys stay in the runner's environment (`.envrc.local`), never on the board.

### Usage limits

Each harness's **USAGE** block in **Settings › Agents** tells the runner how to read that CLI's
usage — off its own output, or from a usage command run every few minutes — and its **PAUSE AT**
per window. When a harness passes a PAUSE AT, `./hamaca start` stops claiming nodes for that
harness only, re-checks it while it is idle, and claims its nodes again once usage is back under
(or the window resets). Only when every installed harness is paused does the runner claim
nothing at all. PAUSE AT is set on the harness, not per runner: a `limits` block in
`.hamaca/runner.json` is ignored, with one line in the runner's log.

### The `HAMACA_NODE_SCRATCH` contract

The runner sets `HAMACA_NODE_SCRATCH` to a git-ignored file in the node's worktree, stable per
card and node across retries. Use it for `outcome failed --detail @$HAMACA_NODE_SCRATCH`, and put
sibling payloads next to it: `$(dirname "$HAMACA_NODE_SCRATCH")/<name>.json`. Never invent your own
scratch path.

### The AI result blob

`./hamaca result RLY-12 @result.json` takes exactly this shape. Every key is optional:

```json
{
  "summary": "- markdown bullets for a product owner",
  "changes": ["Adds …", "Removes …"],
  "screens": [{ "url": "/attachments/<uuid>", "caption": "Sign in" }]
}
```

A screen's `url` is the uploaded image: `./hamaca attach RLY-12 shot.png --field url`. Any other
key is refused with `422 invalid_ai_result`.
