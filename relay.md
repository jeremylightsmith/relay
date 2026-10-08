# Working with Relay from your agent

Relay is an AI-first kanban board. Work passes back and forth between humans and AI as cards flow
**left → right** through a board's stages. You drive it with one tool, `./relay` (zero-dependency
Python 3). `./relay start` runs as a runner and claims jobs from the server; setup lives at
`$RELAY_URL/docs/architecture-runner`.

**Dispatch is server-side.** Which cards are ready, which flow runs them, and what each step does
are configured per board in **Settings › Flows**, never in this repo.

**Full reference:** `$RELAY_URL/docs/cli` (every command and flag, runner config, flows as data),
`$RELAY_URL/docs/api`, `$RELAY_URL/docs/statuses-and-outcomes`.

## Setup

1. Mint a board API key at `/board/<slug>/settings?section=keys`, one per machine. Writes are
   attributed to the board's AI agent ("Relay AI").
2. Export `RELAY_URL` and `RELAY_API_KEY` in the agent's shell (e.g. a gitignored `.envrc.local`).
3. Confirm: `./relay board` prints your board.
4. Wire the repo to a flow: run `/relay-onboard` in Claude Code. If the repo is already wired and
   one node broke, use `/relay-doctor`.

## Mental model

**Everything about a card travels on the card**, not in the working tree: description, spec,
criteria, plan + tasks, branch, PR, result, blockers. `describe` and `spec` are separate fields.

**Stages and substages.** `*:Review` is a human checkpoint (`approve` → `*:Done`); `*:Done`
auto-continues into the next AI stage.

**Status** is `ready | working | needs_input | in_review`. There is no `done` status: a `ready` card
in the rightmost stage reports `done: true`.

**Stuck cards** are blocked on a human (`needs_input`), waiting at a review gate, missing a flow or
runner, or have a failed/stranded run. `./relay why` names which.

## Cheatsheet

Add `--json` for machine output and `--field PATH` for one value. Long text args take `-` (stdin)
or `@path`.

| Command | What it does |
|---|---|
| `./relay board` · `./relay card RLY-12` | The board · one card |
| `./relay search "words"` | Find a card by ref or title |
| `./relay why RLY-12` | **Why isn't this card moving?** |
| `./relay runs RLY-12` · `./relay runners` · `./relay version` | Run detail · connected runners · deployed SHA |
| `./relay create "Fix login" --stage Backlog [--depends-on RE12,RE13]` | Create a card |
| `./relay move RLY-12 Code` · `./relay title RLY-12 "…"` | Move to a stage · retitle |
| `./relay archive RLY-12` · `./relay unarchive RLY-12` | Take off the board / restore (`cancel` a live run first) |
| `./relay status RLY-12 working` | Set status |
| `./relay describe` · `./relay spec` · `./relay criteria` · `./relay plan RLY-12 @file` | Set those fields |
| `./relay tasks add RLY-12 --task "Title" @body.md` · `./relay tasks list RLY-12` | Append tasks · list them |
| `./relay task show RLY-12 42` | Read one task's body |
| `./relay check` · `./relay uncheck RLY-12 42` | Toggle a task done |
| `./relay sub-tasks RLY-12 @file` | Legacy: replace the whole task list |
| `./relay branch` · `./relay pr` · `./relay result RLY-12 …` | Record branch / PR url / AI result |
| `./relay attach RLY-12 shot.png` | Upload a file; `--field url` gives its `/attachments/…` path |
| `./relay mockups RLY-12 a.html b.png` · `--pull` | Replace the card's mockups · download them |
| `./relay depends RLY-12 RLY-13` | Replace the card's blocker set |
| `./relay comment RLY-12 "…"` · `./relay needs-input RLY-12 "…"` | Comment · ask a human (blocks) |
| `./relay own` · `./relay release RLY-12` | Claim for the AI · hand back |
| `./relay approve` · `./relay reject RLY-12 ["note"]` | Review gate |
| `./relay retry RLY-12 [--at NODE]` · `./relay cancel RLY-12` | Retry · stop the active run |
| `./relay stages` · `./relay stage add …` | List · edit the board's stages |
| `./relay flow code --json` · `./relay flow-push code code.json` | Pull · push a flow |
| `./relay update` | Refresh `./relay`, the `relay-*` skills and this file (prefer `/relay-update`) |

## Working inside a flow

If your skill runs as a flow node, learn what your step should write (spec, plan, criteria) from
the installed skills, **Settings › Flows** and `./relay why`. Don't hard-code it. Write results
with the verbs above so they travel on the card.

If your node's work is already committed on the branch, don't fake a commit or escalate:
`./relay outcome succeeded --no-changes`.

### The `RELAY_NODE_SCRATCH` contract

The runner sets `RELAY_NODE_SCRATCH` to a git-ignored file in the node's worktree, stable per
card and node across retries. Use it for `outcome failed --detail @$RELAY_NODE_SCRATCH`, and put
sibling payloads next to it: `$(dirname "$RELAY_NODE_SCRATCH")/<name>.json`. Never invent your own
scratch path.

### The AI result blob

`./relay result RLY-12 @result.json` takes exactly this shape. Every key is optional:

```json
{
  "summary": "- markdown bullets for a product owner",
  "changes": ["Adds …", "Removes …"],
  "screens": [{ "url": "/attachments/<uuid>", "caption": "Sign in" }]
}
```

A screen's `url` is the uploaded image: `./relay attach RLY-12 shot.png --field url`. Any other
key is refused with `422 invalid_ai_result`.
