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

**Core principle:** resolve names with the executor's own resolver, never a copy of it —
and change nothing without asking.

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
   - **Repo side** — create the missing `.claude/agents/<name>.md` or skill (follow the
     `writing-skills` skill), or install the missing binary.
   - **Flow side** — the flow names something that should not exist: pull
     (`./bin/relay flow <key> --json > /tmp/<key>.json`), edit the node, push
     (`./bin/relay flow-push <key> /tmp/<key>.json`).
3. **A flow push is a real board mutation.** Show the exact node-level change and get
   explicit confirmation first. Never push a document the user has not seen.
4. **Blast radius:** `.claude/` files and flow documents only. Never cards, git branches,
   commits, or any other board state.

## Common mistakes

- **Re-implementing the resolver** instead of calling `collect_capabilities()` — the copy
  drifts from the executor and the report starts lying.
- **Pushing a flow the user has not seen** — every push is confirmed, node-level, first.
- **Reporting a check-4 miss as certain** — it is a heuristic about *this machine's* PATH.
- **Reporting an unloadable inventory as "everything missing"** — skip checks 1 and 2 and
  say why.
- **Running this from a flow node** — it is interactive by design.
