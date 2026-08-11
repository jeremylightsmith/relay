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

**Core principle:** never re-implement a check — resolution comes from the executor's own
resolver, board health from `relay audit` — and change nothing without asking.

`/relay-doctor` with no argument checks **every** flow, disabled ones included and marked
`(disabled)` — the flow you are about to enable is exactly the one worth doctoring.
`/relay-doctor <key>` narrows to one.

**Never run this from a flow node.** It asks questions; a runner has nobody to ask.

## When to Use

- After editing a flow, or pushing one with `./bin/relay flow-push`.
- After adding, renaming, or deleting a `.claude/agents/*.md`, `.claude/skills/*/SKILL.md`,
  or `.claude/commands/*.md`.
- After a run failed with an unknown agent or skill, or a node that never started.
- When wiring Relay into a repo, or before enabling a flow.

## Gather

Everything comes from commands that already exist — this skill adds no code.

```bash
./bin/relay flow --json          # every flow: full document (nodes, edges, trigger, enabled, version, isolation)
./bin/relay flow <key> --json    # one flow, same shape
./bin/relay executors --json     # capacity per class, freshness, stale?, version, outdated, jobs
./bin/relay audit --json          # board health: run-history findings + CI parity (advisory, exits 0)
ls .claude/agents/*.md           # check 7 ONLY — repo-local, never ~/.claude
```

What this machine can resolve by name is the executor's own answer. Import it; do not
re-derive it:

```bash
python3 -c "
import importlib.machinery, importlib.util, json
loader = importlib.machinery.SourceFileLoader('relay_runner', 'bin/relay')
spec = importlib.util.spec_from_file_location('relay_runner', 'bin/relay', loader=loader)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(json.dumps(mod.collect_capabilities()))
"
```

That prints `{"agents": [...], "skills": [...]}` — repo `.claude/` **and** `~/.claude`
(`agents/*.md`, `skills/*/SKILL.md`, `commands/*.md`) plus built-ins — byte-for-byte what
this machine reports to the server. If it cannot load (no `python3`, no `bin/relay`), say
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
| 3 | `trigger.pulls_from` / `works_in` / `lands_on` all non-null | per flow | **error** if enabled, **warning** if not |
| 4 | leading binaries of a `run` exist on PATH *on this machine* | shell + gate nodes | **error** |
| 5 | a fresh executor advertises capacity in the flow's `isolation` class | per flow | **warning** |
| 6 | at least one connected executor is **not** `outdated` | board-wide | **warning** |
| 7 | a repo `.claude/agents/*.md` that no **enabled** flow node names | board-wide | **warning** |
| 8 | a node with a declared `reads`/`writes` contract whose skill/agent shows no evidence of honoring it | nodes with `reads`/`writes` | **warning** ("couldn't confirm") |
| 9 | a node with **no** declared contract in a flow whose stage implies one | agent + shell nodes | **warning** → the establish dialogue |

**error** = the node cannot possibly run as written. **warning** = something is off but the
flow could still run right now.

**Check 4 is a heuristic — say so in the finding.** Split `run` on `&&`, `||`, `;`, `|`;
take each segment's first bare word; expand `{relay}` to `./bin/relay`; skip shell builtins,
keywords and grouping tokens (`test`, `[`, `]`, `cd`, `exit`, `echo`, `:`, `{`, `}`, `(`, `)`,
`!`, `if`, `then`, `else`, `fi`, `for`, `while`, `do`, `done`), `VAR=$(…)` assignments, and
any segment whose command word holds an unexpanded `{placeholder}`. A segment you cannot
parse produces **no finding** — a false "missing binary" is worse than a miss. Every check-4
finding says **"on this machine"**: PATH here is not PATH on the executor.

**Checks 5–6 read, they do not compute.** Report the server's `freshness`, `stale?` and
`outdated` fields; never compare version numbers yourself. Check 5 is a **fleet union** — the
authoritative per-executor answer is the Flows enable confirm. Check 6 is **fleet-wide** — it
warns only when *no* connected executor is current (the board can then place no work at all)
— but the finding names every outdated executor.

**Check 7 scans the repo's `.claude/agents/` only** — `~/.claude` globals are not this
repo's dead code.

**Checks 8–9 read the card contract off the flow document.** `./bin/relay flow --json` already
returns every node's `reads`/`writes` — no new gathering command, and this skill still adds no
code.

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
skill, and looking only under `skills/` reports a false miss on the whole Plan flow. A `shell`
or `gate` node's evidence is its own `run` string. A file doctor cannot locate (a built-in, a
`~/.claude` global) is **"couldn't confirm"**, never a violation.

**Write evidence** is a `bin/relay` writer token appearing in that file:

| field | write evidence |
|---|---|
| `description` | `relay describe` |
| `spec` | `relay spec` |
| `acceptance_criteria` | `relay criteria` |
| `plan` | `relay plan` |
| `sub_tasks` | `relay sub-tasks` |
| `branch` | `relay branch` |
| `pr_url` | `relay pr` |
| `ai_result` | `relay result` |

**Read evidence is card-level, not per-field.** `relay card <ref>` (in any form) shows the node
reads the card, but not *which* field it uses. Say so in the report rather than claiming
precision you don't have: a node with any `reads` declared is confirmed by a single `relay card`
occurrence.

## Board health (the audit)

`./bin/relay audit --json` answers the second question, and like everything else here the skill
**reads it, never re-derives it**. Its findings share the checks' shape — severity, the node,
the evidence, the fix — and split in two:

| finding | means |
|---|---|
| `findings_dropped` (ERROR) | a review failed inside a `foreach` iteration and the loop-back target's next execution carried a **different** sub-task: the findings were never addressed |
| `verdict_flipped` (WARNING, ERROR at two nodes in one run) | the same node, same visit, same `git_sha` went `failed` → `succeeded` on a retry: a retry laundered a failure into a pass |
| `ci_parity` (WARNING) | `.github/workflows/*.yml` requires a verify command that **no enabled flow's gate node runs** — every gate can pass and the PR still fails required CI |

`ci_parity` is a **heuristic about the files in *this* working directory** — a line-based read
of the workflow YAML, because `bin/relay` is stdlib-only. Say so in the finding, exactly as
check 4 does about PATH. A step carrying `# relay-audit: ignore` on its `run:` line or the line
above is a deliberate divergence and is already silenced.

Append the audit's sections to the report below **after** the nine checks, then give **one**
combined summary line covering both halves.

## The report

Grouped by flow, errors before warnings. Every finding names three things — node, expected
artifact, fix:

```
code flow (enabled, v1)
  ERROR   node `smoke` names agent `smoke-tester`
          expected: .claude/agents/smoke-tester.md (or ~/.claude/agents/, or a built-in)
          fix: create that file, or clear the node's `agent` field and push the flow
  WARNING no fresh executor advertises `exclusive` capacity
          fix: start `bin/relay execute` on a machine with exclusive capacity
```

Finish with one summary line — `3 errors, 2 warnings across 3 flows` — or an explicit
all-clear.

## Fixing, in dialogue

1. Report everything first. Then work the **errors** one at a time. Warnings are reported
   and left alone unless the user asks.
2. Every error has two legitimate directions — the user picks:
   - **Repo side** — create the missing file, or install the missing binary. An agent is
     `.claude/agents/<name>.md` with YAML frontmatter (`name`, `description`, optional `tools`)
     whose body IS its system prompt; a skill is `.claude/skills/<name>/SKILL.md` with `name` +
     `description` frontmatter and the procedure in the body.
   - **Flow side** — the flow names something that should not exist: pull
     (`./bin/relay flow <key> --json > /tmp/<key>.json`), edit the node, push
     (`./bin/relay flow-push <key> /tmp/<key>.json`).
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
      node-level diff, get explicit confirmation, then one `./bin/relay flow-push`. This is the
      existing "never push a document the user has not seen" rule; do not weaken it.
6. **Audit findings are reported and stopped at.** A `findings_dropped` ERROR is about a
   *shipped card* — a run that already happened — and this skill's blast radius is `.claude/`
   files and flow documents only (item 4). Cards, branches and commits are out. Report it, name
   the run, and stop; do not try to "fix" a run.

## Common mistakes

- **Re-implementing the resolver** instead of calling `collect_capabilities()` — the copy
  drifts from the executor and the report starts lying.
- **Pushing a flow the user has not seen** — every push is confirmed, node-level, first.
- **Reporting a check-4 miss as certain** — it is a heuristic about *this machine's* PATH.
- **Reporting an unloadable inventory as "everything missing"** — skip checks 1 and 2 and
  say why.
- **Running this from a flow node** — it is interactive by design.
- **Declaring a contract the skill doesn't honor yet** — `writes` is enforced at run time, so an
  aspirational declaration turns a working flow into a failing one.
- **Looking for a `/name` only under `.claude/skills/`** — `/write-plan` is a *command*; check
  `.claude/commands/<name>.md` too, or check 8 reports a false miss on the Plan flow.
- **Reporting a CI-parity warning as certain** — it is a heuristic about the workflow files in
  *this* working directory, on *this* machine, against the flows enabled *right now*.
- **Branching on a finding's `check` id in `bin/relay`** — check ids are deliberately not pinned
  by the executor contract; the executor prints them opaquely so the server can add a check
  without an executor bump.
