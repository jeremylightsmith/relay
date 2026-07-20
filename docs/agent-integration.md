# Working Relay from an agent (CLI + node-job executor)

Relay is programmable over a REST API (MMF 09) and a single `bin/relay` tool. That tool is two
things in one:

- a **CLI** — read the board and drive a card (`bin/relay board`, `move`, `comment`, …);
- **`relay execute`** — the runner mode: claims node-jobs from the server and runs them,
  "passing the baton" between humans and AI as cards move through a board's flows.

Dispatch is entirely server-side (ADR 0006): which cards are ready, which flow they run, and
what each step does are all `Flow`/`Flow.Node`/`Flow.Edge` rows owned by `Relay.Runs.Scheduler`
and `Relay.Runs`. `bin/relay` is generic — it knows the REST API and how to execute a claimed
node-job, but **nothing** about any particular board's columns, agents, or skills. Per-project
customization happens in **Settings › Flows** (or a per-project `.relay/flows.json` override,
RLY-140), not in a runner config file.

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
| `bin/relay why RLY-12` | **Why isn't this card moving?** One plain-language answer |
| `bin/relay runs RLY-12` | The card's runs + node executions, with detail untruncated |
| `bin/relay executors` | Who is connected, their advertised capacity, and the jobs they hold |
| `bin/relay version` | The git SHA the deployed app was built from |
| `bin/relay create "Fix login" --stage Backlog` | Create a new card (title; optional `--stage`/`--description`/`--tag`) |
| `bin/relay comment RLY-12 "…"` | Post a comment (as Relay AI) |
| `bin/relay move RLY-12 Code` | Move to a stage (by name, e.g. `"Code:Review"`) |
| `bin/relay status RLY-12 working` | Set status (`ready`\|`working`\|`needs_input`\|`in_review`) |
| `bin/relay describe RLY-12 @spec.md` | Set the card's **description** (the spec) |
| `bin/relay criteria RLY-12 @criteria.md` | Set the card's **acceptance criteria** (numbered; authored at Spec, run at Code) |
| `bin/relay plan RLY-12 @plan.md` | Set the card's **plan** (travels with the card) |
| `bin/relay branch RLY-12 rly-12-…` | Record the **branch** this card's work lives on |
| `bin/relay pr RLY-12 <url>` | Record the card's **PR URL** (for the review gate) |
| `bin/relay sub-tasks RLY-12 @tasks.md` | Set the **sub-task checklist** (newline-per-item or a JSON array) — Plan writes it |
| `bin/relay check RLY-12 42` / `bin/relay uncheck RLY-12 42` | Toggle one sub-task done/undone by id — Code checks items off |
| `bin/relay result RLY-12 @result.json` | Set the card's **AI result** blob (summary / changes / screens / deploy_url) |
| `bin/relay needs-input RLY-12 "…"` | Ask the human a question — blocks the card |
| `bin/relay own RLY-12` / `bin/relay release RLY-12` | Claim for the AI / hand back |
| `bin/relay approve RLY-12` / `bin/relay reject RLY-12 "note"` | Gate: advance / send back |
| `bin/relay retry RLY-12 [--at NODE]` | Retry the card's failed run in place — re-enters the last node it executed, or `--at NODE` to pick one |

Text args accept `-` (stdin) or `@path` (file) for long content (specs, plans).

**When a card isn't moving, start with `bin/relay why RLY-12`.** It answers in one or two
sentences — no enabled flow for that stage, nothing connected to run it, blocked on a human,
run failed at node X, job stranded — and `bin/relay runs RLY-12` prints the full,
untruncated failure detail behind it. `bin/relay executors` shows what is connected, and
`bin/relay version` shows which commit is deployed.

Every `--json` command also takes `--field PATH` for a single value:
`bin/relay card RLY-12 --field status` prints `working` — no `jq`, no inline `python3 -c`.

**Done is derived, not a status.** The stored status vocabulary is just
`ready | working | needs_input | in_review` — there is no `done` status to set. A card
payload instead carries `done: true` once a `ready` card is parked at the board's terminal
(rightmost) stage, plus a `needs_you: true/false` fact (and the board payload carries a
`needs_you` rollup — `needs_input` / `in_review` / `awaiting_human` / `agent_stalled`). This
means "ready" is used two ways below: **positionally**, a card is
"ready to pull" when the column to its right is an AI column (invariant 5); as a **status**,
`ready` means the card isn't actively `working`/blocked — it's just sitting wherever it is.
Don't set a `done` status; move the card to its terminal stage instead and Done follows.

## The executor

`bin/relay execute` claims node-jobs from the server and runs each in an executor-owned git
worktree. It is cheap when idle — a long-poll claim only returns when there is actual work, or
after `poll_timeout` seconds.

Agent nodes run headless Claude (`claude -p --dangerously-skip-permissions --output-format
stream-json`, streamed as a live feed, `--agent <name>` when the node names one — see
"Agent node → `.claude/agents` definition" in [`docs/architecture/runner.md`](architecture/runner.md));
`shell`/`gate` nodes run shell. Which stages are AI-enabled, what each node does, and where
finished work goes are entirely `Flow` data — see [`docs/designs/flows/`](designs/flows/README.md)
for the shipped library and Settings › Flows to view or override it on a board.

- **Watch it live:** `bin/relay execute` prints a `🤖`/`🔧` play-by-play of each headless step.
- **One job:** `bin/relay execute --once`. **Dry run (no tokens, no mutations):** `--dry-run`.

### Auth: subscription vs API tokens

Headless `claude -p` uses whatever authentication the local Claude CLI has. If it is logged into
a **Claude subscription** (Max includes Claude Code), the runner bills against the subscription —
**no `ANTHROPIC_API_KEY` needed**. If that env var *is* set, Claude Code uses the metered API
instead. Subscription **rate limits** are the ceiling; when hit, `claude -p` is throttled (it does
not silently fall back to paid API). Working one card at a time keeps this manageable.

---

## Node-job protocol (ADR 0006)

Every stage's reasoning lives server-side (`Relay.Runs`, the flow engine); `bin/relay execute`
is a **thin executor** that only claims node-jobs, runs them, and reports outcomes, on top of
the same board-key `/api` (ADR 0001 — no parallel surface):

| Endpoint | Purpose |
|---|---|
| `POST /api/node-jobs/claim` | Claim the next eligible node-job. Request: `{executor: {name, host, interval}, capacity: {shared_clean, exclusive}}`. Response: `200` with `{id, run_id, ref, node_id, node_type, agent, run, isolation, resume_session, vars}` (`agent` is the `.claude/agents/<name>.md` definition a `type: agent` node names, or `nil`; no worktree path — that's executor-local; `run_id` is the owning run's row id, which `ExecutorPool` binds an exclusive worktree slot to), or `204` when nothing is claimable (the endpoint long-polls ~25s before returning `204`; pass `?wait=0` to short-poll instead). |
| `POST /api/node-jobs/:id/outcome` | Report a job's result. Request: `{outcome, detail, git_sha, session_id}`, `outcome` one of `succeeded \| failed \| partial \| needs_input`. Response: `200` with `{status: "ok", run_state}` — `run_state` is the run's post-outcome status (`running \| parked \| done \| failed \| cancelled`), which `ExecutorPool.release` reads to decide whether to keep or free an exclusive slot. `422 unknown_outcome` for any other value; `409 conflict` if the job is no longer held by a live claim. |
| `POST /api/board/heartbeat` | An **executor beat** carries `name` + `capacity` (e.g. `{"shared_clean": 3, "exclusive": 1}`). It upserts a durable `Executor` row *and* feeds `Relay.RunnerPresence`, so the Runners view shows who's registered. A capacity-less beat is inert on this path. |
| `POST /api/node-jobs/heartbeat` | The **executor's own** heartbeat (RLY-135, `relay execute`'s `ExecutorHeartbeat`): `{executor: {name, host}, running: [job-id, …]}`, response `{revoked: [job-id, …]}` — job-ids the server wants terminated (§ revoke, below). Distinct from the `/api/board/heartbeat` beat above, which only carries capacity for presence/liveness. **Client-side only for now**: `bin/relay` posts to it, but no server route exists yet — a follow-up card wires the revoke response. |
| `POST /api/board/logs` | Each entry may now carry an optional `node_job_id` (alongside the existing `run_id`), identifying the node-job that emitted the line. |

### The `RELAY_NODE_OUTCOME` contract

Before running an agent node, the executor sets `RELAY_NODE_OUTCOME` to a **per-job** temp
file (never a fixed path like `tmp/relay-outcome.json` — overlapping `shared_clean` jobs
share a read-only worktree and must never collide). The agent node's prompt ends by writing
that file:

```json
{"outcome": "succeeded", "detail": "…"}
```

`outcome` must be one of the closed set above; `detail` becomes the edge-borne
`{prior.detail}` / `{nodes.<id>.detail}` for the next node. Before `POST`ing to
`/api/node-jobs/:id/outcome`, the executor augments the file's contents with `git_sha` (the
worktree's HEAD after the node ran) and `session_id` (the `claude -p` session id).

**Fallbacks**, evaluated in this order by `determine_agent_outcome`, when the node itself
never wrote a clean outcome:
1. the card was moved to `needs_input` during the node → report `needs_input` (checked first —
   a human question always wins, even if the node also wrote an outcome file);
2. otherwise, `RELAY_NODE_OUTCOME` supplies `{outcome, detail}` — the only channel a node has
   to signal `partial`; an unreadable/malformed file is treated as `failed`, not silently
   skipped, since a `claude -p` that exited 0 without writing a real outcome must not be
   reported as `succeeded`;
3. otherwise, **no outcome file was written → `failed`, whatever the exit code**. An agent node
   must *declare* its verdict: a `claude -p` that exits 0 having written nothing is
   indistinguishable from one that did the work, so reporting it `succeeded` would let a node
   route past its own gate having produced nothing. (RLY-163: the first live Spec-flow dogfood
   landed a card in *Spec:Review* with an empty spec exactly this way — the agent asked its
   question as prose instead of calling `needs-input` — and the same hole would let a silent
   `final_review` reach `merge`.) Rule 1 still covers the legitimate "I stopped to ask a
   human" case, so a skill that parks on a question needs no outcome file.

Agents declare their outcome by running **`relay outcome <outcome> [--detail TEXT|@file]`**
(RLY-175) rather than writing the file by hand: `json.dump` does the writing, so a `detail`
containing quotes or newlines cannot produce invalid JSON. A drill run died exactly that way —
a review's outcome file failed to parse, the node was correctly reported `failed`, and the
parse error was handed to the fixer as its findings list.

Because rule 3 now fails a silent node, the executor **appends the outcome-contract
instruction to every agent node's prompt automatically** (`OUTCOME_CONTRACT` in `bin/relay`) —
the requirement travels with every invocation rather than depending on each flow's node prompt
or each skill author remembering it. Shell and gate nodes are exempt: their exit code is
already an unambiguous verdict.

Valid outcomes: succeeded | failed. (RLY-179: an outcome with no matching edge no longer fails
the run — the engine degrades onto the node's `:failed` edge instead — so the prompt contract
stopped advertising `partial`, which no seeded flow routes. The schema, the API validator, and
the flow editor still accept `partial` for a hand-authored flow that declares its own edge.)

**Needs-input re-entry.** A `needs_input` outcome parks the run; when a human clears the card
and the run resumes, the server hands the same node back with `resume_session` set to the
`session_id` the executor captured and reported last time. The executor's `_stream_claude_job`
inserts `--resume <session_id>` into the `claude -p` argv, so the agent picks the conversation
back up with its prior context intact rather than starting the node over from scratch.

### `relay execute` — the executor runner mode

`bin/relay execute` is **the runner mode**: it claims node-jobs from the endpoints in the
table above, runs each in an executor-owned git worktree, and reports a typed outcome.

- **Config: `.relay/executor.json`**:

  ```json
  {
    "namespace": "exec",
    "capacity": { "shared_clean": 3, "exclusive": 1 },
    "poll_timeout": 25,
    "heartbeat_interval": 15
  }
  ```

  `name` defaults to the hostname, `namespace` to `exec`; a missing file falls back to
  `capacity: {shared_clean: 1, exclusive: 1}`. `capacity` is the field you'll routinely edit —
  it caps how many `shared_clean` jobs and how many `exclusive` run-slots this executor
  advertises at once. Worktrees for both classes live under the `exec-*` namespace
  (`exec-clean`, `exec-work-1`, …), auto-created.

- **Test database per slot (RLY-213).** `exclusive` capacity above 1 means multiple Code runs
  execute concurrently, each in its own `exec-work-N` worktree — and each now gets its own
  Postgres test database too, so two runs' `mix test` invocations (including the `precommit`
  gate) don't truncate each other's rows. `bin/relay` derives `MIX_TEST_PARTITION` from the
  slot name (`partition_for`) and exports it for every shell/agent step: `exec-work-N` ->
  partition `N`, the shared `exec-clean` -> partition `0`. `config/test.exs` already reads
  `MIX_TEST_PARTITION` into the database name (`relay_test$MIX_TEST_PARTITION`), so `mix test`
  creates the database on first use — but on a cold machine it's faster to provision every
  slot's database up front, once per slot you plan to allow:

  ```sh
  MIX_ENV=test MIX_TEST_PARTITION=1 mix ecto.create
  MIX_ENV=test MIX_TEST_PARTITION=2 mix ecto.create
  ```

  Repeat up to your configured `exclusive` capacity (`MIX_TEST_PARTITION=1` .. `N`), plus
  `MIX_TEST_PARTITION=0` for the shared `exec-clean` slot — each creates its own
  `relay_test<N>` database (`psql -l` to confirm). This is belt-and-braces for a cold machine;
  `mix test` creates a missing partition's database on first use regardless.

- **Running it:** `bin/relay execute` runs the claim/execute/report loop until Ctrl-C (which
  stops claiming and waits for in-flight jobs to finish). `--once` drains a single
  claim→execute→report cycle and exits (useful for scripting/testing). `--dry-run` claims and
  mutates nothing — it only logs the capacity it would advertise. `--interval N` overrides the
  configured `poll_timeout`.

- **Cancel/revoke.** If a run is cancelled server-side while this executor is running one of
  its node-jobs, the next heartbeat's `{revoked: [...]}` response terminates that job's live
  subprocess. For an `exclusive` job (bound 1:1 to that job/run) it also resets the job's
  worktree; a revoked `shared_clean` job is left as-is, since `exec-clean` is shared by other
  jobs that may still be running there and resetting it would destroy their work. Either way,
  no outcome is reported for a revoked job.

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
   `description`; the **acceptance criteria** are the card's `acceptance_criteria` field; the
   **plan** is the card's `plan` field. A step materializes these into the repo
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
   Verification is baked into the Code flow itself, not one script: `precommit` (gate, `mix
   precommit`) → `final_review` (whole-branch review) → `smoke` → `acceptance` (the "eyes" that
   watch it actually run) all have to pass before `merge` pushes, opens the PR, and
   squash-merges it — so nothing merges unverified. There is no separate Deploy stage.

## Customizing a board's flows

A board's flows — which stages are AI-enabled, what each node does, model/effort per node,
retry/loop budgets — are `Flow`/`Flow.Node`/`Flow.Edge` rows, not a repo config file. View or
edit them in **Settings › Flows**; the shipped defaults (`Relay.Flows.DefaultLibrary`) are
seeded from [`docs/designs/flows/*.jsonc`](designs/flows/README.md) — open those files for the
literal node/edge contents of Spec, Plan, and Code. A repo may override specific fields
per-project via `.relay/flows.json` (RLY-140) without forking the library.

To honor invariant 3, an agent/shell node's `run` should start by checking out the card's
branch (from `vars.branch`) and end by committing. To honor invariant 4, the Plan flow writes
the plan to the card's `plan` field, and the Code flow's `branch` node materializes it into the
worktree as `plan.md` (see [`code.jsonc`](designs/flows/code.jsonc)'s `branch` node) for
`implement` to work through.
