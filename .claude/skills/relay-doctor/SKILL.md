---
name: relay-doctor
description: Use when a flow may no longer match this repo's factory — after editing a flow or one of its nodes, after adding, renaming, or removing a `.claude/agents`, skill, or command file, when a run failed with an unknown agent or skill, or when wiring Relay into a repo. Keywords: flow, factory, agent not found, unknown skill, alignment, doctor.
---

# Relay Doctor

## Overview

A board's **flow** names the steps (`agent: smoke-tester`, `run: /write-plan {ref}`); this
**repo** supplies them (`.claude/agents/*.md`, skills, commands, binaries on PATH). Nothing
checks that binding until a run dies on it. This skill checks it, reports every
disagreement, and then fixes each one **with the user** — "grow the repo or shrink the
flow?" is a question, not a computation.

The doctor now answers **two** questions: "do these names resolve?" (checks 1–9) and **"is this
board's history clean?"** (the audit). The gap between those was the whole bug — RE249 was filed
after a green doctor was followed, hours later, by five Relay bugs on one card, none of which
was a naming problem.

A third section, **factory migrations**, asks "has this repo picked up what the platform now
expects of a factory?" ADR 0010 makes the planner and executor agents the repo's own, so
`relay update` cannot deliver a change to them; doctor detects the old shape and walks the human
through the new one (see [Factory migrations](#factory-migrations)).

**Core principle:** never re-implement a check — resolution comes from the runner's own
resolver, board health from `relay audit` — and change nothing without asking.

`/relay-doctor` with no argument checks **every** flow, disabled ones included and marked
`(disabled)` — the flow you are about to enable is exactly the one worth doctoring.
`/relay-doctor <key>` narrows to one.

**Never run this from a flow node.** It asks questions; a runner has nobody to ask.

## When to Use

- After editing a flow, or pushing one with `./relay flow-push`.
- After adding, renaming, or deleting a `.claude/agents/*.md`, `.claude/skills/*/SKILL.md`,
  or `.claude/commands/*.md`.
- After a run failed with an unknown agent or skill, or a node that never started.
- When wiring Relay into a repo, or before enabling a flow.

## Gather

Everything comes from commands that already exist — this skill adds no code.

```bash
./relay flow --json          # every flow: full document (nodes, edges, trigger, enabled, version, isolation)
./relay flow <key> --json    # one flow, same shape
./relay runners --json     # capacity per class, freshness, stale?, version, outdated, jobs
./relay audit --json          # board health: run-history findings + CI parity (advisory, exits 0)
ls .claude/agents/*.md           # check 7 ONLY — repo-local, never ~/.claude
```

What this machine can resolve by name is the runner's own answer. Import it; do not
re-derive it:

```bash
python3 -c "
import importlib.machinery, importlib.util, json
loader = importlib.machinery.SourceFileLoader('relay_runner', 'relay')
spec = importlib.util.spec_from_file_location('relay_runner', 'relay', loader=loader)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(json.dumps(mod.collect_capabilities()))
"
```

That prints `{"agents": [...], "skills": [...]}` — repo `.claude/` **and** `~/.claude`
(`agents/*.md`, `skills/*/SKILL.md`, `commands/*.md`) plus built-ins — byte-for-byte what
this machine reports to the server. If it cannot load (no `python3`, no `./relay`), say
so and **skip checks 1 and 2**: unknown is not missing. Check 7 still runs — it needs only
`ls .claude/agents/*.md` and the flow documents, never the inventory.

What a flow *requires* is read off the document, mirroring `Relay.Flows.node_requirements/1`
in `lib/relay/flows.ex` — check the two still agree:

- **agents:** every node's `agent` field (absent = none).
- **skills:** the leading slash token `^/([A-Za-z0-9_-]+)` of an **agent** node's `run`
  (`/write-plan {ref}` → `write-plan`). A `shell` or `gate` node's `run` is a shell
  command — never parse it as a slash command.

## The checks

| # | Check | Applies to | Fails as |
|---|---|---|---|
| 1 | node's `agent` is in the capabilities inventory | nodes with `agent` | **error** |
| 2 | agent node's leading `/name` is in the inventory's skills | agent nodes | **error** |
| 3 | `trigger.stage` non-null, and `derived.pulls_from` / `derived.lands_on` non-null | per flow | **error** if enabled, **warning** if not |
| 4 | leading binaries of a `run` exist on PATH *on this machine* | shell + gate nodes | **error** |
| 5 | a fresh runner advertises capacity in the flow's `isolation` class | per flow | **warning** |
| 6 | at least one connected runner is **not** `outdated` | board-wide | **warning** |
| 7 | a repo `.claude/agents/*.md` that no **enabled** flow node names | board-wide | **warning** |
| 8 | a node with a declared `reads`/`writes` contract whose skill/agent shows no evidence of honoring it | nodes with `reads`/`writes` | **warning** ("couldn't confirm") |
| 9 | a node with **no** declared contract in a flow whose stage implies one | agent + shell nodes | **warning** → the establish dialogue |

**error** = the node cannot possibly run as written. **warning** = something is off but the
flow could still run right now.

**Check 4 is a heuristic — say so in the finding.** Split `run` on `&&`, `||`, `;`, `|`;
take each segment's first bare word; expand `{relay}` to `./relay`; skip shell builtins,
keywords and grouping tokens (`test`, `[`, `]`, `cd`, `exit`, `echo`, `:`, `{`, `}`, `(`, `)`,
`!`, `if`, `then`, `else`, `fi`, `for`, `while`, `do`, `done`), `VAR=$(…)` assignments, and
any segment whose command word holds an unexpanded `{placeholder}`. A segment you cannot
parse produces **no finding** — a false "missing binary" is worse than a miss. Every check-4
finding says **"on this machine"**: PATH here is not PATH on the runner.

**Checks 5–6 read, they do not compute.** Report the server's `freshness`, `stale?` and
`outdated` fields; never compare version numbers yourself. Check 5 is a **fleet union** — the
authoritative per-runner answer is the Flows enable confirm. Check 6 is **fleet-wide** — it
warns only when *no* connected runner is current (the board can then place no work at all)
— but the finding names every outdated runner.

**Check 7 scans the repo's `.claude/agents/` only** — `~/.claude` globals are not this
repo's dead code.

**Checks 8–9 read the card contract off the flow document.** `./relay flow --json` already
returns every node's `reads`/`writes` — no new gathering command, and this skill still adds no
code.

**Check 8 defers to a migration that covers it.** When a declared `reads`/`writes` is
unconfirmed AND a pending migration's detection covers that node and field, the finding's
`fix:` line reads "apply migration `tasks-cutover`" (or whichever migration covers it) — never
"remove the declaration". Covered today, both by `tasks-cutover`: `writes: tasks` on the plan
node, and `reads: tasks` on a task node.

**Check 9 does NOT apply to a node whose output is commits.** A node with
`expects_commits: true`, or any node in a Code-style flow whose only product is a branch, is
*correctly* undeclared (`docs/designs/flows/README.md`) — the commit guard is its contract, and
`writes` is not a legal place to say "commits". In this repo that exempts most of the Code flow
(`implement`, the reviewers, the fixers, the rebasers, `precommit`, `smoke`, `acceptance`, …);
only `branch`, `post` and `merge` produce a card field. Check 9 targets a node that clearly
produces a **card field** and hasn't said so. Warning on a commits-only node pushes the human
toward exactly the footgun "Common mistakes" names — an aspirational `writes` is enforced at run
time and turns a working flow into a failing one.

**Where doctor looks for evidence.** The node's `agent` field → `.claude/agents/<name>.md`; the
leading `/name` token of an **agent** node's `run` → `.claude/skills/<name>/SKILL.md` **or**
`.claude/commands/<name>.md`. Check both: `/write-plan` is a *command* in this repo, not a
skill, and looking only under `skills/` reports a false miss on the whole Plan flow. An
**agent** node's own `run` prompt text (with `{relay}` expanded to `./relay`) is evidence too,
alongside its agent and skill files — that is how a Code-flow prompt that calls
`{relay} task show {ref} {task_id}` is recognized. A `shell` or `gate` node's evidence is its
own `run` string. A file doctor cannot locate (a built-in, a `~/.claude` global) is
**"couldn't confirm"**, never a violation.

**Write evidence** is a `./relay` writer token appearing in that file:

| field | write evidence |
|---|---|
| `description` | `relay describe` |
| `spec` | `relay spec` |
| `acceptance_criteria` | `relay criteria` |
| `plan` | `relay plan` |
| `tasks` | `relay tasks add` |
| `branch` | `relay branch` |
| `pr_url` | `relay pr` |
| `ai_result` | `relay result` |

A repo-local flow file may still carry the `tasks` field's legacy spelling. The board
normalizes it when a flow is loaded or pushed, so a pulled flow never shows it; detection rule 3
of the [`tasks-cutover`](#factory-migrations) migration reports it, and check 8 treats it as
`tasks`.

**Read evidence is card-level, not per-field — with one exception.** `relay card <ref>` (in any
form) shows the node reads the card, but not *which* field it uses. Say so in the report rather
than claiming precision you don't have: a node with any `reads` declared is confirmed by a single
`relay card` occurrence. The exception is `tasks`: a card's task bodies are not in
`relay card`, so `relay task show` or `relay tasks list` is the **read** evidence for `tasks`
(and also confirms the node reads the card).

## Board health (the audit)

`./relay audit --json` answers the second question, and like everything else here the skill
**reads it, never re-derives it**. Its findings share the checks' shape — severity, the node,
the evidence, the fix — and split in two:

| finding | means |
|---|---|
| `findings_dropped` (ERROR) | a review failed inside a `foreach` iteration and the loop-back target's next execution carried a **different** task: the findings were never addressed |
| `verdict_flipped` (WARNING, ERROR at two nodes in one run) | the same node, same visit, same `git_sha` went `failed` → `succeeded` on a retry: a retry laundered a failure into a pass |
| `outcomeless_attempts` (WARNING) | one node in one visit was entered `max_outcomeless_reentries` (3)+ times without any attempt reporting an outcome — something keeps killing its job (a server restart from inside the flow?) |
| `ci_parity` (WARNING) | `.github/workflows/*.yml` requires a verify command that **no enabled flow's gate node runs** — every gate can pass and the PR still fails required CI |
| `planner_not_migrated` (WARNING) | a run in the window had its tasks seeded by parsing `## Task N:` headings out of `card.plan` (the legacy fallback; the run is marked `tasks_from_plan`) — the plan node's skill doesn't write tasks with `relay tasks add`. The run-history signal for the `tasks-cutover` migration: see [Factory migrations](#factory-migrations) |

`ci_parity` is a **heuristic about the files in *this* working directory** — a line-based read
of the workflow YAML, because `./relay` is stdlib-only. Say so in the finding, exactly as
check 4 does about PATH. A step carrying `# relay-audit: ignore` on its `run:` line or the line
above is a deliberate divergence and is already silenced.

Append the audit's sections to the report below **after** the nine checks, then the
[factory migrations](#factory-migrations) section, then give **one** combined summary line
covering all three.

## Factory migrations

ADR 0010 makes a repo's planner and executor agents **its own**, and `relay update` ships only
the Relay-owned files — so when the platform changes what a factory should *do*, nothing
delivers that change to the repo. Checks 1–9 can't see it either: they compare a flow's
*declared* contract to the repo, and a customized flow (which the board's default sync skips)
declares nothing wrong. A **factory migration** closes that gap: doctor detects that the repo
still has the old shape and walks the human to the new one.

Migrations are a list. A later platform change appends one entry in the same shape:

- an **id** — what the report and the fix dialogue call it;
- a one-paragraph **why** — the platform change, and what keeps working until the repo
  migrates;
- **detection rules** — each a local, read-only test over the files and flow documents
  [Gather](#gather) already collects (no new gathering command);
- a **recipe**, split into a plan side and an exec side;
- a **verify** step.

Each migration is reported in one of three states:

- **pending** — any detection rule fires;
- **applied** — no rule fires and the repo shows the migrated shape;
- **n/a** — the board has no node the migration concerns.

A pending migration is not an error — the old shape still runs — but unlike a warning it is not
left alone: it is **offered** in the fix dialogue, one at a time, right after the errors (see
[Fixing, in dialogue](#fixing-in-dialogue)). No migration is ever applied automatically. Every
file edit and every flow push it involves goes through the same confirm-every-change rules as
any other fix.

### Migration `tasks-cutover` (RE357)

**Why.** The planner must write the plan header with `relay plan` and each task as a standalone
body with `relay tasks add`; executors fetch ONE task by id with `relay task show`. Until a repo
migrates, the board seeds a run's tasks by parsing `## Task N:` headings out of `card.plan` — a
legacy fallback slated for deletion — marks the run `tasks_from_plan`, and the audit reports
`planner_not_migrated`. Runs keep working meanwhile; they just depend on the fallback.

**The plan node** is any agent node that declares `writes` containing `plan`, or whose evidence
file (see "Where doctor looks for evidence") contains `relay plan`. **A task node** is a
`foreach` node, or any node whose `run` references `{task}` or `{task_id}`. The migration is
**n/a** on a board with neither.

#### Detect

Pending if ANY of these holds:

1. **The planner doesn't write tasks.** The plan node's evidence file —
   `.claude/skills/<name>/SKILL.md` or `.claude/commands/<name>.md` — contains no
   `relay tasks add`.
2. **A task node doesn't fetch its task.** Neither its agent file (`.claude/agents/<name>.md`)
   nor its own `run` text contains `relay task show` (`{relay} task show` counts — expand
   `{relay}` to `./relay`).
3. **Legacy spellings in a repo flow file.** A repo-local flow file (`docs/designs/flows/*.json`,
   or wherever this repo keeps its flows) still says a legacy spelling: `sub_tasks`,
   `card.sub_tasks`, `{sub_task}` or `{sub_task_id}` (all legacy). The board normalizes these
   to the `tasks` names whenever it loads or pushes a flow, so a pulled flow never shows them — only repo files can.
4. **The audit says so.** `./relay audit --json` has a `planner_not_migrated` finding. On its
   own this can be stale history — old runs still inside the audit window. If rules 1–3 all
   pass, report the migration **applied** with a note that the finding will age out of the
   window, not pending.

#### Plan-side recipe

Applied to the plan node's skill or command file:

- **Header only** with `./relay plan <ref> @header.md` — Goal / Architecture / Tech, Global
  Constraints, and `## Verification` (`Gate:` / `Smoke:`). Nothing per-task.
- **Clear stale tasks first.** `tasks add` **appends**, so list them with
  `./relay tasks list <ref> --json` and remove each one with `./relay task rm <ref> <id>`.
- **Each task a standalone body** — Files, Interfaces (Consumes / Produces), Steps with real
  code, the deliverable and the commit message — added in ONE call, in execution order:
  `./relay tasks add <ref> --task "<title>" @task1.md --task "<title>" @task2.md …`. The batch
  is all-or-nothing.
- **Verify on the card** with `./relay tasks list <ref>` and `./relay task show <ref> <id>`.
- **Scratch files** go beside `$RELAY_NODE_SCRATCH`, never in the repo root.
- **Flow:** the plan node declares `writes: ["plan", "tasks"]`. Push that **only after** the
  skill edit is written — `writes` is enforced at run time.

#### Exec-side recipe

- `implement` keeps `foreach: "card.tasks"`.
- `implement`, `spec_review`, `quality_review` and `fix_findings` — by role; the names may
  differ in this repo — get `reads: ["tasks"]` and a `run` prompt that names `{task_id}` (and
  `{task}` for the title) and fetches the body with `` `{relay} task show {ref} {task_id}` ``.
- Each of those prompts reads `$RELAY_PLAN` **only** for the header (Global Constraints,
  `## Verification`).
- The matching agent files (those nodes' `agent:`) stop "finding their task in the plan". Where
  one tells the agent to locate `## Task N` in `$RELAY_PLAN`, replace that with: "fetch your
  task's body with `./relay task show <ref> <id>`; read `$RELAY_PLAN` only for Global
  Constraints and `## Verification`".

#### Verify

Re-run this migration's detection — it should now read **applied**. Then tell the human how to
confirm it on the next real card: once that card runs plan → code, `./relay tasks list <ref>`
shows the planner's tasks, the run is not marked `tasks_from_plan`, and the next `./relay audit`
attributes no new `planner_not_migrated` card to it.

**Reference implementation.** In the Relay repo itself: `.claude/commands/write-plan.md`
("Writing it to the card") and `docs/designs/flows/code.json` (the `implement`, `spec_review`,
`quality_review` and `fix_findings` nodes). They are the worked example — name them; don't
fetch them into another repo.

## The report

Grouped by flow, errors before warnings. Every finding names three things — node, expected
artifact, fix:

```
code flow (enabled, v1)
  ERROR   node `smoke` names agent `smoke-tester`
          expected: .claude/agents/smoke-tester.md (or ~/.claude/agents/, or a built-in)
          fix: create that file, or clear the node's `agent` field and push the flow
  WARNING no fresh runner advertises `exclusive` capacity
          fix: start `./relay start` on a machine with exclusive capacity
  WARNING node `implement` declares reads `tasks`; couldn't confirm in .claude/agents/plan-implementer.md
          fix: apply migration `tasks-cutover`

factory migrations
  MIGRATION tasks-cutover
          detected: `write_plan` runs /write-plan (.claude/commands/write-plan.md), which never calls `relay tasks add`
          fix: walk the plan-side and exec-side recipe — offered after the errors
```

The migrations section lists every migration with its status word — `MIGRATION` (pending),
`applied`, or `n/a` — so "already applied" is said, not implied.

Finish with one summary line in the form `N errors, M warnings, K migrations pending across F
flows` — e.g. `3 errors, 2 warnings, 1 migrations pending across 3 flows` — or an explicit
all-clear.

## Fixing, in dialogue

1. Report everything first. Then work the **errors** one at a time, then offer each **pending
   migration** one at a time — `[apply / skip]`. Warnings are reported and left alone unless
   the user asks.
2. Every error has two legitimate directions — the user picks:
   - **Repo side** — create the missing file, or install the missing binary. An agent is
     `.claude/agents/<name>.md` with YAML frontmatter (`name`, `description`, optional `tools`)
     whose body IS its system prompt; a skill is `.claude/skills/<name>/SKILL.md` with `name` +
     `description` frontmatter and the procedure in the body.
   - **Flow side** — the flow names something that should not exist: pull
     (`./relay flow <key> --json > /tmp/<key>.json`), edit the node, push
     (`./relay flow-push <key> /tmp/<key>.json`).
3. **A flow push is a real board mutation.** Show the exact node-level change and get
   explicit confirmation first. Never push a document the user has not seen.
4. **Blast radius:** `.claude/` files and flow documents only. Never cards, git branches,
   commits, or any other board state.
5. **Check 9's fix path — establish the contract, don't assume it.** A hand-declared contract
   just moves the "is it correct?" question, so for a node with no declared I/O:
   1. **Infer** a proposal from two signals — the node's flow/stage role (a node in a flow
      landing on Plan probably writes `plan`) *and* what its skill actually does (a `relay plan`
      call is evidence it writes `plan`).
   2. **Confirm per node** — "`write_plan`: reads `spec`, `acceptance_criteria`; writes `plan`?
      [y / adjust / skip]". Never assume: the human confirmation is what breaks the
      infer-from-the-skill-then-check-the-skill circle.
   3. **Warn, in the confirm step, that a declared `writes` is ENFORCED at run time** — the
      server rewrites the node's `succeeded` to `failed` when the field is still blank. Declare
      what the skill does **today**, not what you wish it did.
   4. **Push once per flow, not once per node** — collect the confirmed nodes, show the exact
      node-level diff, get explicit confirmation, then one `./relay flow-push`. This is the
      existing "never push a document the user has not seen" rule; do not weaken it.
6. **A migration's fix path — offer it, then walk the recipe.** Name the detection rules that
   fired and ask `[apply / skip]`. On apply, walk the recipe one file at a time: show each
   skill, command or agent edit as a diff and confirm it before writing; collect the flow
   changes (`writes`, `reads`, prompts) and push **once per flow** after showing the node-level
   diff — and only after the skill edits they depend on are written, because `writes` is
   enforced at run time. Finish with the migration's verify step. A skipped migration stays in
   the summary as pending.
7. **Check 8 → migration first.** When an unconfirmed `reads`/`writes` is covered by a pending
   migration, offer the migration **first**: it makes the skill honor the declaration, which is
   the right direction. Removing the declaration is offered only if the human declines the
   migration.
8. **Audit findings are reported and stopped at.** A `findings_dropped` ERROR is about a
   *shipped card* — a run that already happened — and this skill's blast radius is `.claude/`
   files and flow documents only (item 4). Cards, branches and commits are out. Report it, name
   the run, and stop; do not try to "fix" a run.

## Common mistakes

- **Re-implementing the resolver** instead of calling `collect_capabilities()` — the copy
  drifts from the runner and the report starts lying.
- **Pushing a flow the user has not seen** — every push is confirmed, node-level, first.
- **Reporting a check-4 miss as certain** — it is a heuristic about *this machine's* PATH.
- **Reporting an unloadable inventory as "everything missing"** — skip checks 1 and 2 and
  say why.
- **Running this from a flow node** — it is interactive by design.
- **Declaring a contract the skill doesn't honor yet** — `writes` is enforced at run time, so an
  aspirational declaration turns a working flow into a failing one. But when a migration covers
  the gap (`writes: tasks` on a planner that never calls `relay tasks add`), fix the skill
  rather than removing the declaration — the declaration is right; the skill is behind.
- **Applying a migration without asking** — a migration is a recipe the human walks with you,
  one confirmed edit at a time; doctor never runs it.
- **Looking for a `/name` only under `.claude/skills/`** — `/write-plan` is a *command*; check
  `.claude/commands/<name>.md` too, or check 8 reports a false miss on the Plan flow.
- **Reporting a CI-parity warning as certain** — it is a heuristic about the workflow files in
  *this* working directory, on *this* machine, against the flows enabled *right now*.
- **Branching on a finding's `check` id in `./relay`** — check ids are deliberately not pinned
  by the runner contract; the runner prints them opaquely so the server can add a check
  without a runner bump.
