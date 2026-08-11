---
name: relay-onboard
description: Use when wiring a repo to a Relay board for the first time, or when a repo's factory and its flows disagree wholesale rather than at one node — seeding the default factory, adopting the repo's existing agents and skills, or a hybrid, looping until `/relay-doctor` reports zero errors. Keywords: onboard, wire up, set up Relay, new project, bootstrap, seed, adopt, factory, green doctor.
---

# Relay Onboard

## Overview

Onboarding is a **reconcile loop with a real oracle**: change the repo, change the flow, re-run
the doctor, repeat — until it reports **zero errors**. That is the whole method.

    onboard = reconcile(repo ↔ flow) until /relay-doctor is green

Three legitimate paths, and the human picks one:

- **Seed** — take the shipped default flow shape as-is; **author** the agents and skills it
  names; adjust the gates. (Nothing fetches a factory for you: the scaffold ships `bin/relay`
  and the four `relay-*` skills, and ADR 0010 makes every other agent and skill the repo's own.)
- **Adopt** — keep the repo's existing agents and skills; remap the flow's nodes onto them.
- **Hybrid** — seed the flow's shape, adopt wherever the repo already has a better artifact.

**Green means zero doctor *errors*.** Warnings land in the closing summary as a human checklist;
they never block and are never chased.

**This skill adds no checks of its own.** `/relay-doctor` owns the check list and the report
format; onboarding consumes its `ERROR` / `WARNING` lines and its `N errors, M warnings` summary.
Restating a check here would be a second copy of it, and the copy would drift. The doctor is a
**skill**, invoked with the `Skill` tool — there is no `relay doctor` subcommand.

**Never run this from a flow node.** It asks questions and confirms every mutation; a runner has
nobody to ask.

**Blast radius:** `.claude/` files, `.relay/executor.json`, and flow documents.
**Never** app code, git branches, commits, or cards.

**Idempotent and resumable.** Every run starts by running the doctor and does only what is
missing, so an interrupted session continues instead of restarting. On an already-green repo, say
"nothing to do" and stop.

## When to Use

- Wiring Relay into a repo for the first time, right after `/relay-setup`.
- A repo whose `.claude/` and whose flows have drifted so far apart that the answer is a *path*,
  not a patch.
- Before enabling a board's flows for the first time.

Already wired and one node broke? That is `/relay-doctor`, not this.

## Phase 0 — Floor check

Two independent floors. The credential floor is always a **stop** — a skill cannot mint a key.
The scaffold floor stops only when `bin/relay` itself is missing; a stale `relay-*` skill
self-heals via `bin/relay update` instead.

1. **Scaffold floor** — `bin/relay` and the four `relay-*` skills must be installed. If
   `bin/relay` is missing, stop and hand the human the entry point:

   ```
   /relay-setup
   ```

   If `bin/relay` is present but any `relay-*` skill is missing or stale, refresh them with the
   **command**, not the skill — the missing one may *be* `/relay-update`, and the `Skill` tool
   cannot resolve a name that is not installed:

   ```bash
   bin/relay update --json
   ```

   Report the `written` list. A skill file written mid-session is not discoverable until Claude
   Code restarts, so if this wrote any `SKILL.md`, stop and tell the human to restart the session
   and re-run `/relay-onboard`. Resume from Phase 1 when the floor is met.

   `.relay/executor.json` is **not** part of that floor — it is not a Relay-owned served file,
   and authoring it for this repo is part of onboarding's own work below. `relay.md` **is**
   served, so `update` installs it and you never author one.

2. **Credential floor** — `RELAY_URL` and `RELAY_API_KEY` must be set and `./bin/relay board` must
   succeed. If not, stop with the checklist: mint a board key at
   `$RELAY_URL/board/<slug>/settings` → **API keys** (shown once), export both variables, re-run
   `./bin/relay board`. The doctor cannot run without a reachable board, and a skill cannot mint a
   key.

## Phase 1 — Detect

Run `/relay-doctor` (via the `Skill` tool) for the full starting diagnosis. Gather the repo's
inventory with the executor's own resolver — import it, never re-derive it:

```bash
python3 -c "
import importlib.machinery, importlib.util, json
loader = importlib.machinery.SourceFileLoader('relay_runner', 'bin/relay')
spec = importlib.util.spec_from_file_location('relay_runner', 'bin/relay', loader=loader)
mod = importlib.util.module_from_spec(spec); spec.loader.exec_module(mod)
print(json.dumps(mod.collect_capabilities()))
"
```

Report the starting state in one block: which flows exist and whether each is enabled, the error
and warning counts, which nodes fail to resolve and why, and what the repo's `.claude/` actually
holds. This is the diagnosis the path choice is made from.

> The **first** doctor run in a session may include its per-node I/O-contract confirmation
> dialogue. Those confirmations are persisted into the flow by `flow-push`, so later loop
> iterations do not re-ask. If the doctor starts re-asking on a second pass, that is a bug to
> report, not to work around.

## Phase 2 — Choose the path

**An explicit user choice, never a hidden inference.** Put the Phase 1 evidence next to the
options — "the default Code flow names 8 agents; your repo has 2" — and ask for **Seed**,
**Adopt**, or **Hybrid**.

A new board already carries the shipped `spec` / `plan` / `code` flows, **disabled**. So seed mode
is a repo-side job plus a gate adjustment, not "author a flow from nothing".

## Phase 3 — Plan

Show the **whole** plan before mutating anything, and get sign-off on it as a unit:

- files to create or modify, each with its diff — including: if `.relay/executor.json` is
  missing, author it for this repo as part of the shown plan (it is already inside this skill's
  declared blast radius, and nothing else installs it);
- flow changes as a **node-level** diff (node key → what changes);
- the **verify command**, asked here, once.

**The verify command.** Ask: *"what one command proves this repo is green?"* Propose a detected
candidate as the default — a `precommit` alias in `mix.exs`, a `check` or `test` target in a
`Makefile`, a `package.json` script — and let the human override it. Then pull each flow
(`./bin/relay flow <key> --json`) and replace **every** occurrence of the default's
`mix precommit` in the nodes' `run` strings: the shell gates that run it *and* the agent prompts
that name it. Search the pulled document for the literal rather than working from a memorised node
list — the list changes with the flow. Leave the flow's **shape** alone.

**Adopt mapping is a proposal, not a computation.** For each unresolved node, propose the best
candidate from the `.claude/` inventory *with the evidence for it*, show the whole mapping at
once, and iterate until the human is happy. A node with no candidate has exactly two exits, the
human's choice:

- **author one** — write the file the node names: an agent is `.claude/agents/<name>.md` with
  YAML frontmatter (`name`, `description`, optional `tools`) and a body that IS its system
  prompt; a skill is `.claude/skills/<name>/SKILL.md` with `name` + `description` frontmatter and
  the procedure in the body. Keep it to one job, and write the `description` so a reader can tell
  when it applies — that string is the whole basis for choosing it. Or
- **drop the node** — remove it from the flow and re-point its edges.

Never auto-map. The user is the authority on their own factory.

## Phase 4 — Apply → re-check → repeat

Apply **one** step, re-run `/relay-doctor`, show the delta (`6 errors → 3`), repeat.

- **Small, shown, confirmed, reversible.** Nothing the user has not seen. Every flow push is
  confirmed node-by-node first — the rule `/relay-doctor` already enforces.
- **Termination.** Stop at **zero errors**. Also stop when **two consecutive passes** fail to
  reduce the error count, and say plainly what is left and why: a stall is a report, not a retry
  loop.
- **Warnings are reported, not chased.** They go in the closing summary as a human checklist
  ("start `bin/relay execute`", "this agent file is named by no enabled flow").

## Phase 5 — Enable

Only once the doctor reports **zero errors**, offer to turn the flows on, taking
**one confirmation per flow**.
Show the trigger stages it will pull from, work in, and land on, and say plainly that enabling
means the board starts pulling real cards into this repo. Then push it:

```bash
./bin/relay flow <key> --json > /tmp/<key>.json    # edit: "enabled": true
./bin/relay flow-push <key> /tmp/<key>.json
```

**Never offer to enable a flow that still has errors.** Declining is a first-class outcome — the
closing summary then says where to turn them on by hand (`$RELAY_URL/board/<slug>/settings`
→ **Flows**).

Close with a summary: what changed, what the doctor now reports, and the remaining human checklist.

## Common mistakes

- **Inferring the path** instead of asking. Seed / adopt / hybrid is the human's call.
- **Auto-mapping an unresolved node** onto the nearest-looking agent. Propose, show, iterate.
- **Re-implementing a doctor check** — the doctor owns the check list; consume its report.
- **Chasing warnings** — they never block a green result.
- **Pushing a flow the user has not seen** — every push is node-level confirmed first.
- **Enabling a flow with errors outstanding** — a live flow that cannot resolve its nodes fails at
  run time, on a real card.
- **Restarting from scratch on a resumed session** — run the doctor first and do only what is
  missing.
- **Running this from a flow node** — it is interactive by design.
- **Touching app code or git** — the blast radius is `.claude/`, `.relay/executor.json`, and
  flow documents.
- **Adding a sibling file to this skill's directory** — `Relay.Scaffold.items/0` names `SKILL.md`
  only, so a reference file would silently vanish from every scaffolded repo.
