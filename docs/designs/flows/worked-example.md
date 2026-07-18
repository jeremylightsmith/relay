# The whole system, literally — today vs. tomorrow

Companion to [ADR 0006](../../adr/0006-workflow-orchestration.md)'s inventory: the actual
file trees, the actual file contents, and the actual database rows, so the complexity is
visible instead of asserted. **Today** = the system running right now. **Tomorrow** =
after the W-cards land.

## The file trees, side by side

```text
TODAY — repo files that make the flow      HISTORICAL — deleted in the cutover
─────────────────────────────────────      ─────────────────────────────────────────
bin/relay                   1135 lines     relay_config.json           42 (RLY-139)
.relay/executor.json           6 lines     .claude/workflows/
.claude/agents/                              execute-plan.js          485 (RLY-139)
  plan-implementer.md         57           .claude/commands/
  spec-reviewer.md            67             exec-plan.md             119 (RLY-139)
  quality-reviewer.md         74
  final-reviewer.md           60           .claude/agents/*.md are KEPT — RLY-139 settled
  final-fixer.md              27           this the other way from an earlier "optional,
  smoke-tester.md            127           prompts absorbed into flow nodes" plan: each is
  acceptance-tester.md        82           pointed at directly by a flow node's `agent`
  rebaser.md                  39           field, rendered as `claude -p --agent <name>`.
─────────────────────────────────────      ─────────────────────────────────────────
repo-side: bin/relay + 8 agent            server-side data:      3 Flow rows
files = 1,668 lines                       (spec.jsonc 22 + plan.jsonc 18 +
                                           code.jsonc 98 = 138 lines of data)
UNCHANGED THROUGHOUT: .claude/skills/* (brainstorm, TDD, debugging, …),
.claude/commands/write-plan.md, CLAUDE.md/AGENTS.md, board stages, API key.
```

## Per AI-enabled stage: the actual configuration

| Stage | What it does | Today's configuration | Tomorrow's configuration |
| --- | --- | --- | --- |
| **Spec** | Reads the card, asks the human clarifying questions (needs-input stepper), writes the spec + acceptance criteria back to the card | **Cut over (RLY-136):** no `relay_config.json` pipeline entry — runs as the enabled `spec` [Flow row ↓](#spec-stage) (22 lines) on the engine + [`brainstorm` skill](../../../.claude/skills/brainstorm/SKILL.md) | [Flow row ↓](#spec-stage) (22 lines) |
| **Plan** | Turns the approved spec into the implementation plan stored on the card | **Cut over (RLY-138):** no `relay_config.json` pipeline entry — runs as the enabled `plan` [Flow row ↓](#plan-stage) (18 lines) on the engine + [`write-plan` command](../../../.claude/commands/write-plan.md) | [Flow row ↓](#plan-stage) (18 lines) |
| **Code** | Implements the plan task-by-task with TDD + two reviews each, then precommit, whole-branch review, smoke, acceptance, and PR + squash-merge | **Cut over (RLY-139):** no `relay_config.json` pipeline entry — runs as the enabled `code` [Flow row ↓](#code-stage) (`code.jsonc`, 13 nodes / 21 edges) on the engine + 7 [`.claude/agents/`](../../../.claude/agents/) files named by node `agent` | [Flow row ↓](#code-stage) (`code.jsonc`) |

### Spec stage

**Today — cut over (RLY-136).** Spec no longer has a `relay_config.json` pipeline entry; it
runs as the enabled `spec` Flow on the engine (see "Tomorrow" below, which is now *today's*
reality for this stage). Code is cut over too (RLY-139, below) — every AI-enabled stage now
runs on the engine, and the legacy `relay watch` / `relay_config.json` dispatcher is deleted.
See [`docs/runbooks/flow-cutover.md`](../../runbooks/flow-cutover.md) for the cutover ritual.

Files it pulls in: [`.claude/skills/brainstorm/`](../../../.claude/skills/brainstorm/SKILL.md)
(the behavior — stays in both worlds, developer-owned).

**Tomorrow** — the `Flow` row (trigger stored as stage ids; names shown for readability):

```jsonc
{ "key": "spec", "board_id": 1, "enabled": false, "origin": "default", "version": 1,
  "isolation": "shared_clean",
  "trigger": { "from": "Next up", "stage": "Spec", "done": "Spec:Review" },
  "nodes": {
    "brainstorm": { "type": "agent", "run": "/brainstorm {ref}", "max_retries": 1 }
  },
  "edges": [
    { "from": "start", "to": "brainstorm" },
    { "from": "brainstorm", "to": "done", "on": "succeeded" }
  ] }
```

Note what evaporated: the 9-line prompt above shrinks to `/brainstorm {ref}` because its
other 8 lines are workarounds — "ask in ONE structured call" becomes the `needs_input`
outcome contract; "then STOP, don't touch git" becomes node boundaries the engine enforces.

### Plan stage

**Today — cut over (RLY-138).** Plan no longer has a `relay_config.json` pipeline entry; it
runs as the enabled `plan` Flow on the engine (see "Tomorrow" below, which is now *today's*
reality for this stage). Code is cut over too (RLY-139, below) — every AI-enabled stage now
runs on the engine, and the legacy `relay watch` / `relay_config.json` dispatcher is deleted.
See [`docs/runbooks/flow-cutover.md`](../../runbooks/flow-cutover.md) for the cutover ritual.

Historical record — the `relay_config.json` entry this replaced, now deleted:

```json
{
  "stage": "Plan",
  "from": "Spec:Done",
  "done": "Plan:Done",
  "pool": "clean",
  "action": [
    { "claude": "You are the AI working Relay card {ref} at the PLAN stage. Run /write-plan {ref} to completion — it reads the approved spec from the card and writes the implementation plan back to the card. This is authorized; proceed without asking. Then STOP. Do not touch git or other cards." }
  ]
}
```

Files it pulls in: [`.claude/commands/write-plan.md`](../../../.claude/commands/write-plan.md)
(now carries the operational framing directly — RLY-138 — developer-owned).

**Tomorrow** — the `Flow` row:

```jsonc
{ "key": "plan", "board_id": 1, "enabled": false, "origin": "default", "version": 1,
  "isolation": "shared_clean",
  "trigger": { "from": "Spec:Done", "stage": "Plan", "done": "Plan:Done" },
  "nodes": {
    "write_plan": { "type": "agent", "run": "/write-plan {ref}", "max_retries": 1 }
  },
  "edges": [
    { "from": "start", "to": "write_plan" },
    { "from": "write_plan", "to": "done", "on": "succeeded" }
  ] }
```

### Code stage

**Today — cut over (RLY-139).** Code no longer has a `relay_config.json` pipeline entry; it
runs as the enabled `code` Flow on the engine (see "Tomorrow" below, which is now *today's*
reality for this stage). This was the last stage on the legacy dispatcher — `relay watch`,
`relay_config.json`, `.claude/commands/exec-plan.md` and `.claude/workflows/execute-plan.js`
are all deleted; every AI-enabled stage now runs on the engine. See
[`docs/runbooks/flow-cutover.md`](../../runbooks/flow-cutover.md) for the cutover ritual.

Historical record — the `relay_config.json` entry this replaced, now deleted:

```json
{
  "stage": "Code",
  "from": "Plan:Done",
  "done": "Review",
  "pool": "work",
  "action": [
    { "shell": "git fetch origin --prune && git checkout -B {branch} origin/main && rm -f tmp/exec-plan-status" },
    { "claude": "You are the AI working Relay card {ref} at the CODE stage. Run /exec-plan {ref} on the current branch to completion — it materializes the plan from the card into a transient plan.md, runs the workflow, and cleans up after itself. This is authorized — proceed without asking for confirmation. Do not push or merge yourself; the shell steps that follow push the branch, open the PR, and squash-merge it." },
    { "shell": "test \"$(cat tmp/exec-plan-status 2>/dev/null)\" = ready || { echo \"exec-plan did not reach 'ready' (review/smoke not passed) — refusing to push or merge\"; exit 1; }" },
    { "shell": "git push -u origin {branch}" },
    { "shell": "url=$(gh pr create --fill --head {branch} --base main) && {relay} branch {ref} {branch} && {relay} pr {ref} \"$url\" && echo \"PR: $url\"" },
    { "shell": "git checkout --detach && gh pr merge {branch} --squash && { git push origin --delete {branch} || true; git branch -D {branch} || true; }" }
  ]
}
```

Historical record — the files that entry pulled in, also now deleted:
[`exec-plan.md`](../../../.claude/commands/exec-plan.md) (119) →
[`execute-plan.js`](../../../.claude/workflows/execute-plan.js) (485).

Files it pulls in **today**: the node `agent` field (RLY-139) points a reviewer/implementer
node at a `.claude/agents/<name>.md` definition, which supplies the system prompt for
`claude -p --agent` — developer-owned, freely editable —
[`plan-implementer`](../../../.claude/agents/plan-implementer.md) (57) ·
[`spec-reviewer`](../../../.claude/agents/spec-reviewer.md) (67) ·
[`quality-reviewer`](../../../.claude/agents/quality-reviewer.md) (74) ·
[`final-reviewer`](../../../.claude/agents/final-reviewer.md) (60) ·
[`final-fixer`](../../../.claude/agents/final-fixer.md) (27) ·
[`smoke-tester`](../../../.claude/agents/smoke-tester.md) (127) ·
[`acceptance-tester`](../../../.claude/agents/acceptance-tester.md) (82).
[`rebaser`](../../../.claude/agents/rebaser.md) (39) stays in the repo but no Code node names
it yet.

**Tomorrow** — the `Flow` row is [`code.jsonc`](code.jsonc) **in its entirety** (13 nodes,
21 edges, models + agents per node) plus the record wrapper:

```jsonc
{ "key": "code", "board_id": 1, "enabled": false, "origin": "default", "version": 1,
  "isolation": "exclusive",
  "trigger": { "from": "Plan:Done", "stage": "Code", "done": "Review" },
  "nodes": { /* the 13 nodes of code.jsonc — branch, implement (foreach: "card.sub_tasks"),
                spec_review, quality_review, precommit, final_review, final_fix,
                smoke, smoke_fix, acceptance, acceptance_fix, post, merge. The next_task
                grep-gate is GONE — "which task is next" is engine-derived (RLY-139). */ },
  "edges": [ /* its 21 outcome-routed edges: quality_review carries TWO guarded
                succeeded edges on the same outcome — { to: implement, when:
                foreach_remaining } and { to: precommit, when: foreach_exhausted } —
                which is what the next_task gate was faking; fix loops bounded by
                max_loops, now scoped per foreach iteration */ ] }
```

The agent files' *prompts* become the nodes' `run` strings, and 7 of them are also pointed
at directly by a node's `agent` field for a richer system prompt. The 4 trailing shell steps
and the `tmp/exec-plan-status` gate become the `merge` node + routing.

## Tomorrow's repo files, in full

**`.relay/executor.jsonc`** — the only *new* required repo file; replaces
`relay_config.json`'s `pools` block (its `pipeline` block has no successor — that's the
point):

```jsonc
{
  "worktree_root": ".claude/worktrees/exec",   // never shares the legacy watcher's dirs
  "capacity": { "shared_clean": 3, "exclusive": 1 },
  "base": "origin/main"
}
```

**`.relay/flows.json`** — optional, only if this repo overrides the shipped library (RLY-140):

```jsonc
{
  "code": {
    "nodes": { "implement": { "run": "/exec-task {ref}" } }
  }
}
```

**The flow definitions** are not repo files at all — they're rows in the `Flow` table,
seeded from [`spec.jsonc`](spec.jsonc) (22 lines), [`plan.jsonc`](plan.jsonc) (18), and
[`code.jsonc`](code.jsonc) (98). Those three files ARE the literal contents; open them.

## The domain objects and how they stick together

```mermaid
erDiagram
    Board ||--o{ Stage : has
    Board ||--o{ Flow : "3 rows: spec, plan, code"
    Flow }o--|| Stage : "trigger: from / stage / done"
    Flow ||--o{ Run : "one per card traversal"
    Card ||--o{ Run : has
    Card ||--o{ SubTask : "parsed from plan (RLY-139)"
    Run ||--o{ NodeExecution : "history, one per node attempt"
    Run ||--o{ NodeJob : "work in flight"
    SubTask ||--o{ NodeExecution : "binds one foreach iteration"
    Executor ||--o{ NodeJob : claims
    Board ||--o{ Executor : "registered machines"

    Flow {
        string key "spec | plan | code"
        string isolation "shared_clean | exclusive"
        bool enabled "false until cutover"
        json nodes "embedded, from *.jsonc"
        json edges "embedded, from *.jsonc"
    }
    Run {
        string status "running | parked | done | failed | cancelled"
        string current_node
    }
    SubTask {
        string title "### Task N: <name> heading"
        bool done "checked at the loop tail, after review"
        int position
    }
    NodeExecution {
        string outcome "succeeded | failed | partial | needs_input"
        string git_sha
        string session_id
        int attempt
        int sub_task_id "nil outside a foreach (RLY-139)"
    }
    NodeJob {
        string state "queued | claimed | running | done | revoked"
        json payload "rendered run, isolation, vars, agent"
    }
    Executor {
        string name
        json capacity "per isolation class"
        datetime last_heartbeat
    }
```

## The rows, mid-flight

A concrete moment: imaginary card **RLY-150 "CSV export of the board"** is in the Code
flow; the quality review just refuted task 2's implementation and the engine looped back.
Every row involved (abridged JSON; timestamps trimmed):

```jsonc
// Flow — one of the three seeded rows (nodes/edges = code.jsonc, not repeated here)
{ "key": "code", "board_id": 1, "enabled": true, "origin": "default", "version": 1,
  "isolation": "exclusive",
  "trigger": { "from_stage_id": 41, "stage_id": 47, "done_stage_id": 51 } }

// Executor — one registered machine (was: relay_config.json's pools block)
{ "id": 3, "name": "jeremy-mbp", "board_id": 1,
  "capacity": { "shared_clean": 3, "exclusive": 1 },
  "last_heartbeat": "…T18:42:07Z", "status": "online" }

// SubTask — parsed from the card's plan at run start (RLY-139); task 1 already
// checked off (it passed both reviews), task 2 is the iteration in flight
{ "id": 501, "card_id": 150, "title": "Add CSV export endpoint",   "done": true,  "position": 1 }
{ "id": 502, "card_id": 150, "title": "Wire the export button up", "done": false, "position": 2 }

// Run — RLY-150's traversal of the code flow
{ "id": "run_7f3a", "card_id": 150, "flow_key": "code", "flow_version": 1,
  "status": "running", "current_node": "implement", "started_at": "…T17:55:02Z" }

// NodeExecution — the history so far (what RLY-137 renders on the card). branch is
// unbound (sub_task_id nil); task 1's three iteration nodes are bound to 501 and
// already checked off at quality_review; task 2's implement/spec_review/quality_review
// are bound to 502 — the failed quality_review is what looped back into implement.
{ "run": "run_7f3a", "node": "branch",         "attempt": 1, "sub_task_id": null, "outcome": "succeeded", "git_sha": "9c01d4e", "duration_s": 2 }
{ "run": "run_7f3a", "node": "implement",      "attempt": 1, "sub_task_id": 501,  "outcome": "succeeded", "git_sha": "…", "duration_s": 701 }
{ "run": "run_7f3a", "node": "spec_review",    "attempt": 1, "sub_task_id": 501,  "outcome": "succeeded", "git_sha": "…", "duration_s": 140 }
{ "run": "run_7f3a", "node": "quality_review", "attempt": 1, "sub_task_id": 501,  "outcome": "succeeded", "git_sha": "…", "duration_s": 190 }
{ "run": "run_7f3a", "node": "implement",      "attempt": 1, "sub_task_id": 502,  "outcome": "succeeded", "git_sha": "5e2f90c", "session_id": "s_a41…", "duration_s": 861 }
{ "run": "run_7f3a", "node": "spec_review",    "attempt": 1, "sub_task_id": 502,  "outcome": "succeeded", "git_sha": "5e2f90c", "duration_s": 173 }
{ "run": "run_7f3a", "node": "quality_review", "attempt": 1, "sub_task_id": 502,  "outcome": "failed",    "git_sha": "5e2f90c", "duration_s": 244,
  "detail": "export test asserts on private struct internals; assert on the CSV bytes instead" }

// NodeJob — the work in flight right now (loop 1 of 3 back into implement, still
// bound to sub_task 502; carrying the finding; session resumes so the implementer
// keeps its context)
{ "id": "nj_c88", "run": "run_7f3a", "node": "implement", "state": "claimed",
  "executor_id": 3, "claimed_at": "…T18:41:55Z",
  "payload": { "isolation": "exclusive", "resume_session": "s_a41…", "agent": "plan-implementer",
               "run": "Implement the task named {sub_task} from the card's plan with strict red/green TDD. One task only — do not start the next one. If reviewer findings are attached, address them.",
               "vars": { "ref": "RLY-150", "branch": "rly-150-csv-export",
                         "sub_task": "Wire the export button up",
                         "findings": "export test asserts on private struct internals; …" } } }
```

That's the entire state: **3 Flow rows per board (written once), 1 Executor row per
machine, and ~1 Run + ~2 SubTask + ~15 NodeExecution rows + transient NodeJobs per card
worked.**

## The complexity ledger

| | Today | Tomorrow |
| --- | --- | --- |
| Repo-side flow machinery | 2,174 lines across 12 files | ~610 lines across 2 files (executor + its config) |
| Orchestration logic | `execute-plan.js` (485 lines of JS) + `bin/relay watch` dispatch (~400 of the 995) | engine code in `Relay.Flows`/`Relay.Runs` (new, W2–W4 — the cost moved here, written once for every project) |
| Flow *definitions* | implicit in JS + config + 8 agent files | 130 lines of data, 3 files, renderable as graphs |
| Per-project setup | copy 12 files, keep them in sync by hand | `relay init` + one executor config |
| State when idle | none (stateless watcher) | 3 Flow rows + 1 Executor row |
| State per worked card | scattered: card timeline + runner stdout | 1 Run + ~15 NodeExecution rows, queryable |

The honest reading: total complexity doesn't vanish — the 485 lines of `execute-plan.js`
become engine code in Elixir (RLY-131…134). What changes is *where it lives* (in the product,
tested, shared by every project) and *what a project carries* (2,174 lines → ~610 + data).
