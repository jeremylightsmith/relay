# Working Relay from an agent (CLI + autonomous board runner)

Relay is programmable over a REST API (MMF 09) and a single `bin/relay` tool. That tool is two
things in one:

- a **CLI** — read the board and drive a card (`bin/relay board`, `move`, `comment`, …);
- a **board runner** — run with no arguments (`bin/relay watch`) and it watches the board and
  drives *ready* cards through a pipeline autonomously, "passing the baton" between humans and AI.

`bin/relay` is generic — it knows the REST API and how to watch/dispatch, but **nothing** about
any particular board's columns, agents, or skills. All of that lives in **`relay_config.json`**.
This split is deliberate: another team customizes the runner by editing config, not code.

---

## Setup

1. **Mint a board API key:** in Relay, open `/board/settings` → **API keys** → Generate (shown
   once). Every write is attributed to the board's AI agent ("Relay AI").
2. **Configure the environment** the agent's shell uses (e.g. in `.envrc.local`, gitignored):

   ```bash
   export RELAY_URL="https://<your-relay-host>"
   export RELAY_API_KEY="relay_xxxxxxxxxxxx_…"
   ```
3. **Confirm access:** `./bin/relay board` should print your board.

`bin/relay` is zero-dependency (Python 3 stdlib only), so it runs anywhere the agent does.

## CLI

Human output by default; add `--json` for machine output. Non-zero exit on any error.

| Command | What it does |
|---|---|
| `bin/relay board` | The board: stages with their cards |
| `bin/relay card RLY-12` | One card: description, plan, branch, timeline |
| `bin/relay create "Fix login" --stage Backlog` | Create a new card (title; optional `--stage`/`--description`/`--tag`) |
| `bin/relay pull` | (advisory) the next ready card per the config |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay move RLY-12 Code` | Move to a stage (by name, e.g. `"Code:Review"`) |
| `bin/relay status RLY-12 working` | Set status (`ready`\|`working`\|`needs_input`\|`in_review`) |
| `bin/relay describe RLY-12 @spec.md` | Set the card's **description** (the spec) |
| `bin/relay plan RLY-12 @plan.md` | Set the card's **plan** (travels with the card) |
| `bin/relay branch RLY-12 rly-12-…` | Record the **branch** this card's work lives on |
| `bin/relay pr RLY-12 <url>` | Record the card's **PR URL** (for the review gate) |
| `bin/relay sub-tasks RLY-12 @tasks.md` | Set the **sub-task checklist** (newline-per-item or a JSON array) — Plan writes it |
| `bin/relay check RLY-12 42` / `bin/relay uncheck RLY-12 42` | Toggle one sub-task done/undone by id — Code checks items off |
| `bin/relay result RLY-12 @result.json` | Set the card's **AI result** blob (summary / changes / screens / deploy_url) |
| `bin/relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `bin/relay own RLY-12` / `bin/relay release RLY-12` | Claim for the AI / hand back |
| `bin/relay approve RLY-12` / `bin/relay reject RLY-12 "note"` | Gate: advance / send back |

Text args accept `-` (stdin) or `@path` (file) for long content (specs, plans).

**Done is derived, not a status.** The stored status vocabulary is just
`ready | working | needs_input | in_review` — there is no `done` status to set. A card
payload instead carries `done: true` once a `ready` card is parked at the board's terminal
(rightmost) stage, plus a `needs_you: true/false` fact (and the board payload carries a
`needs_you` rollup). This means "ready" is used two ways below: **positionally**, a card is
"ready to pull" when the column to its right is an AI column (invariant 5); as a **status**,
`ready` means the card isn't actively `working`/blocked — it's just sitting wherever it is.
Don't set a `done` status; move the card to its terminal stage instead and Done follows.

## The runner

`bin/relay watch` polls the board and, on any change, works the single **rightmost ready** card
one hop, then re-polls. It is cheap when idle — it fingerprints the board and only spends model
tokens when there is actual work.

Reasoning stages run headless Claude (`claude -p --dangerously-skip-permissions --output-format
stream-json`, streamed as a live feed); mechanical steps (git, PR, merge) run shell. The pipeline —
which columns are AI columns, what to run at each, and where finished work goes — is entirely in
`relay_config.json`. Regenerate a skeleton from your board with `bin/relay layout`.

- **Watch it live:** `bin/relay watch` prints a `🤖`/`🔧` play-by-play of each headless step.
- **One pass:** `bin/relay watch --once`. **Dry run (no tokens, no mutations):** `--dry-run`.

### Auth: subscription vs API tokens

Headless `claude -p` uses whatever authentication the local Claude CLI has. If it is logged into
a **Claude subscription** (Max includes Claude Code), the runner bills against the subscription —
**no `ANTHROPIC_API_KEY` needed**. If that env var *is* set, Claude Code uses the metered API
instead. Subscription **rate limits** are the ceiling; when hit, `claude -p` is throttled (it does
not silently fall back to paid API). Working one card at a time keeps this manageable.

---

## Operating invariants

These are the rules the runner relies on. Break one and cards corrupt each other's work. If you
build your own runner or agents, honor these:

1. **One agent works in a repo directory at a time.** A `git checkout` (or branch/file edit) is
   *global to the working directory* — two agents on two branches in one directory overwrite each
   other. Serialize (one card at a time), or give each agent its own **clone or `git worktree`**.
   Do **not** run the runner and an interactive session in the same working tree at once.

2. **Many cards are in flight, moving back and forth between stages.** A card may be specced, then
   sit for review, then planned much later, while other cards pass through. So **state must live on
   the board/card, never in the working tree.** Nothing durable may depend on "what's currently
   checked out" or a shared repo-root scratch file.

3. **Each card owns its own branch — commit at the end of every step, checkout at the start.**
   Because the working tree is shared and cards interleave, every step must:
   - **begin** by `git checkout`-ing the card's branch (restore its context — the card carries its
     `branch` field for exactly this), and
   - **end** by committing its work (never leave uncommitted changes for the next card to inherit).
   A step must be self-contained: it cannot assume the tree is where it left it.

4. **Work travels *with the card*, not in shared repo files.** The **spec** is the card's
   `description`; the **plan** is the card's `plan` field. A step materializes these into the repo
   just-in-time (inside the card's branch) and never relies on a shared `plan.md` that another card
   will clobber. (This is why `Card` has `branch` + `plan` fields, API-read/writable.)

5. **Readiness is positional and prioritized.** A card is *ready* when the column immediately to its
   right is an AI column (`Next up → Spec`, `Spec:Done → Plan`, `Plan:Done → Code`). Work
   **right-to-left** (finish what's furthest along first). Two guards: **respect WIP
   limits** (don't pull into a full AI column) and **skip blocked cards** (anything in
   `needs_input`).

6. **Finish a stage by pushing to the next column — Review if it exists, else Done.** A `*:Review`
   sub-lane is a human checkpoint (the runner stops; a human approves it into `*:Done`); a `*:Done`
   sub-lane auto-continues (the runner picks it up for the next AI stage). The board's sub-lane
   layout *is* the human-checkpoint configuration.

7. **On failure, flag the card — never retry-loop.** If a step fails, set the card to `needs_input`
   with the reason. Because blocked cards are skipped (invariant 5), a flagged card is not retried
   until a human clears it. Idempotent, no infinite loops.

8. **Ask, don't guess.** If a reasoning stage needs clarification, it calls `bin/relay needs-input`
   and stops; the human answers in the drawer; the card unblocks and resumes on a later tick.
   Verification (`mix precommit` + the exec-plan review + the acceptance-smoke "eyes") is baked into
   the Code stage, which finishes by pushing, opening the PR, and squash-merging it — so nothing
   merges unverified. There is no separate Deploy stage.

## Customizing (`relay_config.json`)

The config is the whole contract. Per AI stage:

```json
{ "stage": "Spec", "from": "Next up", "done": "Spec:Review",
  "action": [ { "claude": "…design and `{relay} describe {ref} @<file>`…" } ] }
```

- `from` — the column a ready card is pulled from; `stage` — the AI column it's moved into;
  `done` — where to push when finished (`*:Review` = checkpoint, `*:Done` = auto-continue).
- `action` — ordered steps, each `{ "shell": "…" }` or `{ "claude": "…" }`. Templates available:
  `{ref} {title} {branch} {stage} {from} {done} {relay} {url}`.

To honor invariant 3, every `action` should start by checking out `{branch}` and end by
committing. To honor invariant 4, the Plan step writes to the card's `plan` field and the Code
step materializes it inside `{branch}`.
